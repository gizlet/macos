import Foundation

public enum PackageKind: String, Codable, Sendable {
    case app
    case service
}

/// A package's `manifest.json`, as the build generates it from `gizlet.toml`.
/// See https://github.com/gizlet/gizlet/blob/main/docs/gizlet-toml.md#manifestjson
public struct Manifest: Codable, Equatable, Sendable {
    public var schema: Int?
    public var declaredKind: String?
    public var id: String
    public var name: String
    public var names: [String: String]?
    public var version: String
    public var description: String?
    public var descriptions: [String: String]?
    public var color: String?
    public var runtime: Int?
    public var target: String
    public var tier: String
    public var entry: String
    public var icon: String?

    enum CodingKeys: String, CodingKey {
        case schema, id, name, names, version, description, descriptions, color, runtime, target, tier, entry, icon
        case declaredKind = "kind"
    }

    public var kind: PackageKind { declaredKind == "service" ? .service : .app }

    /// Reads and checks a manifest: the schema and kind rules, a supported
    /// runtime, a reverse-DNS ID, the tier, a target triple and canonical paths.
    public static func parse(_ data: Data) throws -> Manifest {
        guard let first = data.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }), first == UInt8(ascii: "{") else {
            throw PackageError.invalid("manifest.json must be a JSON object")
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw PackageError.invalid("manifest.json cannot be read: \(error.localizedDescription)")
        }
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        switch (schema ?? 1, declaredKind) {
        case (1, nil), (1, "app"?), (2, "app"?), (2, "service"?):
            break
        case (1, let kind?):
            throw PackageError.invalid("manifest schema 1 is always an app, but it has kind \(kind)")
        case (2, nil):
            throw PackageError.invalid("manifest schema 2 must name its kind (app or service)")
        case (2, let kind?):
            throw PackageError.invalid("unsupported package kind \(kind)")
        case (let schema, _):
            throw PackageError.invalid("unsupported manifest schema \(schema)")
        }
        if let runtime, runtime != 1 {
            throw PackageError.invalid("unsupported Gizlet runtime \(runtime)")
        }
        for (field, value) in [("name", name), ("version", version), ("entry", entry)] where value.trimmingCharacters(in: .whitespaces).isEmpty {
            throw PackageError.invalid("manifest has no \(field)")
        }
        guard isValidAppID(id) else {
            throw PackageError.invalid("id \(id) must be reverse-DNS: lowercase letters, digits, '-' and '_' in dot-separated parts")
        }
        guard tier == "lite" || tier == "full" else {
            throw PackageError.invalid("tier \(tier) must be lite or full")
        }
        guard target.split(separator: "-").count >= 3 else {
            throw PackageError.invalid("target \(target) is not a target triple")
        }
        for (field, path) in [("entry", Optional(entry)), ("icon", icon)] {
            if let path, let problem = relativePathProblem(path) {
                throw PackageError.invalid("\(field) \(path) \(problem)")
            }
        }
    }

    /// The name in `language` (`zh-CN`, `en`), matching its primary subtag too.
    public func name(for language: String) -> String {
        localized(names ?? [:], language) ?? name
    }

    public func description(for language: String) -> String? {
        localized(descriptions ?? [:], language) ?? description
    }
}

/// The value for `language`, or for another tag with the same primary subtag.
public func localized(_ values: [String: String], _ language: String) -> String? {
    if let value = values[language] { return value }
    let primary = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? language
    return values.sorted(by: { $0.key < $1.key }).first(where: {
        $0.key.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) == primary
    })?.value
}

public enum PackageError: Error, Equatable, LocalizedError {
    case invalid(String)
    case unsupported(String)
    case running(String)
    case notInstalled(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): "Not a valid package: \(message)"
        case .unsupported(let message): message
        case .running(let id): "\(id) is running; quit it first"
        case .notInstalled(let id): "\(id) is not installed"
        case .io(let message): message
        }
    }
}
