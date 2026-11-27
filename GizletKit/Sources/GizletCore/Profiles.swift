import Foundation

/// A local profile: one person's saves, favorites and preferences over the shared apps.
public struct Profile: Identifiable, Equatable, Hashable, Sendable {
    public static let defaultName = "Default"
    public static let maxNameCharacters = 24

    public var id: String
    /// Empty for the first profile, which is called Default until renamed.
    public var name: String
    /// Seconds since 1970; profiles are listed in this order.
    public var created: UInt64

    public init(id: String, name: String, created: UInt64) {
        self.id = id
        self.name = name
        self.created = created
    }

    public var label: String { name.isEmpty ? Self.defaultName : name }

    static func parse(id: String, text: String) -> Profile {
        var profile = Profile(id: id, name: "", created: 0)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "name" where Profiles.nameProblem(value) == nil: profile.name = value
            case "created": profile.created = UInt64(value) ?? 0
            default: break
            }
        }
        return profile
    }

    var rendered: String { "name = \(name)\ncreated = \(created)\n" }
}

public enum ProfileError: Error, Equatable, LocalizedError {
    case badName(String)
    case taken(String)
    case notFound(String)
    case isCurrent
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .badName(let problem): problem
        case .taken(let name): "A profile is already called \(name)"
        case .notFound(let key): "No profile \(key)"
        case .isCurrent: "The profile in use cannot be deleted; switch to another one first"
        case .io(let message): message
        }
    }
}

/// The profiles under a data root, with the one in use named in
/// `device/current-profile`. On a Mac a switch takes effect at once.
public final class Profiles: @unchecked Sendable {
    public static let idLength = 16
    public let root: DataRoot
    private let lock = NSLock()

    public init(root: DataRoot) {
        self.root = root
    }

    public static func isValidID(_ id: String) -> Bool {
        id.utf8.count == idLength && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Why `name` cannot name a profile; nil when it can.
    public static func nameProblem(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "A profile needs a name" }
        if name.trimmingCharacters(in: .whitespaces) != name { return "A profile name cannot start or end with a space" }
        if name.count > Profile.maxNameCharacters { return "A profile name has at most 24 characters" }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
            return "A profile name cannot hold control characters"
        }
        return nil
    }

    public func directory(_ id: String) -> URL {
        root.profiles.appendingPathComponent(id, isDirectory: true)
    }

    /// Every profile, oldest first.
    public func list() -> [Profile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.profiles.path)) ?? []
        return names.filter(Self.isValidID).compactMap(load).sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }

    private func load(_ id: String) -> Profile? {
        guard let data = try? Data(contentsOf: directory(id).appendingPathComponent("profile.ini")) else { return nil }
        return Profile.parse(id: id, text: String(decoding: data, as: UTF8.self))
    }

    /// The profile in use: the one `current-profile` names, else the oldest,
    /// else a new Default profile, which the first start creates.
    public func current() throws -> Profile {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: root.currentProfileFile) {
            let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isValidID(id), let profile = load(id) { return profile }
        }
        let profile = try list().first ?? make(name: "")
        try writeCurrent(profile.id)
        return profile
    }

    public func create(name: String) throws -> Profile {
        lock.lock()
        defer { lock.unlock() }
        if let problem = Self.nameProblem(name) { throw ProfileError.badName(problem) }
        try checkUnique(name, except: nil)
        return try make(name: name)
    }

    public func rename(_ id: String, to name: String) throws -> Profile {
        lock.lock()
        defer { lock.unlock() }
        if let problem = Self.nameProblem(name) { throw ProfileError.badName(problem) }
        guard var profile = load(id) else { throw ProfileError.notFound(id) }
        try checkUnique(name, except: id)
        profile.name = name
        try write(profile)
        return profile
    }

    /// Deletes a profile other than the one in use, with all its saves and settings.
    public func delete(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isValidID(id), load(id) != nil else { throw ProfileError.notFound(id) }
        if currentIDOnDisk() == id { throw ProfileError.isCurrent }
        let fm = FileManager.default
        let doomed = root.profiles.appendingPathComponent(".deleting-\(id)-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.moveItem(at: directory(id), to: doomed)
        } catch {
            throw ProfileError.io(error.localizedDescription)
        }
        try? fm.removeItem(at: doomed)
    }

    /// Makes `id` the profile in use.
    public func switchTo(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isValidID(id), load(id) != nil else { throw ProfileError.notFound(id) }
        try writeCurrent(id)
    }

    /// Removes what a profile creation or deletion cut short left.
    public func sweep() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.profiles.path)) ?? [] where name.hasPrefix(".") {
            try? fm.removeItem(at: root.profiles.appendingPathComponent(name))
        }
    }

    private func currentIDOnDisk() -> String? {
        guard let data = try? Data(contentsOf: root.currentProfileFile) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkUnique(_ name: String, except: String?) throws {
        if list().contains(where: { $0.id != except && $0.label.lowercased() == name.lowercased() }) {
            throw ProfileError.taken(name)
        }
    }

    private func make(name: String) throws -> Profile {
        let fm = FileManager.default
        try fm.ensureDirectory(root.profiles)
        var id: String
        repeat {
            id = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        } while fm.fileExists(atPath: directory(id).path)
        let profile = Profile(id: id, name: name, created: UInt64(Date().timeIntervalSince1970))
        // Built aside and renamed into place, so a profile is never half made.
        let staging = root.profiles.appendingPathComponent(".new-\(id)", isDirectory: true)
        try fm.createDirectory(at: staging.appendingPathComponent("launcher"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("apps"), withIntermediateDirectories: true)
        try Data(profile.rendered.utf8).write(to: staging.appendingPathComponent("profile.ini"))
        try fm.moveItem(at: staging, to: directory(id))
        return profile
    }

    private func write(_ profile: Profile) throws {
        try writeAtomically(Data(profile.rendered.utf8), to: directory(profile.id).appendingPathComponent("profile.ini"))
    }

    private func writeCurrent(_ id: String) throws {
        try writeAtomically(Data("\(id)\n".utf8), to: root.currentProfileFile)
    }
}

/// What a profile keeps of the Launcher, in `launcher/settings.ini` as on the
/// handheld: language, appearance and the favorite apps, one `favorite` line each.
public struct ProfileSettings: Equatable, Sendable {
    public enum Language: String, CaseIterable, Sendable {
        case system
        case english = "en"
        case chinese = "zh-CN"
    }

    public enum Appearance: String, CaseIterable, Sendable {
        case system
        case light
        case dark
    }

    public var language: Language = .system
    public var appearance: Appearance = .system
    public var favorites: [String] = []

    public init(language: Language = .system, appearance: Appearance = .system, favorites: [String] = []) {
        self.language = language
        self.appearance = appearance
        self.favorites = favorites
    }

    /// Unknown keys and bad values keep their defaults, so a handheld's file reads too.
    public static func parse(_ text: String) -> ProfileSettings {
        var settings = ProfileSettings()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "language": settings.language = Language(rawValue: value) ?? settings.language
            case "theme": settings.appearance = Appearance(rawValue: value) ?? settings.appearance
            case "favorite" where isValidAppID(value) && !settings.favorites.contains(value): settings.favorites.append(value)
            default: break
            }
        }
        return settings
    }

    public var rendered: String {
        var text = "language = \(language.rawValue)\ntheme = \(appearance.rawValue)\n"
        for id in favorites { text += "favorite = \(id)\n" }
        return text
    }
}

/// One profile's own files: settings, recent play times and each app's saves.
public struct ProfileStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    var settingsFile: URL { directory.appendingPathComponent("launcher/settings.ini") }
    var recentFile: URL { directory.appendingPathComponent("launcher/recent.ini") }

    /// The folder an app keeps its saves in, `GIZLET_SAVE_DIR`.
    public func saveDirectory(for appID: String) -> URL {
        directory.appendingPathComponent("apps/\(appID)", isDirectory: true)
    }

    public func loadSettings() -> ProfileSettings {
        guard let data = try? Data(contentsOf: settingsFile) else { return ProfileSettings() }
        return ProfileSettings.parse(String(decoding: data, as: UTF8.self))
    }

    public func save(_ settings: ProfileSettings) throws {
        try writeAtomically(Data(settings.rendered.utf8), to: settingsFile)
    }

    /// When each app last ran, seconds since 1970, as `<id> = <time>` lines.
    public func recent() -> [String: UInt64] {
        guard let data = try? Data(contentsOf: recentFile) else { return [:] }
        var times: [String: UInt64] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, isValidAppID(parts[0]), let time = UInt64(parts[1]) { times[parts[0]] = time }
        }
        return times
    }

    public func markPlayed(_ appID: String, at date: Date = Date()) throws {
        var times = recent()
        times[appID] = UInt64(date.timeIntervalSince1970)
        let text = times.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)\n" }.joined()
        try writeAtomically(Data(text.utf8), to: recentFile)
    }
}
