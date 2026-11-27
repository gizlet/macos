import GizletCore
import SwiftUI

/// What is installed on this Mac, favorites and recently played first.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    @State private var selection: String?
    @State private var uninstalling: InstalledApp?
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        PageScroll(title: l("Library", "游戏库"), subtitle: l("\(model.profile.label)'s games and apps", "\(model.profile.label) 的游戏和应用")) {
            Picker(l("Show", "显示"), selection: $model.showFavoritesOnly) {
                Text(l("All", "全部")).tag(false)
                Text(l("Favorites", "收藏")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if model.apps.isEmpty {
                EmptyState(symbol: "gamecontroller", title: l("Your library is empty", "游戏库还是空的"),
                           message: l("Get games and apps that run on this Mac from Discover, or install a .gzl package from a file.",
                                      "从“发现”获取适合这台 Mac 的游戏和应用，或从文件安装 .gzl 软件包。")) {
                    HStack {
                        Button(l("Discover", "去发现")) { model.section = .discover }.buttonStyle(.borderedProminent)
                        Button(l("Install Package…", "安装软件包…")) { model.requestImport = true }
                    }
                }
            } else if model.visibleApps.isEmpty {
                EmptyState(symbol: "star", title: l("No favorites", "没有收藏"), message: l("Star a game to keep it at the front.", "收藏游戏，让它排在最前面。"))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 22)], alignment: .leading, spacing: 26) {
                    ForEach(model.visibleApps) { app in
                        LibraryTile(app: app, selected: selection == app.id)
                            .onTapGesture(count: 2) { model.launch(app) }
                            .simultaneousGesture(TapGesture().onEnded { selection = app.id; focused = true })
                            .contextMenu { menu(for: app) }
                    }
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.return) {
                    guard let app = model.visibleApps.first(where: { $0.id == selection }) else { return .ignored }
                    model.launch(app)
                    return .handled
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    move(press.key)
                    return .handled
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.requestImport = true } label: { Label(l("Install Package", "安装软件包"), systemImage: "square.and.arrow.down") }
                    .help(l("Install a .gzl package from a file", "从文件安装 .gzl 软件包"))
            }
        }
        .task {
            await model.storeModel.load()
            await model.checkAppUpdates()
        }
        .confirmationDialog(l("Uninstall \(uninstalling?.manifest.name(for: l.tag) ?? "")?", "卸载\(uninstalling?.manifest.name(for: l.tag) ?? "")？"),
                            isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }), presenting: uninstalling) { app in
            Button(l("Uninstall", "卸载"), role: .destructive) { model.uninstall(app.id) }
        } message: { _ in
            Text(l("Every profile keeps its saves of it, for when it is installed again.", "每个 Profile 都会保留它的存档，重新安装后可以继续使用。"))
        }
    }

    @ViewBuilder private func menu(for app: InstalledApp) -> some View {
        if model.isRunning(app.id) {
            Button(l("Quit", "退出")) { model.stop(app.id) }
        } else {
            Button(l("Play", "开始")) { model.launch(app) }
        }
        Button(model.isFavorite(app.id) ? l("Remove from Favorites", "取消收藏") : l("Add to Favorites", "收藏")) { model.toggleFavorite(app.id) }
        if model.appUpdates[app.id] != nil {
            Button(l("Update", "更新")) { Task { await model.upgrade(app.id) } }
        }
        Divider()
        Button(l("Show Saves in Finder", "在访达中显示存档")) {
            let saves = model.profileStore.saveDirectory(for: app.id)
            try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([saves])
        }
        Divider()
        Button(l("Uninstall…", "卸载…"), role: .destructive) { uninstalling = app }
    }

    private func move(_ key: KeyEquivalent) {
        let apps = model.visibleApps
        guard !apps.isEmpty else { return }
        guard let current = apps.firstIndex(where: { $0.id == selection }) else {
            selection = apps[0].id
            return
        }
        let step = key == .leftArrow ? -1 : key == .rightArrow ? 1 : key == .upArrow ? -3 : 3
        selection = apps[max(0, min(apps.count - 1, current + step))].id
    }
}

/// An installed game: its cover (or icon on its color), a play button under
/// the pointer, and its favorite star.
struct LibraryTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    let app: InstalledApp
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let name = app.manifest.name(for: l.tag)
        let running = model.isRunning(app.id)
        let cover = model.storeModel.cover(for: app.id)
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                CoverArt(url: cover, color: app.manifest.color, name: name, iconFile: cover == nil ? app.icon : nil, iconSize: 76)
                if hovering || running {
                    Color.black.opacity(0.35)
                    Button {
                        running ? model.stop(app.id) : model.launch(app)
                    } label: {
                        Image(systemName: running ? "stop.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .frame(width: 58, height: 58)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .help(running ? l("Quit", "退出") : l("Play", "开始"))
                    .accessibilityLabel(running ? l("Quit \(name)", "退出\(name)") : l("Play \(name)", "开始\(name)"))
                }
            }
            .overlay(alignment: .topLeading) {
                if running {
                    Label(l("Playing", "运行中"), systemImage: "circle.fill").font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4).background(.green, in: Capsule()).foregroundStyle(.white).padding(10)
                } else if model.appUpdates[app.id] != nil {
                    Text(l("Update", "可更新")).font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4).background(.blue, in: Capsule()).foregroundStyle(.white).padding(10)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0))
            .modifier(Lift())
            .onHover { hovering = $0 }

            HStack(spacing: 10) {
                AppIcon(file: app.icon, name: name, color: app.manifest.color, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.headline).lineLimit(1)
                    Text(model.busyApps.contains(app.id) ? l("Updating…", "正在更新…") : l("Version \(app.manifest.version)", "版本 \(app.manifest.version)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { model.toggleFavorite(app.id) } label: {
                    Image(systemName: model.isFavorite(app.id) ? "star.fill" : "star").foregroundStyle(model.isFavorite(app.id) ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(model.isFavorite(app.id) ? l("Remove from Favorites", "取消收藏") : l("Add to Favorites", "收藏"))
                .accessibilityLabel(model.isFavorite(app.id) ? l("Remove from Favorites", "取消收藏") : l("Add to Favorites", "收藏"))
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityAction(named: l("Play", "开始")) { model.launch(app) }
    }
}
