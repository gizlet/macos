import GizletCore
import SwiftUI

/// Gizlet's own update and the installed apps' Store updates.
struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    @State private var checking = false

    var body: some View {
        let pending = model.apps.filter { model.appUpdates[$0.id] != nil }
        PageScroll(title: l("Updates", "更新")) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                UpdateSettings()
            }
            .padding(20)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(l("Games and Apps", "游戏和应用")).font(.title2.bold())
                    Spacer()
                    if pending.count > 1 {
                        Button(l("Update All", "全部更新")) {
                            Task { for app in pending { await model.upgrade(app.id) } }
                        }
                    }
                }
                if pending.isEmpty {
                    Text(checking ? l("Checking…", "正在检查…") : l("Everything from the Store is up to date.", "从商店安装的内容都是最新版本。"))
                        .foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    ForEach(pending) { app in
                        HStack(spacing: 14) {
                            AppIcon(file: app.icon, name: app.manifest.name, color: app.manifest.color, size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.manifest.name(for: l.tag)).font(.headline)
                                Text("\(app.manifest.version) → \(model.appUpdates[app.id]?.version ?? "")").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.busyApps.contains(app.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(l("Update", "更新")) { Task { await model.upgrade(app.id) } }
                                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                            }
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await refresh() } } label: { Label(l("Check for Updates", "检查更新"), systemImage: "arrow.clockwise") }
                    .disabled(checking)
                    .help(l("Check for updates", "检查更新"))
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        checking = true
        await model.checkAppUpdates()
        checking = false
    }
}
