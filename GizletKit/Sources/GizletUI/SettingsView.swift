import GizletCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    @State private var naming: NamingRequest?
    @State private var deleting: Profile?

    struct NamingRequest: Identifiable {
        var id = UUID()
        var profile: Profile?
        var name: String
    }

    var body: some View {
        Form {
            SwiftUI.Section(l("General", "通用")) {
                Picker(l("Language", "语言"), selection: Binding(get: { model.settings.language }, set: { value in model.update { $0.language = value } })) {
                    Text(l("System", "跟随系统")).tag(ProfileSettings.Language.system)
                    Text("English").tag(ProfileSettings.Language.english)
                    Text("简体中文").tag(ProfileSettings.Language.chinese)
                }
                Picker(l("Appearance", "外观"), selection: Binding(get: { model.settings.appearance }, set: { value in model.update { $0.appearance = value } })) {
                    Text(l("System", "跟随系统")).tag(ProfileSettings.Appearance.system)
                    Text(l("Light", "浅色")).tag(ProfileSettings.Appearance.light)
                    Text(l("Dark", "深色")).tag(ProfileSettings.Appearance.dark)
                }
                .pickerStyle(.segmented)
                Toggle(l("Open Gizlet at login", "登录时打开 Gizlet"), isOn: Binding(get: { model.updateModel.opensAtLogin }, set: { model.updateModel.opensAtLogin = $0 }))
            }

            SwiftUI.Section {
                ForEach(model.profileList) { profile in
                    HStack {
                        Image(systemName: profile.id == model.profile.id ? "person.crop.circle.fill" : "person.crop.circle").foregroundStyle(.tint)
                        Text(profile.label)
                        if profile.id == model.profile.id { Text(l("In use", "使用中")).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if profile.id != model.profile.id {
                            Button(l("Switch", "切换")) { model.switchProfile(profile.id) }
                        }
                        Menu {
                            Button(l("Rename…", "重命名…")) { naming = NamingRequest(profile: profile, name: profile.name) }
                            Button(l("Delete…", "删除…"), role: .destructive) { deleting = profile }
                                .disabled(profile.id == model.profile.id)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(l("More for \(profile.label)", "\(profile.label) 的更多操作"))
                    }
                }
                Button(l("New Profile…", "新建 Profile…")) { naming = NamingRequest(profile: nil, name: "") }
            } header: {
                Text(l("Profiles", "Profiles"))
            } footer: {
                Text(l("Installed apps are shared. Each profile keeps its own saves, favorites, language and appearance; switching takes effect at once.",
                       "已安装的应用由所有 Profile 共享，每个 Profile 有自己的存档、收藏、语言和外观，切换后立即生效。"))
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section(l("Updates", "更新")) { UpdateSettings() }

            SwiftUI.Section(l("About", "关于")) {
                LabeledContent(l("Version", "版本"), value: model.updateModel.currentVersion)
                LabeledContent(l("This Mac runs", "这台 Mac 支持"), value: model.platform.targets.joined(separator: ", "))
                LabeledContent(l("Data folder", "数据文件夹")) {
                    Button(model.root.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { NSWorkspace.shared.open(model.root.url) }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(l("Settings", "设置"))
        .sheet(item: $naming) { request in ProfileNameSheet(request: request) }
        .confirmationDialog(l("Delete \(deleting?.label ?? "")?", "删除\(deleting?.label ?? "")？"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { profile in
            Button(l("Delete Profile", "删除 Profile"), role: .destructive) { model.deleteProfile(profile.id) }
        } message: { _ in
            Text(l("Its saves, favorites and settings are deleted. Installed apps stay.", "它的存档、收藏和设置都会被删除，已安装的应用会保留。"))
        }
    }
}

struct ProfileNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    @Environment(\.dismiss) private var dismiss
    let request: SettingsView.NamingRequest
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.profile == nil ? l("New Profile", "新建 Profile") : l("Rename Profile", "重命名 Profile")).font(.title3.bold())
            TextField(l("Name", "名称"), text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            if let problem = Profiles.nameProblem(name), !name.isEmpty {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(l("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.profile == nil ? l("Create", "创建") : l("Rename", "重命名"), action: save)
                    .keyboardShortcut(.defaultAction).disabled(Profiles.nameProblem(name) != nil)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { name = request.name }
    }

    private func save() {
        guard Profiles.nameProblem(name) == nil else { return }
        let ok = request.profile.map { model.renameProfile($0.id, to: name) } ?? model.createProfile(name)
        if ok { dismiss() }
    }
}

struct UpdateSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l

    var body: some View {
        let updates = model.updateModel!
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                switch updates.state {
                case .idle, .checking:
                    Text(l("Checking for updates…", "正在检查更新…"))
                case .upToDate:
                    Text(l("Gizlet \(updates.currentVersion) is up to date", "Gizlet \(updates.currentVersion) 已是最新版本"))
                case .available(let release):
                    Text(l("Gizlet \(release.version) is available", "Gizlet \(release.version) 已推出")).bold()
                case .downloading(let release, let fraction):
                    Text(l("Downloading \(release.version)…", "正在下载 \(release.version)…"))
                    ProgressView(value: fraction).frame(maxWidth: 240)
                case .waitingForFlash(let release):
                    Text(l("\(release.version) installs when the card is written", "\(release.version) 将在写卡完成后安装"))
                case .waitingForApps(let release):
                    Text(l("\(release.version) installs when the open games are quit", "\(release.version) 将在退出正在运行的游戏后安装"))
                case .installing(let release):
                    Text(l("Installing \(release.version)…", "正在安装 \(release.version)…"))
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                }
                if let checked = updates.lastChecked {
                    Text(l("Checked \(checked.formatted(date: .omitted, time: .shortened)); checks every 2 minutes", "上次检查 \(checked.formatted(date: .omitted, time: .shortened))，每 2 分钟检查一次"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if case .available(let release) = updates.state {
                Button(l("Install…", "安装…")) { updates.prompt = release }.buttonStyle(.borderedProminent)
            } else {
                Button(l("Check Now", "立即检查")) { Task { await updates.check(manual: true) } }.disabled(updates.isBusy)
            }
        }
    }
}
