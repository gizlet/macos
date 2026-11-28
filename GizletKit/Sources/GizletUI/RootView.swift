import GizletCore
import SwiftUI

extension Page {
    func title(_ l: Localizer) -> String {
        switch self {
        case .discover: l("Discover", "发现")
        case .games: l("Games", "游戏")
        case .apps: l("Apps", "应用")
        case .library: l("Library", "游戏库")
        case .updates: l("Updates", "更新")
        case .flash: l("Flash", "刷机")
        case .settings: l("Settings", "设置")
        }
    }

    var symbol: String {
        switch self {
        case .discover: "star"
        case .games: "gamecontroller"
        case .apps: "square.grid.2x2"
        case .library: "books.vertical"
        case .updates: "arrow.down.app"
        case .flash: "sdcard"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l

    var body: some View {
        @Bindable var model = model
        @Bindable var store = model.storeModel!
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            NavigationStack(path: $store.path) {
                page
                    .navigationDestination(for: StoreSummary.self) { StoreDetailView(summary: $0) }
            }
        }
        .searchable(text: $store.query, placement: .sidebar, prompt: l("Search", "搜索"))
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text(l("OK", "好"))))
        }
        .sheet(item: $model.updateModel.prompt) { release in
            UpdatePrompt(release: release)
        }
        .fileImporter(isPresented: $model.requestImport, allowedContentTypes: [.gizletPackage, .zip], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.importPackage(url) }
        }
    }

    @ViewBuilder private var page: some View {
        if model.storeModel.isSearching {
            SearchResultsView()
        } else {
            switch model.section {
            case .discover: DiscoverView()
            case .games: ShelfPage(shelf: .games)
            case .apps: ShelfPage(shelf: .apps)
            case .library: LibraryView()
            case .updates: UpdatesView()
            case .flash: FlashView()
            case .settings: SettingsView()
            }
        }
    }
}

extension LauncherRelease: Identifiable {
    public var id: String { version }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l

    var body: some View {
        let selection = Binding<Page?>(get: { model.storeModel.isSearching ? nil : model.section }, set: { page in
            guard let page else { return }
            model.storeModel.query = ""
            model.storeModel.path = []
            model.section = page
        })
        List(selection: selection) {
            SwiftUI.Section {
                ForEach(Page.store) { row($0) }
            }
            SwiftUI.Section(l("On This Mac", "本机")) {
                ForEach(Page.device) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { ProfileButton().padding(.horizontal, 12).padding(.bottom, 12) }
    }

    private func row(_ page: Page) -> some View {
        Label(page.title(l), systemImage: page.symbol)
            .badge(badge(for: page))
            .tag(page)
    }

    private func badge(for page: Page) -> Int {
        guard page == .updates else { return 0 }
        if case .available = model.updateModel.state { return model.appUpdates.count + 1 }
        return model.appUpdates.count
    }
}

/// The profile in use at the bottom of the sidebar; its menu switches profiles and opens Settings.
struct ProfileButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l

    var body: some View {
        Menu {
            SwiftUI.Section(l("Switch Profile", "切换 Profile")) {
                ForEach(model.profileList) { profile in
                    Button {
                        model.switchProfile(profile.id)
                    } label: {
                        if profile.id == model.profile.id { Label(l.name(of: profile), systemImage: "checkmark") } else { Text(l.name(of: profile)) }
                    }
                }
            }
            Divider()
            Button(l("Settings…", "设置…")) { model.storeModel.query = ""; model.storeModel.path = []; model.section = .settings }
        } label: {
            HStack(spacing: 10) {
                Avatar(profile: model.profile, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.name(of: model.profile)).font(.headline).lineLimit(1)
                    Text(l("Profile", "Profile")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(l("Switch profile or open Settings", "切换 Profile 或打开设置"))
        .accessibilityLabel(l("Profile: \(l.name(of: model.profile))", "Profile：\(l.name(of: model.profile))"))
    }
}

struct UpdatePrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    let release: LauncherRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l("Gizlet \(release.version) is available", "Gizlet \(release.version) 已推出")).font(.title2.bold())
                    Text(l("You have \(model.updateModel.currentVersion).", "当前版本为 \(model.updateModel.currentVersion)。")).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(release.notes(for: l.tag).isEmpty ? l("Bug fixes and improvements.", "问题修复与改进。") : release.notes(for: l.tag))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 90, maxHeight: 220)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if model.flashModel.isBusy {
                Label(l("It installs after the card being written is finished.", "正在写卡，写完后再安装。"), systemImage: "sdcard")
                    .foregroundStyle(.secondary)
            }
            if !model.runningIDs.isEmpty {
                Label(l("It installs after the open games are quit.", "退出正在运行的游戏后再安装。"), systemImage: "gamecontroller")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(l("Later", "稍后")) { model.updateModel.later(release) }
                    .keyboardShortcut(.cancelAction)
                Button(l("Install and Relaunch", "安装并重新打开")) { Task { await model.updateModel.install(release) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
