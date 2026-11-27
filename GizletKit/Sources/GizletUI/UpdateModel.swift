import AppKit
import GizletCore
import Observation
import ServiceManagement

/// The Launcher's own updates: checked at start and every two minutes while it
/// runs, reading only the small signed manifest. An update is downloaded and
/// verified when the user asks, and installed once no card is being written.
@MainActor @Observable
public final class UpdateModel {
    public static let interval: TimeInterval = 120

    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(LauncherRelease)
        case downloading(LauncherRelease, Double)
        case waitingForFlash(LauncherRelease)
        /// Open games would outlive the Launcher's relaunch, so it waits for them to quit.
        case waitingForApps(LauncherRelease)
        case installing(LauncherRelease)
        case failed(String)
    }

    unowned let app: AppModel
    public private(set) var state = State.idle
    public private(set) var lastChecked: Date?
    /// The release the update sheet shows; set when a check finds one not yet dismissed.
    public var prompt: LauncherRelease?
    public let currentVersion: String
    private var dismissed: String?
    private var timer: Timer?
    private var staged: UpdateInstaller.Staged?
    private let feed: UpdateFeed?

    init(app: AppModel) {
        self.app = app
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        feed = try? UpdateFeed.standard()
    }

    var installer: UpdateInstaller? {
        feed.map { UpdateInstaller(feed: $0, workDirectory: app.root.launcher.appendingPathComponent("updates", isDirectory: true)) }
    }

    public func start() {
        guard timer == nil else { return }
        Task { await check(manual: false) }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(manual: false) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing, .waitingForFlash, .waitingForApps: true
        default: false
        }
    }

    public func check(manual: Bool) async {
        guard let feed else {
            state = .failed("The update key cannot be read")
            return
        }
        switch state {
        case .checking, .downloading, .installing, .waitingForFlash, .waitingForApps: return
        default: break
        }
        if manual { dismissed = nil }
        let previous = state
        state = .checking
        do {
            let release = try await feed.latest()
            lastChecked = Date()
            switch try compare(release, running: currentVersion) {
            case .upToDate:
                state = .upToDate
            case .available(let release):
                state = .available(release)
                if dismissed != release.version { prompt = release }
            }
        } catch {
            lastChecked = Date()
            // A background check that fails keeps what an earlier one found.
            if manual {
                state = .failed(error.localizedDescription)
            } else if case .available = previous {
                state = previous
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func later(_ release: LauncherRelease) {
        dismissed = release.version
        prompt = nil
    }

    /// Downloads and verifies the release, then installs it and reopens; while
    /// a card is being written, the install waits for the write to end.
    public func install(_ release: LauncherRelease) async {
        prompt = nil
        guard let installer else { return }
        if let problem = UpdateInstaller.replaceableLocation(of: Bundle.main.bundleURL) {
            state = .failed(problem)
            return
        }
        state = .downloading(release, 0)
        do {
            let staged = try await installer.stage(release) { done, total in
                Task { @MainActor [weak self] in
                    if let total, total > 0, case .downloading = self?.state { self?.state = .downloading(release, Double(done) / Double(total)) }
                }
            }
            self.staged = staged
            finishWhenIdle()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Called after staging, when a card write ends and when an app quits:
    /// installs once no card is being written and no app is open.
    func finishWhenIdle() {
        guard let staged, let installer else { return }
        if app.flashModel.isWriting {
            state = .waitingForFlash(staged.release)
            return
        }
        if !app.runningApps.running.isEmpty {
            state = .waitingForApps(staged.release)
            return
        }
        state = .installing(staged.release)
        do {
            try installer.scheduleReplacement(of: Bundle.main.bundleURL, with: staged)
            NSApp.terminate(nil)
        } catch {
            self.staged = nil
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Opening at login

    public var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                app.report(error, app.l("Cannot change opening at login", "无法更改登录时打开"))
            }
        }
    }
}
