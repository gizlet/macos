import GizletCore
import SwiftUI

struct FlashView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    @State private var choosingFile = false

    var body: some View {
        @Bindable var flash = model.flashModel
        Form {
            SwiftUI.Section(l("Image", "镜像")) {
                Picker(l("Source", "来源"), selection: Binding(get: { flash.source == .latest ? 0 : 1 }, set: { choice in
                    if choice == 0 { flash.source = .latest } else { choosingFile = true }
                })) {
                    Text(l("Latest Gizlet OS release", "最新 Gizlet OS 版本")).tag(0)
                    Text(l("Local file…", "本地文件…")).tag(1)
                }
                .pickerStyle(.radioGroup)
                .disabled(flash.isBusy)
                switch flash.source {
                case .latest:
                    if let release = flash.release {
                        LabeledContent(l("Version", "版本"), value: release.tag)
                    } else if let error = flash.releaseError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        Button(l("Try Again", "重试")) { Task { await flash.loadRelease() } }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .file(let url):
                    LabeledContent(l("File", "文件"), value: url.lastPathComponent)
                    if let prepared = flash.prepared, !prepared.isGizletR36S {
                        Label(l("This image does not look like Gizlet OS for the R36S.", "这个镜像看起来不是 R36S 的 Gizlet OS。"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            SwiftUI.Section {
                if flash.listedDisks.isEmpty {
                    Label(l("Insert the R36S's TF card, in a card reader if needed.", "请插入 R36S 的 TF 卡，必要时使用读卡器。"), systemImage: "sdcard")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(flash.listedDisks) { disk in
                        DiskRow(disk: disk, selected: flash.selection == disk.bsdName)
                            .contentShape(Rectangle())
                            .onTapGesture { if flash.problem(disk) == nil && !flash.isBusy { flash.selection = disk.bsdName } }
                    }
                }
            } header: {
                Text(l("Card", "卡片"))
            } footer: {
                Text(l("The startup disk and internal disks are never listed as choices.", "启动磁盘和内置磁盘永远不会作为可选项。")).foregroundStyle(.secondary)
            }

            if flash.selectedDisk != nil {
                SwiftUI.Section(l("Display", "屏幕")) { PanelPicker() }
            }

            SwiftUI.Section { FlashProgress() }
        }
        .formStyle(.grouped)
        .navigationTitle(l("Flash", "刷机"))
        .navigationSubtitle(l("Gizlet OS for the R36S", "R36S 的 Gizlet OS"))
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.diskImage, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                _ = url.startAccessingSecurityScopedResource()
                flash.source = .file(url)
            }
        }
        .alert(confirmTitle, isPresented: Binding(get: { flash.confirming != nil }, set: { if !$0 { flash.confirming = nil } })) {
            if flash.confirming?.isUnusuallyLarge == true {
                TextField(flash.confirming?.bsdName ?? "", text: $flash.typedName)
            }
            Button(l("Erase and Write", "清空并写入"), role: .destructive) {
                if let disk = flash.confirming { Task { await flash.write(confirmed: disk.identity) } }
            }
            .disabled(flash.confirming?.isUnusuallyLarge == true && flash.typedName != flash.confirming?.bsdName)
            Button(l("Cancel", "取消"), role: .cancel) { flash.confirming = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmTitle: String {
        l("Erase \(model.flashModel.confirming?.displayName ?? "")?", "清空\(model.flashModel.confirming?.displayName ?? "")？")
    }

    private var confirmMessage: String {
        guard let disk = model.flashModel.confirming else { return "" }
        let volumes = disk.volumeNames.isEmpty ? "" : l(" (\(disk.volumeNames.joined(separator: ", ")))", "（\(disk.volumeNames.joined(separator: "、"))）")
        var text = l("Everything on \(disk.bsdName), \(l.bytes(disk.size))\(volumes), is erased and cannot be recovered. macOS asks for an administrator password to write it.",
                     "\(disk.bsdName)（\(l.bytes(disk.size))）\(volumes)上的所有数据都会被清除，无法恢复。写入时 macOS 会要求输入管理员密码。")
        if disk.isUnusuallyLarge {
            text += l("\n\nThis disk is over 256 GB, which a TF card rarely is. Type \(disk.bsdName) to confirm.",
                      "\n\n这个磁盘超过 256 GB，TF 卡很少这么大。请输入 \(disk.bsdName) 以确认。")
        }
        if disk.volumeNames.contains("ROMS") {
            text += l("\n\nThis looks like a stock ArkOS card; its games will be lost.", "\n\n这看起来是原厂 ArkOS 卡，上面的游戏会全部丢失。")
        }
        return text
    }
}

struct DiskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l
    let disk: DiskInfo
    let selected: Bool

    var body: some View {
        let flash = model.flashModel!
        let problem = flash.problem(disk)
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(problem == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)
            Image(systemName: disk.protocolName == "Secure Digital" ? "sdcard.fill" : "externaldrive.fill").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(disk.displayName) · \(l.bytes(disk.size))").font(.headline)
                Text(details(problem)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if disk.isUnusuallyLarge, problem == nil {
                Label(l("Over 256 GB", "超过 256 GB"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
        }
        .opacity(problem == nil ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func details(_ problem: String?) -> String {
        var parts = [disk.bsdName]
        if !disk.volumeNames.isEmpty { parts.append(disk.volumeNames.joined(separator: ", ")) }
        if let detection = model.flashModel.panels[disk.bsdName] {
            let panel = l("Panel \(detection.panel.number) (\(detection.panel.controller))", "Panel \(detection.panel.number)（\(detection.panel.controller)）")
            parts.append(detection.source == .stockFirmware ? l("stock card: \(panel)", "原厂卡：\(panel)") : l("Gizlet OS: \(panel)", "Gizlet OS：\(panel)"))
        }
        if let problem { parts.append(l("cannot be written: \(problem)", "不可写入：\(problem)")) }
        return parts.joined(separator: " · ")
    }
}

struct PanelPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l

    var body: some View {
        @Bindable var flash = model.flashModel
        let detection = flash.selection.flatMap { flash.panels[$0] }
        let localImage: Bool = { if case .file = flash.source { return true } else { return false } }()
        Picker(l("Screen", "屏幕"), selection: Binding(get: { flash.effectivePanel?.rawValue ?? "keep" }, set: { flash.panelChoice = R36SPanel(rawValue: $0) })) {
            if localImage { Text(l("Keep the image's setting", "保留镜像自带设置")).tag("keep") }
            Text(l("Panel 4 (NV3051D): V30 boards and most current units", "Panel 4（NV3051D）：V30 主板和目前大多数机器")).tag(R36SPanel.panel4.rawValue)
            Text(l("Panel 0 (ST7703): earlier units", "Panel 0（ST7703）：较早的机器")).tag(R36SPanel.panel0.rawValue)
        }
        .disabled(flash.isBusy)
        Group {
            switch detection?.source {
            case .stockFirmware?:
                Text(l("Found from the stock card's kernel dtb. If the screen stays black after boot, write the card again with the other panel.",
                       "已根据原厂卡的内核 dtb 识别。如果开机后屏幕一直黑屏，换另一种屏幕重新写卡。"))
            case .gizletCard?:
                Text(l("This card was written for this panel before. If its screen stayed black, choose the other one.",
                       "这张卡上次就是为这种屏幕写入的。如果之前黑屏，请换另一种。"))
            case nil:
                Text(l("Writing over the stock card finds this by itself. If the screen stays black after boot, write the card again with the other choice.",
                       "直接写原厂卡时会自动识别。如果开机后屏幕一直黑屏，换另一个选项重新写卡。"))
            }
        }
        .font(.callout).foregroundStyle(.secondary)
    }
}

struct FlashProgress: View {
    @Environment(AppModel.self) private var model
    @Environment(\.l) private var l

    var body: some View {
        let flash = model.flashModel!
        VStack(alignment: .leading, spacing: 12) {
            steps(flash.step)
            HStack {
                switch flash.step {
                case .done, .failed, .doneNotEjected:
                    Button(l("Done", "完成")) { flash.reset() }
                case .writing, .verifying:
                    Button(l("Stop", "停止"), role: .destructive) { flash.cancel() }
                default:
                    EmptyView()
                }
                Spacer()
                Button(l("Write to Card…", "写入卡片…")) { Task { await flash.requestWrite() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(flash.selectedDisk.map { flash.problem($0) != nil } ?? true || flash.isBusy)
            }
        }
    }

    @ViewBuilder private func steps(_ step: FlashModel.Step) -> some View {
        switch step {
        case .idle:
            Text(l("Checks the image, writes the card, then reads it all back to compare.", "先校验镜像，再写入卡片，最后完整读回比对。")).foregroundStyle(.secondary)
        case .preparing(let phase, let fraction):
            row(phase == .downloading ? l("Downloading the image", "正在下载镜像") : phase == .verifying ? l("Checking the image", "正在校验镜像") : l("Unpacking and checking the image", "正在解压并校验镜像"), fraction)
        case .authorizing:
            row(l("Waiting for administrator authorization", "等待管理员授权"), nil)
        case .writing(let fraction):
            row(l("Writing", "正在写入"), fraction)
        case .verifying(let fraction):
            row(l("Reading back and comparing", "正在读回比对"), fraction)
        case .configuring:
            row(l("Setting up the display", "正在配置屏幕"), nil)
        case .done(let name):
            Label(l("Done: \(name) is written and verified, and safe to remove. Put it in the R36S and switch it on.",
                    "完成：\(name) 已写入并校验，可以安全取出。把卡插进 R36S 开机。"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .doneNotEjected(let name, _):
            VStack(alignment: .leading, spacing: 8) {
                Label(l("\(name) is written and verified, but it could not be ejected: a window or app is still using it. Close it, then eject the card before removing it.",
                        "\(name) 已写入并校验，但无法推出：仍有窗口或应用在使用它。请关闭后推出卡片，再取出。"),
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button(l("Eject", "推出")) { Task { await model.flashModel.ejectAgain() } }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func row(_ title: String, _ fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let fraction {
                ProgressView(value: fraction) { EmptyView() } currentValueLabel: { Text(fraction.formatted(.percent.precision(.fractionLength(0)))) }
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
