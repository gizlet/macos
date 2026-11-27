import Foundation

/// The launcher's data folder, laid out as on a Gizlet OS card: `device/` holds
/// what every profile shares and `profiles/` one folder per local profile.
///
/// | Path | Holds |
/// | --- | --- |
/// | `device/packages/apps/<id>/` | An installed app, shared by every profile |
/// | `device/store/` | Store origins, downloads and the art cache |
/// | `device/current-profile` | The ID of the profile in use |
/// | `device/launcher/` | The Launcher's own update downloads |
/// | `profiles/<id>/` | One profile: `profile.ini`, `launcher/` and `apps/<app-id>/` |
public struct DataRoot: Sendable, Equatable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    /// `GIZLET_PREFIX` when set, else `~/Library/Application Support/Gizlet`.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> DataRoot {
        if let prefix = environment["GIZLET_PREFIX"], !prefix.isEmpty {
            return DataRoot(url: URL(fileURLWithPath: prefix, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DataRoot(url: support.appendingPathComponent("Gizlet", isDirectory: true))
    }

    public var device: URL { url.appendingPathComponent("device", isDirectory: true) }
    public var apps: URL { device.appendingPathComponent("packages/apps", isDirectory: true) }
    public var store: URL { device.appendingPathComponent("store", isDirectory: true) }
    public var launcher: URL { device.appendingPathComponent("launcher", isDirectory: true) }
    public var profiles: URL { url.appendingPathComponent("profiles", isDirectory: true) }
    public var currentProfileFile: URL { device.appendingPathComponent("current-profile") }
}

extension FileManager {
    func ensureDirectory(_ url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// Writes `data` beside `url` and renames it into place, so readers see the old or the new file.
func writeAtomically(_ data: Data, to url: URL) throws {
    try FileManager.default.ensureDirectory(url.deletingLastPathComponent())
    try data.write(to: url, options: .atomic)
}
