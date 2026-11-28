import Darwin
import Foundation

/// The R36S's LCD panels Gizlet OS drives. The stock firmware numbers them.
public enum R36SPanel: String, CaseIterable, Sendable {
    /// NewVision NV3051D: later V12 boards and V21, V22 and V30 boards.
    case panel4 = "v30-panel4"
    /// Sitronix ST7703: early V12 boards. The device tree describes it, so it needs no overlay.
    case panel0 = "original"

    public var controller: String { self == .panel4 ? "NV3051D" : "ST7703" }
    public var number: Int { self == .panel4 ? 4 : 0 }
    /// The overlay a card carries for this panel, copied to `mipi-panel.dtbo` to select it.
    public var overlay: String? { self == .panel4 ? "r36s-v30-panel4.dtbo" : nil }
}

/// What a card says about its handheld's panel.
public struct PanelDetection: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// A stock card's kernel dtb names the controller: taken without a question.
        case stockFirmware
        /// A Gizlet OS card was written for this panel, which may be the wrong one being corrected.
        case gizletCard
    }

    public var panel: R36SPanel
    public var source: Source
}

/// Reads a card's FAT boot partition, as gizlet/os's `flash.sh` does: a Gizlet
/// OS card (`GIZLETBOOT`) keeps `mipi-panel.dtbo` as a copy of one overlay
/// beside it, or none for Panel 0; a stock card's `boot.ini` loads kernel dtbs
/// whose panel init sequence starts with the controller's own command.
public enum PanelDetector {
    public static func detect(bootVolume: URL, volumeName: String?) -> PanelDetection? {
        let fm = FileManager.default
        if volumeName == "GIZLETBOOT" {
            let selected = bootVolume.appendingPathComponent("mipi-panel.dtbo")
            guard let chosen = fm.contents(atPath: selected.path) else { return PanelDetection(panel: .panel0, source: .gizletCard) }
            for panel in R36SPanel.allCases {
                if let overlay = panel.overlay, fm.contents(atPath: bootVolume.appendingPathComponent(overlay).path) == chosen {
                    return PanelDetection(panel: panel, source: .gizletCard)
                }
            }
            return nil
        }
        guard let bootINI = fm.contents(atPath: bootVolume.appendingPathComponent("boot.ini").path) else { return nil }
        let names = dtbNames(in: String(decoding: bootINI, as: UTF8.self))
        var found: R36SPanel?
        for name in names {
            guard name.range(of: #"^[A-Za-z0-9_-][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
                  let dtb = fm.contents(atPath: bootVolume.appendingPathComponent(name).path),
                  let panel = panel(ofDTB: dtb), found == nil || found == panel else { return nil }
            found = panel
        }
        return found.map { PanelDetection(panel: $0, source: .stockFirmware) }
    }

    /// Makes a Gizlet OS boot volume select `panel`: Panel 4's overlay copied
    /// to `mipi-panel.dtbo` (as plain bytes: FAT would keep extended attributes
    /// as `._` files), or for Panel 0 any `mipi-panel.dtbo` removed.
    public static func select(_ panel: R36SPanel, onBootVolume volume: URL, device: String) throws {
        try select(panel, onBootVolume: volume, expectedDevice: device)
    }

    static func select(_ panel: R36SPanel, onBootVolume volume: URL, expectedDevice: String? = nil) throws {
        let directory = open(volume.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw FlashError.write("Cannot open the boot volume") }
        defer { close(directory) }
        if let expectedDevice {
            var mount = statfs()
            guard fstatfs(directory, &mount) == 0 else { throw FlashError.write("Cannot identify the boot volume") }
            let type = withUnsafeBytes(of: mount.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let source = withUnsafeBytes(of: mount.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard type == "msdos", source == "/dev/\(expectedDevice)" else {
                throw FlashError.write("Expected a FAT boot volume on \(expectedDevice)")
            }
        }
        let selected = "mipi-panel.dtbo"
        var targetInfo = stat()
        if fstatat(directory, selected, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0 {
            guard targetInfo.st_mode & S_IFMT == S_IFREG else { throw FlashError.write("Invalid \(selected)") }
        } else if errno != ENOENT {
            throw FlashError.write("Cannot check \(selected)")
        }
        guard let overlay = panel.overlay else {
            if unlinkat(directory, selected, 0) != 0, errno != ENOENT { throw FlashError.write("Cannot remove \(selected)") }
            return
        }
        let input = openat(directory, overlay, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw FlashError.write("Cannot open \(overlay)") }
        let inputFile = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        var inputInfo = stat()
        let limit = 1 << 20
        guard fstat(input, &inputInfo) == 0, inputInfo.st_mode & S_IFMT == S_IFREG,
              let data = try inputFile.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else {
            throw FlashError.write("Invalid \(overlay)")
        }
        let temporary = ".panel-\(UUID().uuidString)"
        let output = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o644))
        guard output >= 0 else { throw FlashError.write("Cannot stage \(selected)") }
        defer { _ = unlinkat(directory, temporary, 0) }
        let outputFile = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        try outputFile.write(contentsOf: data)
        try outputFile.synchronize()
        try outputFile.close()
        guard renameat(directory, temporary, directory, selected) == 0 else {
            throw FlashError.write("Cannot replace \(selected)")
        }
    }

    /// The files `boot.ini` loads at `${dtb_loadaddr}`: `load mmc 1:1 ${dtb_loadaddr} NAME`.
    static func dtbNames(in bootINI: String) -> [String] {
        bootINI.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.replacingOccurrences(of: "\r", with: "").split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 5, fields[0] == "load" || fields[0] == "fatload", fields[3].contains("dtb_loadaddr") else { return nil }
            return String(fields[4])
        }
    }

    /// Panel 4 or Panel 0 by the first command of a dtb's `panel-init-sequence`,
    /// in Rockchip's format right after the property's 12-byte header:
    /// NV3051D's page select `FF 30`, `FF 52`, `FF 01`, or ST7703's `B9 F1 12 83`.
    static func panel(ofDTB dtb: Data) -> R36SPanel? {
        let bytes = [UInt8](dtb)
        let nv: [UInt8] = [0x15, 0x00, 0x02, 0xFF, 0x30, 0x15, 0x00, 0x02, 0xFF, 0x52, 0x15, 0x00, 0x02, 0xFF, 0x01]
        let st: [UInt8] = [0x39, 0x00, 0x04, 0xB9, 0xF1, 0x12, 0x83]
        let isNV = matches(bytes, nv), isST = matches(bytes, st)
        switch (isNV, isST) {
        case (true, false): return .panel4
        case (false, true): return .panel0
        default: return nil
        }
    }

    /// `00 00 00 03`, eight bytes (the property's length and name offset), then `sequence`.
    private static func matches(_ bytes: [UInt8], _ sequence: [UInt8]) -> Bool {
        let total = 12 + sequence.count
        guard bytes.count >= total else { return false }
        for start in 0...(bytes.count - total) where bytes[start] == 0 && bytes[start + 1] == 0 && bytes[start + 2] == 0 && bytes[start + 3] == 3 {
            if bytes[(start + 12)..<(start + total)].elementsEqual(sequence) { return true }
        }
        return false
    }
}
