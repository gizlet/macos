import CryptoKit
import Foundation

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// The SHA-256 of a file, read in 1 MiB pieces.
public func sha256(of url: URL, progress: ((Int64) -> Void)? = nil) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var total: Int64 = 0
    while true {
        let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
        total += Int64(chunk.count)
        progress?(total)
    }
    return hasher.finalize().hex
}

public func sha256(of data: Data) -> String {
    SHA256.hash(data: data).hex
}
