import Foundation
import Security

/// Downloads, verifies and installs a Launcher release over the running app.
///
/// The archive must match the signed manifest's size and SHA-256 and unpack to
/// exactly one `Gizlet.app` whose version is the manifest's, signed by the
/// Gizlet Developer ID team, notarized, and valid down to its nested code.
/// Any failure leaves the running version in place. The swap happens after
/// the app quits, by a small script that then opens the new version.
public struct UpdateInstaller: Sendable {
    public var feed: UpdateFeed
    public var workDirectory: URL
    public var requirement: String

    public static let releaseRequirement = """
        anchor apple generic and identifier "\(TrustedKeys.bundleIdentifier)" \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "\(TrustedKeys.developerTeam)" and notarized
        """

    public init(feed: UpdateFeed, workDirectory: URL, requirement: String = UpdateInstaller.releaseRequirement) {
        self.feed = feed
        self.workDirectory = workDirectory
        self.requirement = requirement
    }

    /// A verified new app, ready to replace the running one.
    public struct Staged: Sendable, Equatable {
        public var app: URL
        public var release: LauncherRelease
    }

    public func stage(_ release: LauncherRelease, progress: @escaping @Sendable (UInt64, UInt64?) -> Void = { _, _ in }) async throws -> Staged {
        let fm = FileManager.default
        try fm.ensureDirectory(workDirectory)
        for name in (try? fm.contentsOfDirectory(atPath: workDirectory.path)) ?? [] where name.hasPrefix("staged-") {
            try? fm.removeItem(at: workDirectory.appendingPathComponent(name))
        }
        let archive = workDirectory.appendingPathComponent("\(release.archive.sha256).zip")
        do {
            try await Downloader().download(feed.url(of: release.archive, in: release), to: archive, size: release.archive.bytes,
                                            sha256: release.archive.sha256, limit: release.archive.bytes, progress: progress)
        } catch let error as DownloadError {
            throw UpdateError.verification(error.localizedDescription)
        }
        let staging = workDirectory.appendingPathComponent("staged-\(release.version)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
            let contents = try fm.contentsOfDirectory(atPath: staging.path).filter { $0 != "__MACOSX" }
            guard contents == ["Gizlet.app"] else { throw UpdateError.verification("the archive does not hold Gizlet.app alone") }
            let app = staging.appendingPathComponent("Gizlet.app", isDirectory: true)
            try verify(app, release: release)
            try? fm.removeItem(at: archive)
            return Staged(app: app, release: release)
        } catch {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: archive)
            throw error
        }
    }

    /// The bundle's version and identifier, then its code signature against `requirement`.
    public func verify(_ app: URL, release: LauncherRelease) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == TrustedKeys.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == release.version
        else { throw UpdateError.verification("the app is not Gizlet \(release.version)") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.verification("the app's code cannot be read")
        }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled else {
            throw UpdateError.verification("the signing requirement cannot be read")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var failure: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, compiled, &failure)
        guard status == errSecSuccess else {
            let message = failure?.takeRetainedValue().localizedDescription ?? "status \(status)"
            throw UpdateError.verification("the code signature is not Gizlet's (\(message))")
        }
    }

    /// Where the running app can be replaced: a writable folder, not a translocated or disk-image copy.
    public static func replaceableLocation(of bundle: URL) -> String? {
        let path = bundle.standardizedFileURL.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "Move Gizlet to the Applications folder to install updates"
        }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: bundle.path) else {
            return "Gizlet's folder cannot be written; move Gizlet to the Applications folder to install updates"
        }
        return nil
    }

    /// Copies `staged` beside `bundle`, on the same volume, and checks the copy
    /// again; then starts the script that waits for this process to quit,
    /// swaps the two with renames (putting the old app back if the second
    /// rename fails) and opens Gizlet. The caller then quits. A failed copy
    /// leaves the installed app untouched.
    public func scheduleReplacement(of bundle: URL, with staged: Staged, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        if let problem = Self.replaceableLocation(of: bundle) { throw UpdateError.notInstallable(problem) }
        let fm = FileManager.default
        let destination = bundle.standardizedFileURL
        let beside = destination.deletingLastPathComponent()
            .appendingPathComponent(".Gizlet-\(staged.release.version)-\(UUID().uuidString).app", isDirectory: true)
        do {
            try run("/usr/bin/ditto", [staged.app.path, beside.path])
            try verify(beside, release: staged.release)
        } catch {
            try? fm.removeItem(at: beside)
            throw UpdateError.notInstallable("The update could not be copied beside Gizlet; nothing was changed (\(error.localizedDescription))")
        }
        let script = """
            set -u
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            old="$2.old-$$"
            if mv "$2" "$old"; then
              if mv "$3" "$2"; then rm -rf "$old"; else mv "$old" "$2"; rm -rf "$3"; fi
            else
              rm -rf "$3"
            fi
            rm -rf "$4"
            open "$2"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "gizlet-update", String(pid), destination.path, beside.path,
                             staged.app.deletingLastPathComponent().path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? fm.removeItem(at: beside)
            throw error
        }
    }
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw PackageError.io("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(String(decoding: data, as: UTF8.self))")
    }
    return data
}
