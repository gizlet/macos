import CryptoKit
import Foundation

public enum DownloadError: Error, LocalizedError, Equatable {
    case http(Int)
    case sizeMismatch
    case checksumMismatch
    case tooLarge
    case offline

    public var errorDescription: String? {
        switch self {
        case .http(let status): "The download failed (HTTP \(status))"
        case .sizeMismatch: "The download did not match its size; try again"
        case .checksumMismatch: "The download is damaged (SHA-256 mismatch); try again"
        case .tooLarge: "The download is larger than expected"
        case .offline: "The download stopped; check the connection and try again"
        }
    }
}

/// Downloads a file to `<destination>.part`, resuming a partial file with a
/// Range request, and renames it to `destination` once it has `size` bytes
/// and the `sha256` given. Without a known size it downloads up to `limit`.
public struct Downloader: Sendable {
    var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(_ url: URL, to destination: URL, size: UInt64?, sha256 expected: String?, limit: UInt64 = 4 << 30,
                         progress: @Sendable (UInt64, UInt64?) -> Void = { _, _ in }) async throws {
        let fm = FileManager.default
        try fm.ensureDirectory(destination.deletingLastPathComponent())
        if let expected, fm.fileExists(atPath: destination.path), (try? sha256(of: destination)) == expected {
            return
        }
        let part = destination.appendingPathExtension("part")
        var attempts = 0
        while true {
            attempts += 1
            let have = (try? fm.attributesOfItem(atPath: part.path)[.size] as? UInt64) ?? 0
            if let size, have > size { try? fm.removeItem(at: part) }
            if let size, have == size { break }
            do {
                let done = try await fetch(url, into: part, from: (size != nil && have > 0) ? have : 0, size: size, limit: limit, progress: progress)
                if done { break }
            } catch let error as URLError {
                if attempts >= 5 { throw DownloadError.offline }
                if error.code == .cancelled { throw CancellationError() }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            if attempts >= 5 { throw DownloadError.sizeMismatch }
        }
        if let size, ((try? fm.attributesOfItem(atPath: part.path)[.size] as? UInt64) ?? 0) != size {
            try? fm.removeItem(at: part)
            throw DownloadError.sizeMismatch
        }
        if let expected, try sha256(of: part) != expected {
            try? fm.removeItem(at: part)
            throw DownloadError.checksumMismatch
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: part, to: destination)
    }

    /// Appends the bytes from `offset` to `part`; true once the server sent the whole rest.
    private func fetch(_ url: URL, into part: URL, from offset: UInt64, size: UInt64?, limit: UInt64,
                       progress: @Sendable (UInt64, UInt64?) -> Void) async throws -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let fm = FileManager.default
        var written = offset
        if status == 200 {
            fm.createFile(atPath: part.path, contents: nil)
            written = 0
        } else if status == 206, offset > 0 {
            // Resuming.
        } else if status == 416, offset > 0 {
            try? fm.removeItem(at: part)
            return false
        } else {
            throw DownloadError.http(status)
        }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seek(toOffset: written)
        try handle.truncate(atOffset: written)
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var lastReport = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if written > (size ?? limit) { throw DownloadError.tooLarge }
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    progress(written, size)
                    lastReport = Date()
                }
                try Task.checkCancellation()
            }
        }
        try handle.write(contentsOf: buffer)
        written += UInt64(buffer.count)
        if written > (size ?? limit) { throw DownloadError.tooLarge }
        progress(written, size)
        return size == nil || written == size
    }
}
