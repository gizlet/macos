import Foundation

/// Where an installed app came from, in `device/store/origins.json`.
public struct StoreOrigin: Codable, Equatable, Sendable {
    public var repo: String
    public var repositoryID: UInt64?
    public var version: String
    public var tag: String
    public var sha256: String

    public init(repo: String, repositoryID: UInt64?, version: String, tag: String, sha256: String) {
        self.repo = repo
        self.repositoryID = repositoryID
        self.version = version
        self.tag = tag
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case repo, version, tag, sha256
        case repositoryID = "repository_id"
    }
}

public enum StoreInstallError: Error, LocalizedError, Equatable {
    case otherSource(id: String, from: String?)
    case repositoryChanged(id: String)
    case changedWhileWaiting(String)
    case notReady
    case badPackage

    public var errorDescription: String? {
        switch self {
        case .otherSource(let id, let from?): "\(id) was installed from \(from); uninstall it first to install this one"
        case .otherSource(let id, nil): "\(id) was installed from a file; uninstall it first to install it from the Store"
        case .repositoryChanged(let id): "The repository \(id) came from was replaced by another; uninstall it first"
        case .changedWhileWaiting(let id): "\(id) changed while waiting to update; check for updates again"
        case .notReady: "The package is still being checked; try again in a minute"
        case .badPackage: "The Gizlet Store sent an invalid package"
        }
    }
}

/// Installs and updates apps from the Store into the shared library. Only the
/// repository an app came from, with GitHub's same id for it, replaces it: a
/// package declaring the same ID from elsewhere never reaches its saves.
public final class StoreInstaller: @unchecked Sendable {
    public static let packageLimit: UInt64 = 1 << 30

    public let library: AppLibrary
    public let client: StoreClient
    let downloader: Downloader
    private let lock = NSLock()
    /// Held while what is installed, and where it came from, changes.
    private let commitLock = NSLock()

    public init(library: AppLibrary, client: StoreClient, downloader: Downloader = Downloader()) {
        self.library = library
        self.client = client
        self.downloader = downloader
    }

    var originsFile: URL { library.root.store.appendingPathComponent("origins.json") }
    var downloads: URL { library.root.store.appendingPathComponent("downloads", isDirectory: true) }

    public func origins() -> [String: StoreOrigin] {
        guard let data = try? Data(contentsOf: originsFile) else { return [:] }
        return (try? JSONDecoder().decode([String: StoreOrigin].self, from: data)) ?? [:]
    }

    func setOrigin(_ id: String, _ origin: StoreOrigin?) throws {
        lock.lock()
        defer { lock.unlock() }
        var all = origins()
        all[id] = origin
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(encoder.encode(all), to: originsFile)
    }

    /// Installs the app a repository offers for this Mac.
    @discardableResult
    public func install(repo: String, isRunning: @escaping (String) -> Bool,
                        progress: @escaping @Sendable (UInt64, UInt64?) -> Void) async throws -> InstalledApp {
        let offer = try await client.offer(repo)
        return try await install(repo: offer.repo, repositoryID: offer.repositoryID, id: offer.appID, kind: offer.kind,
                                 version: offer.version, tag: offer.tag, package: offer.package, replaces: nil,
                                 isRunning: isRunning, progress: progress)
    }

    /// Installs an update `/v1/updates` offered.
    @discardableResult
    public func upgrade(_ update: StoreUpdateStatus, isRunning: @escaping (String) -> Bool,
                        progress: @escaping @Sendable (UInt64, UInt64?) -> Void) async throws -> InstalledApp {
        guard let package = update.package, let version = update.version, let tag = update.tag else { throw StoreInstallError.badPackage }
        let repositoryID = update.repositoryID ?? origins()[update.appID]?.repositoryID
        return try await install(repo: update.repo, repositoryID: repositoryID, id: update.appID, kind: update.kind ?? "app",
                                 version: version, tag: tag, package: package, replaces: update.installed,
                                 isRunning: isRunning, progress: progress)
    }

    private func install(repo: String, repositoryID: UInt64?, id: String, kind: String, version: String, tag: String,
                         package: StorePackage, replaces: String?, isRunning: @escaping (String) -> Bool,
                         progress: @escaping @Sendable (UInt64, UInt64?) -> Void) async throws -> InstalledApp {
        guard isValidAppID(id) else { throw StoreInstallError.badPackage }
        guard kind == "app" else { throw PackageError.unsupported("Services run on Gizlet OS handhelds, not on a Mac") }
        try checkSource(repo: repo, repositoryID: repositoryID, id: id, replaces: replaces)
        guard let url = package.url, let sha256 = package.sha256, let size = package.size else { throw StoreInstallError.notReady }
        guard isSHA256Hex(sha256), size > 0, size <= Self.packageLimit, url.scheme == "https" || url.host == "localhost" else {
            throw StoreInstallError.badPackage
        }
        let file = downloads.appendingPathComponent("\(sha256).gzl")
        try await downloader.download(url, to: file, size: size, sha256: sha256, progress: progress)
        defer { try? FileManager.default.removeItem(at: file) }
        // What is installed may have changed while downloading: check again, and
        // replace the package and its origin together.
        return try commit(file, origin: StoreOrigin(repo: repo, repositoryID: repositoryID, version: version, tag: tag, sha256: sha256),
                          id: id, replaces: replaces, isRunning: isRunning)
    }

    private func commit(_ file: URL, origin: StoreOrigin, id: String, replaces: String?, isRunning: (String) -> Bool) throws -> InstalledApp {
        commitLock.lock()
        defer { commitLock.unlock() }
        try checkSource(repo: origin.repo, repositoryID: origin.repositoryID, id: id, replaces: replaces)
        let installed = try library.install(file, expectedID: id, isRunning: isRunning)
        try setOrigin(id, origin)
        return installed
    }

    /// Fails unless the repository may install `id` now: an installed app is only
    /// replaced by the repository it came from, with the same GitHub repository id,
    /// and an update only replaces the version it was offered for.
    private func checkSource(repo: String, repositoryID: UInt64?, id: String, replaces: String?) throws {
        let current = library.app(id)
        if let replaces, current?.manifest.version != replaces { throw StoreInstallError.changedWhileWaiting(id) }
        guard current != nil else { return }
        switch origins()[id] {
        case .some(let origin) where origin.repo != repo:
            throw StoreInstallError.otherSource(id: id, from: origin.repo)
        case .some(let origin) where origin.repositoryID != nil && origin.repositoryID != repositoryID:
            throw StoreInstallError.repositoryChanged(id: id)
        case .none:
            throw StoreInstallError.otherSource(id: id, from: nil)
        default:
            break
        }
    }

    /// Installs a local `.gzl`; it is no longer updated from the Store.
    @discardableResult
    public func installFile(_ file: URL, isRunning: (String) -> Bool) throws -> InstalledApp {
        commitLock.lock()
        defer { commitLock.unlock() }
        let installed = try library.install(file, isRunning: isRunning)
        try setOrigin(installed.id, nil)
        return installed
    }

    public func uninstall(_ id: String, isRunning: (String) -> Bool) throws {
        commitLock.lock()
        defer { commitLock.unlock() }
        try library.uninstall(id, isRunning: isRunning)
        try setOrigin(id, nil)
    }

    /// Update statuses for the installed apps that came from the Store.
    public func updates() async throws -> [StoreUpdateStatus] {
        let origins = origins()
        let installed = library.list().compactMap { app -> StoreClient.InstalledItem? in
            guard let origin = origins[app.id] else { return nil }
            return StoreClient.InstalledItem(repo: origin.repo, repositoryID: origin.repositoryID, id: app.id, version: app.manifest.version)
        }
        return try await client.updates(installed)
    }
}
