import Foundation

/// One file of a Launcher release, relative to its version folder.
public struct ReleaseFile: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String
    public var bytes: UInt64
}

/// A Launcher release, as the signed update manifest describes it.
public struct LauncherRelease: Codable, Equatable, Sendable {
    public var schema: Int
    public var version: String
    public var tag: String
    public var commit: String?
    public var minimumMacOS: String
    public var publishedAt: String?
    public var notes: [String: String]
    public var archive: ReleaseFile
    public var dmg: ReleaseFile

    enum CodingKeys: String, CodingKey {
        case schema, version, tag, commit, notes, archive, dmg
        case minimumMacOS = "minimum_macos"
        case publishedAt = "published_at"
    }

    public func notes(for language: String) -> String { localized(notes, language) ?? notes["en"] ?? "" }
}

/// `latest.json`: the manifest's exact bytes as a string, and their signature.
struct UpdateEnvelope: Codable {
    var schema: Int
    var manifest: String
    var signature: String
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case feed(String)
    /// The feed has no manifest: nothing is published yet.
    case noRelease
    case notNewer
    case incompatible(String)
    case notInstallable(String)
    case verification(String)

    public var errorDescription: String? {
        switch self {
        case .feed(let message): "Cannot check for updates: \(message)"
        case .noRelease: "No version is published yet"
        case .notNewer: "This version is up to date"
        case .incompatible(let minimum): "The new version needs macOS \(minimum) or later"
        case .notInstallable(let message): message
        case .verification(let message): "The update failed verification and was not installed: \(message)"
        }
    }
}

/// Reads the Launcher's update manifest. It is small, signed, and fetched with
/// the cache revalidated every time, so a new release shows on the next check.
public struct UpdateFeed: Sendable {
    public static let defaultURL = URL(string: "https://gizlet.io/assets/macos/latest.json")!
    public static let releasesURL = URL(string: "https://gizlet.io/assets/macos/releases/")!
    public var url: URL
    public var releases: URL
    var verifier: SSHSignatureVerifier
    var session: URLSession

    public init(url: URL = UpdateFeed.defaultURL, releases: URL = UpdateFeed.releasesURL,
                key: String = TrustedKeys.launcherUpdate, session: URLSession = .shared) throws {
        self.url = url
        self.releases = releases
        verifier = try SSHSignatureVerifier(key: key, namespace: TrustedKeys.launcherUpdateNamespace)
        self.session = session
    }

    /// `GIZLET_UPDATE_FEED` points at another feed (its releases beside it), for testing a release.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> UpdateFeed {
        if let value = environment["GIZLET_UPDATE_FEED"], let url = URL(string: value) {
            return try UpdateFeed(url: url, releases: url.deletingLastPathComponent().appendingPathComponent("releases/"))
        }
        return try UpdateFeed()
    }

    public func latest() async throws -> LauncherRelease {
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 20)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.feed(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError.noRelease }
        guard status == 200 else { throw UpdateError.feed("HTTP \(status)") }
        guard data.count <= 64 << 10 else { throw UpdateError.feed("the manifest is too large") }
        return try parse(data)
    }

    /// Checks the envelope's signature, then reads the manifest it signs.
    public func parse(_ data: Data) throws -> LauncherRelease {
        let envelope: UpdateEnvelope
        do {
            envelope = try JSONDecoder().decode(UpdateEnvelope.self, from: data)
        } catch {
            throw UpdateError.feed("the manifest cannot be read")
        }
        guard envelope.schema == 1 else { throw UpdateError.feed("unsupported manifest schema \(envelope.schema)") }
        let manifest = Data(envelope.manifest.utf8)
        do {
            try verifier.verify(manifest, armored: envelope.signature)
        } catch {
            throw UpdateError.verification(error.localizedDescription)
        }
        let release: LauncherRelease
        do {
            release = try JSONDecoder().decode(LauncherRelease.self, from: manifest)
        } catch {
            throw UpdateError.feed("the manifest cannot be read")
        }
        guard release.schema == 1, let version = ReleaseVersion(release.version), version.tag == release.tag else {
            throw UpdateError.feed("the manifest names an invalid version")
        }
        for file in [release.archive, release.dmg] {
            guard relativePathProblem(file.path) == nil, isSHA256Hex(file.sha256), file.bytes > 0 else {
                throw UpdateError.feed("the manifest names an invalid file")
            }
        }
        return release
    }

    public func url(of file: ReleaseFile, in release: LauncherRelease) -> URL {
        releases.appendingPathComponent(release.tag, isDirectory: true).appendingPathComponent(file.path)
    }
}

/// What a check found.
public enum UpdateCheck: Equatable, Sendable {
    case upToDate(LauncherRelease)
    case available(LauncherRelease)
}

public func compare(_ release: LauncherRelease, running: String, os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws -> UpdateCheck {
    guard let new = ReleaseVersion(release.version) else { throw UpdateError.feed("invalid version") }
    guard let current = ReleaseVersion(running), new > current else { return .upToDate(release) }
    let minimum = release.minimumMacOS.split(separator: ".").compactMap { Int($0) }
    let needed = OperatingSystemVersion(majorVersion: minimum.first ?? 0, minorVersion: minimum.count > 1 ? minimum[1] : 0,
                                        patchVersion: minimum.count > 2 ? minimum[2] : 0)
    let osTuple = (os.majorVersion, os.minorVersion, os.patchVersion)
    guard osTuple >= (needed.majorVersion, needed.minorVersion, needed.patchVersion) else {
        throw UpdateError.incompatible(release.minimumMacOS)
    }
    return .available(release)
}
