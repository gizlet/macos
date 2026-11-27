import AppKit
import GizletCore
import Observation

/// Writing Gizlet OS to an R36S card: the image from the latest release or a
/// local file, the cards Disk Arbitration sees, and the write itself.
///
/// A card is written only after the user confirms that exact medium. Its
/// identity includes the time it appeared, so taking it out and putting it
/// (or another) back in needs a new confirmation; the identity, and that it
/// is not a protected disk, are checked again just before the device is
/// opened, after authorization, and against the opened device itself.
@MainActor @Observable
public final class FlashModel {
    public enum Source: Equatable {
        case latest
        case file(URL)
    }

    public enum Step: Equatable {
        case idle
        case preparing(PreparePhase, Double?)
        case authorizing
        case writing(Double)
        case verifying(Double)
        case configuring
        case done(String)
        case failed(String)
    }

    unowned let app: AppModel
    let monitor = DiskMonitor()
    public private(set) var disks: [DiskInfo] = []
    public private(set) var protected: Set<String> = []
    public private(set) var panels: [String: PanelDetection] = [:]
    public private(set) var release: OSImageRelease?
    public private(set) var releaseError: String?
    public private(set) var prepared: PreparedImage?
    public private(set) var step = Step.idle
    public var source = Source.latest {
        didSet { if source != oldValue { prepared = nil } }
    }
    public var selection: String? {
        didSet { if selection != oldValue { panelChoice = nil; confirming = nil } }
    }
    /// The panel to configure; nil keeps the image's own setting (local images only).
    public var panelChoice: R36SPanel?
    /// The card the confirmation dialog is asking about; cleared when it changes.
    public var confirming: DiskIdentity?
    public var typedName = ""
    private var writer: CardWriter?
    private var started = false
    let allowDiskImages = ProcessInfo.processInfo.environment["GIZLET_ALLOW_DISK_IMAGES"] == "1"

    init(app: AppModel) {
        self.app = app
    }

    var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("io.gizlet.macos/os-images", isDirectory: true)
    }

    public func start() {
        guard !started else { return }
        started = true
        protected = protectedDisks(extraPaths: [Bundle.main.bundleURL, app.root.url])
        monitor.onChange = { [weak self] disks in
            Task { @MainActor in self?.disksChanged(disks) }
        }
        monitor.onDisappear = { [weak self] name in
            Task { @MainActor in self?.diskDisappeared(name) }
        }
        monitor.start()
        Task { await loadRelease() }
    }

    public func loadRelease() async {
        do {
            release = try await OSReleaseFeed().latest()
            releaseError = nil
        } catch {
            releaseError = error.localizedDescription
        }
    }

    public var isWriting: Bool {
        switch step {
        case .authorizing, .writing, .verifying, .configuring: true
        default: false
        }
    }

    public var isBusy: Bool {
        if case .preparing = step { return true }
        return isWriting
    }

    public func problem(_ disk: DiskInfo) -> String? {
        diskProblem(disk, protected: protected, allowDiskImages: allowDiskImages)
    }

    /// Cards that may be written first, then the rest of the external disks, each smallest first.
    public var listedDisks: [DiskInfo] {
        disks.filter { !$0.isInternal || $0.isRemovable || problem($0) == nil }
            .sorted { (problem($0) == nil ? 0 : 1, $0.size) < (problem($1) == nil ? 0 : 1, $1.size) }
    }

    public var selectedDisk: DiskInfo? {
        disks.first { $0.bsdName == selection }
    }

    private func disksChanged(_ disks: [DiskInfo]) {
        self.disks = disks
        for disk in disks {
            let boot = disk.volumes.first { $0.bsdName == disk.bsdName + "s1" }
            if let boot, let mount = boot.mountPoint {
                panels[disk.bsdName] = PanelDetector.detect(bootVolume: mount, volumeName: boot.name)
            } else if !isWriting {
                panels.removeValue(forKey: disk.bsdName)
            }
        }
        if let confirming, monitor.describe(confirming.bsdName)?.identity != confirming {
            self.confirming = nil
        }
        if selection == nil, let first = listedDisks.first(where: { problem($0) == nil }) {
            selection = first.bsdName
        }
    }

    private func diskDisappeared(_ name: String) {
        panels.removeValue(forKey: name)
        if confirming?.bsdName == name { confirming = nil }
        if selection == name, !isWriting { selection = nil }
    }

    /// The panel the card being written will be set up for.
    public var effectivePanel: R36SPanel? {
        if let panelChoice { return panelChoice }
        if case .file = source, prepared?.releaseTag == nil { return nil }
        guard let selection, let detection = panels[selection] else { return .panel4 }
        return detection.panel
    }

    // MARK: Writing

    /// Prepares the image if needed, then asks to confirm the selected card.
    public func requestWrite() async {
        guard let disk = selectedDisk, problem(disk) == nil, !isBusy else { return }
        let identity = disk.identity
        if prepared == nil {
            await prepare()
            guard prepared != nil else { return }
        }
        guard monitor.describe(identity.bsdName)?.identity == identity else {
            step = .failed(FlashError.cardChanged.localizedDescription)
            return
        }
        typedName = ""
        confirming = identity
    }

    public func prepare() async {
        let imageSource: ImageSource
        switch source {
        case .latest:
            if release == nil { await loadRelease() }
            guard let release else {
                step = .failed(releaseError ?? app.l("The latest release cannot be found", "找不到最新版本"))
                return
            }
            imageSource = .release(release)
        case .file(let url):
            imageSource = .file(url)
        }
        step = .preparing(.downloading, nil)
        do {
            let image = try await ImagePreparer(cache: cache).prepare(imageSource) { phase, done, total in
                let fraction = total.flatMap { $0 > 0 ? Double(done) / Double($0) : nil }
                Task { @MainActor [weak self] in
                    if case .preparing = self?.step { self?.step = .preparing(phase, fraction) }
                }
            }
            prepared = image
            step = .idle
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    /// Re-reads the card: the same medium that was confirmed, and still allowed.
    private func confirmedDisk(_ identity: DiskIdentity) throws -> DiskInfo {
        protected = protectedDisks(extraPaths: [Bundle.main.bundleURL, app.root.url])
        guard let disk = monitor.describe(identity.bsdName), disk.identity == identity else { throw FlashError.cardChanged }
        if let problem = problem(disk) { throw FlashError.disk(app.l("This disk cannot be written: \(problem)", "不能写入这个磁盘：\(problem)")) }
        return disk
    }

    /// Writes the confirmed card. `identity` is the medium the user confirmed.
    public func write(confirmed identity: DiskIdentity) async {
        confirming = nil
        guard let image = prepared, !isWriting else { return }
        let panel = effectivePanel
        let bsdName = identity.bsdName
        step = .authorizing
        monitor.setMountsBlocked(true, for: bsdName)
        var descriptor: Int32 = -1
        defer {
            if descriptor >= 0 { close(descriptor) }
            monitor.setMountsBlocked(false, for: bsdName)
            app.updateModel.finishWhenIdle()
        }
        do {
            let disk = try confirmedDisk(identity)
            try await monitor.unmount(bsdName)
            let path = disk.rawDevicePath
            descriptor = try await Task.detached { try AuthOpen.open(path) }.value
            // The password dialog takes time: the card must still be the confirmed one.
            _ = try confirmedDisk(identity)
            var opened = stat(), named = stat()
            guard fstat(descriptor, &opened) == 0, stat(path, &named) == 0, opened.st_rdev == named.st_rdev,
                  opened.st_mode & S_IFMT == S_IFCHR else { throw FlashError.cardChanged }

            step = .writing(0)
            let writer = CardWriter()
            self.writer = writer
            let fd = descriptor
            let reporter = ProgressThrottle { [weak self] phase, fraction in
                Task { @MainActor in
                    guard let self, self.isWriting else { return }
                    self.step = phase == .writing ? .writing(fraction) : .verifying(fraction)
                }
            }
            try await Task.detached(priority: .userInitiated) {
                try writer.write(image, to: fd, blockSize: disk.blockSize, capacity: disk.size) { phase, done, total in
                    reporter.report(phase, total > 0 ? Double(done) / Double(total) : 0)
                }
            }.value
            close(descriptor)
            descriptor = -1
            monitor.setMountsBlocked(false, for: bsdName)
            if let panel {
                step = .configuring
                try await configure(identity, panel: panel)
            }
            if monitor.describe(bsdName)?.identity == identity { try? await monitor.eject(bsdName) }
            step = .done(disk.displayName)
        } catch {
            step = .failed(error.localizedDescription)
        }
        writer = nil
    }

    public func cancel() {
        writer?.cancel()
    }

    public func reset() {
        if !isBusy { step = .idle }
    }

    /// Selects the panel on the written card: copies its overlay to `mipi-panel.dtbo`
    /// on the FAT boot partition once macOS has found the new partitions.
    /// Selects the chosen panel on the written card's FAT boot partition, once
    /// macOS has found the new partitions: Panel 4's overlay copied to
    /// `mipi-panel.dtbo`, or for Panel 0, which the device tree itself
    /// describes, no `mipi-panel.dtbo` at all.
    private func configure(_ identity: DiskIdentity, panel: R36SPanel) async throws {
        let bsdName = identity.bsdName
        let partition = bsdName + "s1"
        let failure: FlashError
        if let overlay = panel.overlay {
            failure = FlashError.write(app.l("The card is written, but its display could not be set up. Copy \(overlay) to mipi-panel.dtbo on GIZLETBOOT.",
                                             "已写卡，但无法配置屏幕。请在 GIZLETBOOT 上把 \(overlay) 复制为 mipi-panel.dtbo。"))
        } else {
            failure = FlashError.write(app.l("The card is written, but its display could not be set up. Delete mipi-panel.dtbo on GIZLETBOOT.",
                                             "已写卡，但无法配置屏幕。请删除 GIZLETBOOT 上的 mipi-panel.dtbo。"))
        }
        for _ in 0..<30 {
            // Only the card just written: another one given the same name is left alone.
            guard let disk = monitor.describe(bsdName), disk.identity == identity else { throw FlashError.cardChanged }
            if let volume = disk.volumes.first(where: { $0.bsdName == partition }) {
                if volume.name != "GIZLETBOOT" { throw failure }
                if volume.mountPoint == nil { try? await monitor.mount(partition) }
                guard let current = monitor.describe(bsdName), current.identity == identity else { throw FlashError.cardChanged }
                if let mount = current.volumes.first(where: { $0.bsdName == partition })?.mountPoint {
                    do {
                        try PanelDetector.select(panel, onBootVolume: mount)
                    } catch {
                        throw failure
                    }
                    sync()
                    return
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw failure
    }
}

/// Passes on progress at most every half percent, from the writing thread.
final class ProgressThrottle: @unchecked Sendable {
    private let send: (WritePhase, Double) -> Void
    private var last: (WritePhase, Double)?
    private let lock = NSLock()

    init(_ send: @escaping (WritePhase, Double) -> Void) {
        self.send = send
    }

    func report(_ phase: WritePhase, _ fraction: Double) {
        lock.lock()
        let due = last == nil || last!.0 != phase || fraction - last!.1 >= 0.005 || fraction >= 1
        if due { last = (phase, fraction) }
        lock.unlock()
        if due { send(phase, fraction) }
    }
}
