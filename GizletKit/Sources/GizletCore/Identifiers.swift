import Foundation

/// A package ID: reverse-DNS, at least two dot-separated parts of lowercase
/// letters, digits, `-` and `_`, at most 128 bytes. A device keeps saves under it.
public func isValidAppID(_ id: String) -> Bool {
    let parts = id.split(separator: ".", omittingEmptySubsequences: false)
    guard id.utf8.count <= 128, parts.count >= 2 else { return false }
    return parts.allSatisfy { part in
        !part.isEmpty && part.utf8.allSatisfy { byte in
            (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x5F
        }
    }
}

/// Why `name` is not a canonical relative path inside a package: `/`-separated,
/// no empty, `.` or `..` parts, no backslash, NUL or `:`; nil when it is one.
public func relativePathProblem(_ name: String) -> String? {
    if name.isEmpty { return "is empty" }
    if name.hasPrefix("/") || name.contains("\\") || name.contains("\0") || name.contains(":") {
        return "is not a relative path"
    }
    if name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
        return "has an empty, . or .. part"
    }
    return nil
}

/// Lowercase hexadecimal SHA-256.
public func isSHA256Hex(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
}
