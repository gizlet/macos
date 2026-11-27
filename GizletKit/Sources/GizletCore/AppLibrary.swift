import CryptoKit
import Foundation

/// An installed app.
public struct InstalledApp: Identifiable, Equatable, Sendable {
    public var id: String { manifest.id }
    public var directory: URL
    public var manifest: Manifest
    public var installedAt: Date

    public var entry: URL { directory.appendingPathComponent(manifest.entry) }
    public var icon: URL? { manifest.icon.map { directory.appendingPathComponent($0) } }
}

/// The apps installed under `device/packages/apps`, shared by every profile.
/// Installing unpacks beside the installed version and swaps folders only when
/// the package is complete; uninstalling leaves every profile's saves.
public final class AppLibrary: @unchecked Sendable {
    public static let maxManifestBytes: UInt64 = 64 << 10
    public static let maxChecksumsBytes: UInt64 = 4 << 20
    public static let maxUnpackedBytes: UInt64 = 8 << 30

    public let root: DataRoot
    public let platform: Platform
    private let lock = NSLock()

    public init(root: DataRoot, platform: Platform = .current) {
        self.root = root
        self.platform = platform
    }

    /// Installed apps by name. Folders without a readable manifest, and staging leftovers, are skipped.
    public func list() -> [InstalledApp] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.apps.path) else { return [] }
        return names.filter { isValidAppID($0) }.compactMap { load($0) }.sorted {
            $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending
        }
    }

    public func app(_ id: String) -> InstalledApp? {
        isValidAppID(id) ? load(id) : nil
    }

    private func load(_ id: String) -> InstalledApp? {
        let directory = root.apps.appendingPathComponent(id, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL), let manifest = try? Manifest.parse(data), manifest.id == id else {
            return nil
        }
        let date = (try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return InstalledApp(directory: directory, manifest: manifest, installedAt: date)
    }

    /// Reads a package's manifest without unpacking it.
    public func peek(_ package: URL) throws -> Manifest {
        let zip = try ZipArchive(url: package)
        guard let entry = zip.entry(named: "manifest.json") else { throw PackageError.invalid("no manifest.json") }
        return try Manifest.parse(zip.read(entry, limit: Self.maxManifestBytes))
    }

    /// Why this Mac cannot install a package with `manifest`; nil when it can.
    public func compatibilityProblem(_ manifest: Manifest) -> String? {
        if manifest.kind == .service {
            return "\(manifest.name) is a background service; services run on Gizlet OS handhelds"
        }
        if !platform.runs(target: manifest.target, tier: manifest.tier) {
            return "\(manifest.name) is built for \(manifest.target) (\(manifest.tier)); this Mac runs \(platform.targets.joined(separator: ", "))"
        }
        return nil
    }

    /// Installs or updates the app in `package`, after checking its zip
    /// directory, every file against `CHECKSUMS`, its manifest and that this
    /// Mac runs its entry. `expectedID` guards a Store install against a
    /// package that names another app. `isRunning` refuses to replace an app
    /// that is open.
    @discardableResult
    public func install(_ package: URL, expectedID: String? = nil, isRunning: (String) -> Bool = { _ in false }) throws -> InstalledApp {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try fm.ensureDirectory(root.apps)
        let staging = root.apps.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let manifest = try unpack(package, into: staging)
        if let expectedID, manifest.id != expectedID {
            throw PackageError.invalid("the package is \(manifest.id), not \(expectedID)")
        }
        if let problem = compatibilityProblem(manifest) { throw PackageError.unsupported(problem) }
        let entry = staging.appendingPathComponent(manifest.entry)
        switch ExecutableFormat.of(entry) {
        case .script:
            break
        case .machO(let cpuTypes):
            guard let wanted = Platform.cpuType(of: manifest.target), cpuTypes.contains(wanted) else {
                throw PackageError.unsupported("\(manifest.entry) is not an executable for \(manifest.target)")
            }
        case .other:
            throw PackageError.unsupported("\(manifest.entry) is not a macOS executable")
        }
        if isRunning(manifest.id) { throw PackageError.running(manifest.id) }

        let destination = root.apps.appendingPathComponent(manifest.id, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging, options: [.usingNewMetadataOnly])
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.appendingPathComponent("manifest.json").path)
        guard let installed = load(manifest.id) else { throw PackageError.io("\(manifest.id) did not install") }
        return installed
    }

    /// Removes an installed app. Profiles keep their `apps/<id>/` folders.
    public func uninstall(_ id: String, isRunning: (String) -> Bool = { _ in false }) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let app = load(id) else { throw PackageError.notInstalled(id) }
        if isRunning(id) { throw PackageError.running(id) }
        let fm = FileManager.default
        let doomed = root.apps.appendingPathComponent(".removing-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: app.directory, to: doomed)
        try? fm.removeItem(at: doomed)
    }

    /// Removes staging folders a crash left behind.
    public func sweep() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.apps.path)) ?? [] where name.hasPrefix(".staging-") || name.hasPrefix(".removing-") {
            try? fm.removeItem(at: root.apps.appendingPathComponent(name))
        }
    }

    /// Extracts `package` into the new folder `destination`, checks every file
    /// against `CHECKSUMS` and returns its manifest.
    func unpack(_ package: URL, into destination: URL) throws -> Manifest {
        let zip = try ZipArchive(url: package)
        let total = zip.entries.reduce(UInt64(0)) { $0 + $1.size }
        guard total <= Self.maxUnpackedBytes else { throw PackageError.invalid("larger than 8 GiB unpacked") }
        guard let manifestEntry = zip.entry(named: "manifest.json") else { throw PackageError.invalid("no manifest.json") }
        guard manifestEntry.size <= Self.maxManifestBytes else { throw PackageError.invalid("manifest.json is larger than 64 KiB") }
        guard let checksumsEntry = zip.entry(named: "CHECKSUMS") else { throw PackageError.invalid("no CHECKSUMS") }
        guard checksumsEntry.size <= Self.maxChecksumsBytes else { throw PackageError.invalid("CHECKSUMS is larger than 4 MiB") }

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        var sums: [String: String] = [:]
        for entry in zip.entries {
            let path = destination.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
            // Names are canonical and relative, but the resolved path must still stay inside.
            guard path.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                throw PackageError.invalid("\(entry.name) is outside the package")
            }
            if entry.isDirectory {
                try fm.createDirectory(at: path, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: entry.isExecutable ? 0o755 : 0o644]) else {
                throw PackageError.io("cannot create \(entry.name)")
            }
            let out = try FileHandle(forWritingTo: path)
            var hasher = SHA256()
            do {
                try zip.extract(entry) { piece in
                    hasher.update(bufferPointer: piece)
                    try out.write(contentsOf: Data(piece))
                }
                try out.close()
            } catch {
                try? out.close()
                throw error
            }
            sums[entry.name] = hasher.finalize().hex
        }

        let listed = String(decoding: try Data(contentsOf: destination.appendingPathComponent("CHECKSUMS")), as: UTF8.self)
        sums.removeValue(forKey: "CHECKSUMS")
        var unchecked = sums
        for line in listed.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let separator = line.range(of: "  ") else { throw PackageError.invalid("bad CHECKSUMS line \(line)") }
            let sum = line[..<separator.lowerBound].lowercased()
            let path = String(line[separator.upperBound...])
            if let actual = unchecked.removeValue(forKey: path) {
                guard actual == sum else { throw PackageError.invalid("\(path) does not match its checksum") }
            } else if sums[path] != nil {
                throw PackageError.invalid("\(path) is listed twice in CHECKSUMS")
            } else {
                throw PackageError.invalid("\(path) is listed in CHECKSUMS but missing")
            }
        }
        if let path = unchecked.keys.sorted().first { throw PackageError.invalid("\(path) is not listed in CHECKSUMS") }

        let manifest = try Manifest.parse(Data(contentsOf: destination.appendingPathComponent("manifest.json")))
        let entry = destination.appendingPathComponent(manifest.entry)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PackageError.invalid("no entry file \(manifest.entry)")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
        return manifest
    }
}
