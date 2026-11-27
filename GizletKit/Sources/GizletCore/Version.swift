import Foundation

/// A `MAJOR.MINOR.PATCH` release version, as the `vMAJOR.MINOR.PATCH` tags name them.
public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable, Hashable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init?(_ text: String) {
        let text = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 9, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  part == "0" || !part.hasPrefix("0") else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }
    public var tag: String { "v\(description)" }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
