import AppKit
import GizletCore
import Observation
import SwiftUI

/// The launcher's pages: the Store's Discover, Games and Apps, what is installed,
/// updates, writing cards, and Settings (from the profile button or ⌘,).
public enum Page: String, CaseIterable, Identifiable, Hashable {
    case discover, games, apps, library, updates, flash, settings
    public var id: String { rawValue }

    /// The pages in the sidebar, in its two groups.
    static let store: [Page] = [.discover, .games, .apps]
    static let device: [Page] = [.library, .updates, .flash]
}

/// A message for the window's alert.
public struct Notice: Identifiable, Equatable {
    public let id = UUID()
    public var title: String
    public var message: String
}

/// The launcher's state: the shared app library, the profile in use with its
/// settings, and the apps running now. Sub-models drive the Store, Flash and updates.
@MainActor @Observable
public final class AppModel {
    public let root: DataRoot
    public let platform: Platform
    let library: AppLibrary
    let profiles: Profiles
    let store: StoreInstaller

    public var section: Page = .discover
    public private(set) var apps: [InstalledApp] = []
    public private(set) var profileList: [Profile] = []
    public private(set) var profile: Profile
    public private(set) var settings = ProfileSettings()
    /// The apps running now, from this run of the Launcher or an earlier one.
    public private(set) var runningIDs: Set<String> = []
    let runningApps: RunningApps
    private var runningWatch: Timer?
    public private(set) var appUpdates: [String: StoreUpdateStatus] = [:]
    public private(set) var busyApps: Set<String> = []
    public var notice: Notice?
    public var showFavoritesOnly = false
    public var requestImport = false

    public var storeModel: StoreModel!
    public var flashModel: FlashModel!
    public var updateModel: UpdateModel!

    public var l: Localizer { Localizer.resolve(settings.language) }

    public init(root: DataRoot = .standard(), platform: Platform = .current) {
        self.root = root
        self.platform = platform
        library = AppLibrary(root: root, platform: platform)
        profiles = Profiles(root: root)
        store = StoreInstaller(library: library, client: .standard())
        runningApps = RunningApps(root: root)
        library.sweep()
        profiles.sweep()
        do {
            profile = try profiles.current()
        } catch {
            profile = Profile(id: String(repeating: "0", count: 16), name: "", created: 0)
            notice = Notice(title: "Gizlet", message: l.describe(error))
        }
        if let page = ProcessInfo.processInfo.environment["GIZLET_PAGE"].flatMap(Page.init(rawValue:)) { section = page }
        loadProfile()
        storeModel = StoreModel(app: self)
        flashModel = FlashModel(app: self)
        updateModel = UpdateModel(app: self)
        refreshRunning()
        // Apps started by an earlier run have no process object to say when they end.
        let watch = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        }
        RunLoop.main.add(watch, forMode: .common)
        runningWatch = watch
    }

    /// Reads which apps run now; a Launcher update waiting for them goes on once none does.
    func refreshRunning() {
        let ids = Set(runningApps.running.map(\.id))
        guard ids != runningIDs else { return }
        runningIDs = ids
        updateModel?.finishWhenIdle()
    }

    var profileStore: ProfileStore { ProfileStore(directory: profiles.directory(profile.id)) }

    func loadProfile() {
        settings = profileStore.loadSettings()
        profileList = profiles.list()
        apps = library.list()
        applyAppearance()
    }

    public func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func report(_ error: Error, _ title: String) {
        if error is CancellationError { return }
        notice = Notice(title: title, message: l.describe(error))
    }

    // MARK: Settings

    public func update(_ change: (inout ProfileSettings) -> Void) {
        var next = settings
        change(&next)
        do {
            try profileStore.save(next)
            settings = next
            applyAppearance()
        } catch {
            report(error, l("Cannot save the setting", "无法保存设置"))
        }
    }

    // MARK: Apps

    public func refreshApps() {
        apps = library.list()
    }

    public var visibleApps: [InstalledApp] {
        let favorites = settings.favorites
        let recent = profileStore.recent()
        let shown = showFavoritesOnly ? apps.filter { favorites.contains($0.id) } : apps
        return shown.sorted { first, second in
            let a = favorites.firstIndex(of: first.id), b = favorites.firstIndex(of: second.id)
            if (a != nil) != (b != nil) { return a != nil }
            if let a, let b, a != b { return a < b }
            let ra = recent[first.id] ?? 0, rb = recent[second.id] ?? 0
            if ra != rb { return ra > rb }
            return first.manifest.name(for: l.tag).localizedStandardCompare(second.manifest.name(for: l.tag)) == .orderedAscending
        }
    }

    public func isFavorite(_ id: String) -> Bool { settings.favorites.contains(id) }

    public func toggleFavorite(_ id: String) {
        update { settings in
            if let index = settings.favorites.firstIndex(of: id) { settings.favorites.remove(at: index) } else { settings.favorites.append(id) }
        }
    }

    public func isRunning(_ id: String) -> Bool { runningIDs.contains(id) }

    /// Whether an app runs at the moment it is asked, for checks off the main actor.
    private var liveRunning: @Sendable (String) -> Bool {
        let apps = runningApps
        return { apps.isRunning($0) }
    }

    /// Opens an app with its folder as the working directory and the Gizlet
    /// environment: its ID and folder, its saves in the current profile, the
    /// language, and the A/B layout a keyboard uses. Not while it is being updated.
    public func launch(_ app: InstalledApp) {
        guard !runningApps.isRunning(app.id) else { return }
        let saves = profileStore.saveDirectory(for: app.id)
        do {
            try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
            var environment = ProcessInfo.processInfo.environment
            environment["GIZLET_APP_ID"] = app.id
            environment["GIZLET_APP_DIR"] = app.directory.path
            environment["GIZLET_SAVE_DIR"] = saves.path
            environment["GIZLET_LANG"] = l.tag
            environment["GIZLET_SWAP_AB"] = "0"
            environment["GIZLET_PROFILE_ID"] = profile.id
            for key in ["GIZLET_PREFIX", "GIZLET_STORE_API", "GIZLET_UPDATE_FEED", "GIZLET_PAGE"] { environment.removeValue(forKey: key) }
            // Its own process group, so Quit ends what it starts too; the running
            // list notices the group ending on its next look.
            try runningApps.launch(app.id, profile: profile.id) {
                try ProcessGroup.spawn(app.entry, environment: environment, directory: app.directory)
            }
            refreshRunning()
            try? profileStore.markPlayed(app.id)
        } catch {
            report(error, l("Cannot open \(app.manifest.name(for: l.tag))", "无法打开\(app.manifest.name(for: l.tag))"))
        }
    }

    /// Asks a running app to quit, and ends it three seconds later if it is still running.
    public func stop(_ id: String) {
        runningApps.stop(id)
    }

    /// Runs `body` with `id` reserved: it cannot launch meanwhile, and is refused if it runs.
    private func replacing<T>(_ id: String, _ body: () async throws -> T) async throws -> T {
        try runningApps.reserve(id)
        busyApps.insert(id)
        defer {
            busyApps.remove(id)
            runningApps.release(id)
        }
        return try await body()
    }

    private func replacing<T>(_ id: String, _ body: () throws -> T) throws -> T {
        try runningApps.reserve(id)
        defer { runningApps.release(id) }
        return try body()
    }

    public func importPackage(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let manifest = try library.peek(url)
            if let installed = library.app(manifest.id), let origin = store.origins()[manifest.id] {
                _ = installed
                notice = Notice(title: l("Installed from a file", "已从文件安装"),
                                message: l("\(manifest.name) was from \(origin.repo); it will no longer get Store updates.",
                                           "\(manifest.name) 原来自 \(origin.repo)，之后不再从商店更新。"))
            }
            let app = try replacing(manifest.id) { try store.installFile(url, isRunning: liveRunning) }
            refreshApps()
            appUpdates.removeValue(forKey: app.id)
            section = .library
        } catch {
            report(error, l("Cannot install \(url.lastPathComponent)", "无法安装 \(url.lastPathComponent)"))
        }
    }

    public func uninstall(_ id: String) {
        do {
            try replacing(id) { try store.uninstall(id, isRunning: liveRunning) }
            if settings.favorites.contains(id) { update { $0.favorites.removeAll { $0 == id } } }
            appUpdates.removeValue(forKey: id)
            refreshApps()
        } catch {
            report(error, l("Cannot uninstall", "无法卸载"))
        }
    }

    public func origin(of id: String) -> StoreOrigin? { store.origins()[id] }

    public func checkAppUpdates() async {
        do {
            let statuses = try await store.updates()
            appUpdates = Dictionary(statuses.filter(\.hasUpdate).map { ($0.appID, $0) }, uniquingKeysWith: { $1 })
        } catch {
            // Update badges wait for the next check; the Store page reports being offline.
        }
    }

    public func upgrade(_ id: String) async {
        guard let update = appUpdates[id], !busyApps.contains(id) else { return }
        do {
            let store = store, check = liveRunning
            _ = try await replacing(id) { try await store.upgrade(update, isRunning: check, progress: { _, _ in }) }
            appUpdates.removeValue(forKey: id)
            refreshApps()
        } catch {
            report(error, l("Cannot update", "无法更新"))
        }
    }

    func storeInstall(_ repo: String, appID: String, progress: @escaping @Sendable (UInt64, UInt64?) -> Void) async throws -> InstalledApp {
        let store = store, check = liveRunning
        let app = try await replacing(appID) { try await store.install(repo: repo, isRunning: check, progress: progress) }
        refreshApps()
        appUpdates.removeValue(forKey: app.id)
        return app
    }

    // MARK: Profiles

    public func createProfile(_ name: String) -> Bool {
        do {
            _ = try profiles.create(name: name)
            profileList = profiles.list()
            return true
        } catch {
            report(error, l("Cannot create the profile", "无法创建 Profile"))
            return false
        }
    }

    public func renameProfile(_ id: String, to name: String) -> Bool {
        do {
            let renamed = try profiles.rename(id, to: name)
            if renamed.id == profile.id { profile = renamed }
            profileList = profiles.list()
            return true
        } catch {
            report(error, l("Cannot rename the profile", "无法重命名 Profile"))
            return false
        }
    }

    public func deleteProfile(_ id: String) {
        if runningApps.running.contains(where: { $0.profile == id }) {
            notice = Notice(title: l("Quit the open apps first", "请先退出正在运行的应用"),
                            message: l("An app is still using this profile's saves.", "有应用仍在使用这个 Profile 的存档。"))
            return
        }
        do {
            try profiles.delete(id)
            profileList = profiles.list()
        } catch {
            report(error, l("Cannot delete the profile", "无法删除 Profile"))
        }
    }

    /// Switches at once. Apps keep writing to the profile they were opened in,
    /// so they must be quit first.
    public func switchProfile(_ id: String) {
        guard id != profile.id else { return }
        if !runningApps.running.isEmpty {
            notice = Notice(title: l("Quit the open apps first", "请先退出正在运行的应用"),
                            message: l("Apps that are open keep their saves in the current profile.", "正在运行的应用会把存档写入当前 Profile。"))
            return
        }
        do {
            try profiles.switchTo(id)
            profile = try profiles.current()
            loadProfile()
        } catch {
            report(error, l("Cannot switch profiles", "无法切换 Profile"))
        }
    }
}
