import AppKit
import GizletCore
import SwiftUI

/// The launcher's window and menus, shared by the Xcode app and the SwiftPM development build.
public struct GizletScene: Scene {
    @State private var model = AppModel()

    public init() {}

    public var body: some Scene {
        Window("Gizlet", id: "main") {
            RootView()
                .environment(model)
                .environment(\.l, model.l)
                .environment(\.locale, model.l.locale)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { url in
                    if url.isFileURL, url.pathExtension == "gzl" { model.importPackage(url) }
                }
                .onAppear {
                    model.applyAppearance()
                    model.updateModel.start()
                    model.flashModel.start()
                }
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { GizletCommands(model: model) }
    }
}

struct GizletCommands: Commands {
    let model: AppModel

    var body: some Commands {
        let l = model.l
        CommandGroup(replacing: .appSettings) {
            Button(l("Settings…", "设置…")) { go(.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .appInfo) {
            Button(l("Check for Updates…", "检查更新…")) {
                go(.updates)
                Task { await model.updateModel.check(manual: true) }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button(l("Install Package…", "安装软件包…")) { model.requestImport = true }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandMenu(l("Go", "前往")) {
            ForEach(Array((Page.store + Page.device).enumerated()), id: \.element) { index, page in
                Button(page.title(l)) { go(page) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }

    private func go(_ page: Page) {
        model.storeModel.query = ""
        model.storeModel.path = []
        model.section = page
    }
}
