import Foundation
@testable import GizletCore
import Testing

@Suite struct ImageTests {
    func image(_ size: Int, r36s: Bool = true) -> Data {
        var data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })
        if r36s {
            data.replaceSubrange(440..<444, with: [0x30, 0x50, 0x33, 0x36])
            data[510] = 0x55
            data[511] = 0xAA
        }
        return data
    }

    @Test func unpacksAGzipImageAndHashesIt() async throws {
        let directory = try temporaryDirectory()
        let raw = image(3 << 20)
        let gz = try runTool("/usr/bin/gzip", ["-c"], input: raw)
        let file = try write(gz, to: directory, name: "card.img.gz")
        let prepared = try await ImagePreparer(cache: directory.appendingPathComponent("cache")).prepare(.file(file)) { _, _, _ in }
        #expect(prepared.size == UInt64(raw.count))
        #expect(prepared.sha256 == sha256(of: raw))
        #expect(prepared.isGizletR36S)
        #expect(try Data(contentsOf: prepared.url) == raw)
    }

    @Test func readsMultipleGzipMembers() throws {
        var decoder = GzipDecoder()
        var out = Data()
        let first = try runTool("/usr/bin/gzip", ["-c"], input: Data("hello ".utf8))
        let second = try runTool("/usr/bin/gzip", ["-c"], input: Data("world".utf8))
        for byte in first + second { try decoder.feed(Data([byte])) { out.append(contentsOf: $0) } }
        try decoder.finish()
        #expect(String(decoding: out, as: UTF8.self) == "hello world")
    }

    @Test func refusesACorruptOrShortGzipImage() async throws {
        let directory = try temporaryDirectory()
        var gz = try runTool("/usr/bin/gzip", ["-c"], input: image(1 << 20))
        gz[gz.count - 6] ^= 0xFF
        let preparer = ImagePreparer(cache: directory.appendingPathComponent("cache"))
        await #expect(throws: FlashError.self) { try await preparer.prepare(.file(try write(gz, to: directory, name: "bad.img.gz"))) { _, _, _ in } }
        let whole = try runTool("/usr/bin/gzip", ["-c"], input: image(1 << 20))
        let short = Data(whole.prefix(whole.count / 2))
        await #expect(throws: (any Error).self) { try await preparer.prepare(.file(try write(short, to: directory, name: "short.img.gz"))) { _, _, _ in } }
        let noTrailer = Data(whole.dropLast(8))
        await #expect(throws: FlashError.self) { try await preparer.prepare(.file(try write(noTrailer, to: directory, name: "trailerless.img.gz"))) { _, _, _ in } }
        // No partial image is left in the cache.
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("cache/local/card.img").path))
    }

    @Test func takesARawImageAsItIs() async throws {
        let directory = try temporaryDirectory()
        let raw = image(1 << 20, r36s: false)
        let file = try write(raw, to: directory, name: "other.img")
        let prepared = try await ImagePreparer(cache: directory.appendingPathComponent("cache")).prepare(.file(file)) { _, _, _ in }
        #expect(prepared.url == file)
        #expect(!prepared.isGizletR36S)
    }

    @Test func downloadsAReleaseImageAgainstItsSignedDigest() async throws {
        let directory = try temporaryDirectory()
        let gz = try runTool("/usr/bin/gzip", ["-c"], input: image(1 << 20))
        let url = URL(string: "https://dl.test/releases/v9.9.9/boards/gameconsole/r36s/gizlet-os-r36s.img.gz")!
        let session = StubProtocol.session([url.absoluteString: .init(status: 200, body: gz)])
        let release = OSImageRelease(tag: "v9.9.9", image: url, sha256: sha256(of: gz), bytes: UInt64(gz.count))
        let prepared = try await ImagePreparer(cache: directory, session: session).prepare(.release(release)) { _, _, _ in }
        #expect(prepared.releaseTag == "v9.9.9")
        #expect(prepared.size == 1 << 20)

        // The server sends other bytes than the release signed.
        var tampered = gz
        tampered[tampered.count / 2] ^= 0x55
        StubProtocol.responses[url.absoluteString] = .init(status: 200, body: tampered)
        try FileManager.default.removeItem(at: directory)
        await #expect(throws: FlashError.self) { try await ImagePreparer(cache: directory, session: session).prepare(.release(release)) { _, _, _ in } }
    }
}

@Suite struct PanelTests {
    func dtb(_ sequence: [UInt8]) -> Data {
        Data([0xD0, 0x0D, 0xFE, 0xED, 0, 0, 0, 3, 0, 0, 0, 0x40, 0, 0, 0x01, 0x23] + sequence + [0, 0, 0, 9])
    }

    let nv: [UInt8] = [0x15, 0x00, 0x02, 0xFF, 0x30, 0x15, 0x00, 0x02, 0xFF, 0x52, 0x15, 0x00, 0x02, 0xFF, 0x01]
    let st: [UInt8] = [0x39, 0x00, 0x04, 0xB9, 0xF1, 0x12, 0x83]

    @Test func tellsPanelsFromStockDTBs() throws {
        #expect(PanelDetector.panel(ofDTB: dtb(nv)) == .panel4)
        #expect(PanelDetector.panel(ofDTB: dtb(st)) == .panel0)
        #expect(PanelDetector.panel(ofDTB: dtb([0x05, 0x78, 0x01, 0x11])) == nil)
        #expect(PanelDetector.panel(ofDTB: dtb(nv) + dtb(st)) == nil)
    }

    @Test func readsAStockCard() throws {
        let boot = try temporaryDirectory()
        try Data("setenv x 1\r\nload mmc 1:1 ${dtb_loadaddr} rk3326-r35s-linux.dtb\r\nload mmc 1:1 ${loadaddr} Image\r\n".utf8).write(to: boot.appendingPathComponent("boot.ini"))
        try dtb(nv).write(to: boot.appendingPathComponent("rk3326-r35s-linux.dtb"))
        #expect(PanelDetector.detect(bootVolume: boot, volumeName: "BOOT") == PanelDetection(panel: .panel4, source: .stockFirmware))
        try Data("load mmc 1:1 ${dtb_loadaddr} ../x.dtb\n".utf8).write(to: boot.appendingPathComponent("boot.ini"))
        #expect(PanelDetector.detect(bootVolume: boot, volumeName: "BOOT") == nil)
    }

    @Test func readsAGizletCard() throws {
        let boot = try temporaryDirectory()
        #expect(PanelDetector.detect(bootVolume: boot, volumeName: "GIZLETBOOT") == PanelDetection(panel: .panel0, source: .gizletCard))
        try Data("overlay".utf8).write(to: boot.appendingPathComponent("r36s-v30-panel4.dtbo"))
        try Data("overlay".utf8).write(to: boot.appendingPathComponent("mipi-panel.dtbo"))
        #expect(PanelDetector.detect(bootVolume: boot, volumeName: "GIZLETBOOT") == PanelDetection(panel: .panel4, source: .gizletCard))
        try Data("custom".utf8).write(to: boot.appendingPathComponent("mipi-panel.dtbo"))
        #expect(PanelDetector.detect(bootVolume: boot, volumeName: "GIZLETBOOT") == nil)
    }
}

@Suite struct PanelSelectionTests {
    @Test func refusesSymlinksInTheBootVolume() throws {
        let boot = try temporaryDirectory()
        let outside = try temporaryDirectory().appendingPathComponent("outside.dtbo")
        let original = Data("outside the card".utf8)
        try original.write(to: outside)
        let overlay = boot.appendingPathComponent("r36s-v30-panel4.dtbo")
        let selected = boot.appendingPathComponent("mipi-panel.dtbo")
        try FileManager.default.createSymbolicLink(at: overlay, withDestinationURL: outside)
        #expect(throws: FlashError.self) { try PanelDetector.select(.panel4, onBootVolume: boot) }
        try FileManager.default.removeItem(at: overlay)
        try Data("panel 4".utf8).write(to: overlay)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)
        #expect(throws: FlashError.self) { try PanelDetector.select(.panel4, onBootVolume: boot) }
        #expect(try Data(contentsOf: outside) == original)
    }

    @Test func requiresTheExpectedFATDevice() throws {
        let boot = try temporaryDirectory()
        let selected = boot.appendingPathComponent("mipi-panel.dtbo")
        try Data("existing overlay".utf8).write(to: selected)
        #expect(throws: FlashError.self) { try PanelDetector.select(.panel0, onBootVolume: boot, device: "disk99s1") }
        #expect(FileManager.default.fileExists(atPath: selected.path))
    }

    @Test func selectsEachPanelOnTheBootVolume() throws {
        let boot = try temporaryDirectory()
        try Data("panel 4".utf8).write(to: boot.appendingPathComponent("r36s-v30-panel4.dtbo"))
        try PanelDetector.select(.panel4, onBootVolume: boot)
        #expect(FileManager.default.contents(atPath: boot.appendingPathComponent("mipi-panel.dtbo").path) == Data("panel 4".utf8))
        #expect(PanelDetector.detect(bootVolume: boot, volumeName: "GIZLETBOOT")?.panel == .panel4)
        // Panel 0 is the device tree's own: no overlay may stay selected.
        try PanelDetector.select(.panel0, onBootVolume: boot)
        #expect(!FileManager.default.fileExists(atPath: boot.appendingPathComponent("mipi-panel.dtbo").path))
        #expect(PanelDetector.detect(bootVolume: boot, volumeName: "GIZLETBOOT")?.panel == .panel0)
        try PanelDetector.select(.panel0, onBootVolume: boot)
        // A card without the overlay cannot be set to Panel 4.
        try FileManager.default.removeItem(at: boot.appendingPathComponent("r36s-v30-panel4.dtbo"))
        #expect(throws: FlashError.self) { try PanelDetector.select(.panel4, onBootVolume: boot) }
    }
}

@Suite struct DiskTests {
    func card(_ change: (inout DiskInfo) -> Void = { _ in }) -> DiskInfo {
        var disk = DiskInfo(bsdName: "disk4", mediaName: "SD Card", vendor: "Apple", model: "SDXC Reader", size: 32_000_000_000, blockSize: 512,
                            isRemovable: true, isEjectable: true, isInternal: true, isWritable: true, protocolName: "Secure Digital",
                            isVirtual: false, isSynthesized: false, appearanceTime: 1, volumes: [])
        change(&disk)
        return disk
    }

    @Test func allowsRemovableCardsOnly() {
        #expect(diskProblem(card(), protected: []) == nil)
        #expect(diskProblem(card { $0.isInternal = false; $0.protocolName = "USB" }, protected: []) == nil)
        #expect(diskProblem(card(), protected: ["disk4"]) != nil)
        #expect(diskProblem(card { $0.isRemovable = false; $0.isEjectable = false; $0.isInternal = true }, protected: []) != nil)
        #expect(diskProblem(card { $0.isRemovable = false; $0.isEjectable = false; $0.isInternal = false }, protected: []) != nil)
        #expect(diskProblem(card { $0.isVirtual = true }, protected: []) != nil)
        #expect(diskProblem(card { $0.isVirtual = true }, protected: [], allowDiskImages: true) == nil)
        #expect(diskProblem(card { $0.isSynthesized = true }, protected: []) != nil)
        #expect(diskProblem(card { $0.isWritable = false }, protected: []) != nil)
        #expect(diskProblem(card { $0.bsdName = "disk4s1" }, protected: []) != nil)
        #expect(diskProblem(card { $0.size = 100 << 20 }, protected: []) != nil)
        #expect(card { $0.size = 512_000_000_000 }.isUnusuallyLarge)
    }

    @Test func protectsTheStartupDisk() {
        let protected = protectedDisks()
        #expect(!protected.isEmpty)
        #expect(protected.allSatisfy { $0.hasPrefix("disk") })
    }
}

@Suite struct WriterTests {
    @Test func writesAndReadsBackAnImage() throws {
        let directory = try temporaryDirectory()
        let raw = Data((0..<(9 << 20) + 100).map { UInt8(truncatingIfNeeded: $0 >> 3) })
        let imageURL = try write(raw, to: directory, name: "card.img")
        let image = PreparedImage(url: imageURL, size: UInt64(raw.count), sha256: sha256(of: raw), isGizletR36S: false, releaseTag: nil)
        let card = directory.appendingPathComponent("card")
        try Data(repeating: 0xEE, count: 16 << 20).write(to: card)
        let descriptor = open(card.path, O_RDWR)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        var phases: [WritePhase] = []
        try CardWriter().write(image, to: descriptor, blockSize: 512, capacity: 16 << 20) { phase, _, _ in
            if phases.last != phase { phases.append(phase) }
        }
        #expect(phases == [.writing, .verifying])
        let written = try Data(contentsOf: card)
        #expect(written.prefix(raw.count) == raw)
        // The last sector is padded with zeros.
        let padEnd = (raw.count + 511) / 512 * 512
        #expect(written[raw.count..<padEnd].allSatisfy { $0 == 0 })
        #expect(written[padEnd] == 0xEE)
    }

    @Test func refusesAnImageThatChangedSinceItWasChecked() throws {
        let directory = try temporaryDirectory()
        let checked = Data(repeating: 1, count: 1 << 20)
        let imageURL = try write(checked, to: directory, name: "card.img")
        let image = PreparedImage(url: imageURL, size: UInt64(checked.count), sha256: sha256(of: checked), isGizletR36S: false, releaseTag: nil)
        let card = directory.appendingPathComponent("card")
        try Data(count: 4 << 20).write(to: card)
        let descriptor = open(card.path, O_RDWR)
        defer { close(descriptor) }
        // A larger file put in its place: refused before anything is written.
        try Data(repeating: 2, count: 2 << 20).write(to: imageURL)
        #expect(throws: FlashError.self) { try CardWriter().write(image, to: descriptor, blockSize: 512, capacity: 4 << 20) { _, _, _ in } }
        #expect(try Data(contentsOf: card) == Data(count: 4 << 20))
        // Other bytes of the same size: the write fails instead of reporting success.
        try Data(repeating: 3, count: 1 << 20).write(to: imageURL)
        #expect(throws: FlashError.self) { try CardWriter().write(image, to: descriptor, blockSize: 512, capacity: 4 << 20) { _, _, _ in } }
    }

    @Test func refusesASmallCard() throws {
        let directory = try temporaryDirectory()
        let imageURL = try write(Data(count: 4096), to: directory, name: "card.img")
        let image = PreparedImage(url: imageURL, size: 4096, sha256: "", isGizletR36S: false, releaseTag: nil)
        #expect(throws: FlashError.self) { try CardWriter().write(image, to: -1, blockSize: 512, capacity: 2048) { _, _, _ in } }
    }
}
