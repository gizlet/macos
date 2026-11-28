import CryptoKit
import Foundation
import zlib

/// A raw card image ready to write, with its size and SHA-256.
public struct PreparedImage: Equatable, Sendable {
    public var url: URL
    public var size: UInt64
    public var sha256: String
    /// `GIZLETBOOT` partition 1 and the R36S disk signature: an image of Gizlet OS for the R36S.
    public var isGizletR36S: Bool
    public var releaseTag: String?
}

/// Where the image comes from.
public enum ImageSource: Equatable, Sendable {
    case release(OSImageRelease)
    case file(URL)
}

public enum PreparePhase: Equatable, Sendable {
    case downloading
    case verifying
    case unpacking
}

/// Downloads a release image (checking its size and SHA-256 against the signed
/// manifest) or reads a local `.img` or `.img.gz`, and unpacks gzip before the card is
/// touched: a raw disk takes whole sectors, and a corrupt image is caught first.
public struct ImagePreparer: Sendable {
    /// The most a gzip image may unpack to.
    static let maxImageBytes: UInt64 = 32_000_000_000
    public var cache: URL
    var session: URLSession

    public init(cache: URL, session: URLSession = .shared) {
        self.cache = cache
        self.session = session
    }

    public func prepare(_ source: ImageSource, progress: @escaping @Sendable (PreparePhase, UInt64, UInt64?) -> Void) async throws -> PreparedImage {
        let fm = FileManager.default
        try fm.ensureDirectory(cache)
        switch source {
        case .release(let release):
            let folder = cache.appendingPathComponent(release.tag, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: cache.path)) ?? [] where name != release.tag {
                try? fm.removeItem(at: cache.appendingPathComponent(name))
            }
            let download = folder.appendingPathComponent(release.fileName)
            do {
                try await Downloader(session: session).download(release.image, to: download, size: release.bytes, sha256: release.sha256) { done, total in
                    progress(.downloading, done, total)
                }
            } catch let error as DownloadError where error == .checksumMismatch || error == .sizeMismatch {
                throw FlashError.image("The downloaded image does not match its signed checksum; try again")
            }
            var image = try await unpack(download, into: folder, progress: progress)
            image.releaseTag = release.tag
            return image
        case .file(let file):
            return try await unpack(file, into: cache.appendingPathComponent("local", isDirectory: true), progress: progress)
        }
    }

    func unpack(_ file: URL, into folder: URL, progress: @escaping @Sendable (PreparePhase, UInt64, UInt64?) -> Void) async throws -> PreparedImage {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.ensureDirectory(folder)
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            let total = (try? fm.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0
            let head = try input.read(upToCount: 2) ?? Data()
            try input.seek(toOffset: 0)
            guard head.count == 2, head[0] == 0x1F, head[1] == 0x8B else {
                // A raw image is written from where it is.
                var hasher = SHA256()
                var done: UInt64 = 0
                while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(data: chunk)
                    done += UInt64(chunk.count)
                    progress(.verifying, done, total)
                }
                guard done > 0 else { throw FlashError.image("The image file is empty") }
                return PreparedImage(url: file, size: done, sha256: hasher.finalize().hex, isGizletR36S: Self.looksLikeR36S(file), releaseTag: nil)
            }
            let output = folder.appendingPathComponent("card.img")
            fm.createFile(atPath: output.path, contents: nil)
            let out = try FileHandle(forWritingTo: output)
            defer { try? out.close() }
            // A failed unpack leaves nothing behind in the cache.
            var finished = false
            defer { if !finished { try? fm.removeItem(at: output) } }
            var hasher = SHA256()
            var written: UInt64 = 0
            var decoder = GzipDecoder()
            var consumed: UInt64 = 0
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                consumed += UInt64(chunk.count)
                try decoder.feed(chunk) { piece in
                    hasher.update(bufferPointer: piece)
                    written += UInt64(piece.count)
                    guard written <= Self.maxImageBytes else { throw FlashError.image("The image unpacks to more than 32 GB, larger than any R36S card image") }
                    try out.write(contentsOf: Data(piece))
                }
                progress(.unpacking, consumed, total)
            }
            try decoder.finish()
            guard written > 0 else { throw FlashError.image("The image is empty") }
            finished = true
            return PreparedImage(url: output, size: written, sha256: hasher.finalize().hex, isGizletR36S: Self.looksLikeR36S(output), releaseTag: nil)
        }.value
    }

    /// The R36S image's MBR disk signature `36335030` and a valid boot record.
    static func looksLikeR36S(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let mbr = try? handle.read(upToCount: 512), mbr.count == 512 else { return false }
        try? handle.close()
        return mbr[510] == 0x55 && mbr[511] == 0xAA && mbr.u32(440) == 0x3633_5030
    }
}

/// Decodes gzip (RFC 1952), one or more members, checking each member's CRC-32 and length.
struct GzipDecoder {
    private enum State { case header, body, trailer, done }
    private var state = State.header
    private var pending = Data()
    private var inflater: Inflater?
    private var crc: uLong = 0
    private var length: UInt32 = 0
    private var members = 0

    mutating func feed(_ data: Data, _ sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        pending.append(data)
        while true {
            switch state {
            case .header:
                guard let size = try headerSize() else { return }
                pending.removeFirst(size)
                inflater = try Inflater()
                crc = crc32(0, nil, 0)
                length = 0
                state = .body
            case .body:
                guard !pending.isEmpty else { return }
                var crc = self.crc
                var length = self.length
                let used = try inflater!.feed(pending) { piece in
                    crc = crc32(crc, piece.bindMemory(to: Bytef.self).baseAddress, uInt(piece.count))
                    length &+= UInt32(truncatingIfNeeded: piece.count)
                    try sink(piece)
                }
                self.crc = crc
                self.length = length
                pending.removeFirst(used)
                if inflater!.finished { state = .trailer } else { return }
            case .trailer:
                guard pending.count >= 8 else { return }
                guard UInt32(truncatingIfNeeded: crc) == pending.u32(0) else { throw FlashError.image("The image is corrupt (CRC mismatch)") }
                guard length == pending.u32(4) else { throw FlashError.image("The image is corrupt (length mismatch)") }
                pending.removeFirst(8)
                members += 1
                state = .done
            case .done:
                // Another member may follow; trailing zeros are padding.
                guard let first = pending.first else { return }
                if first == 0x1F { state = .header } else if pending.allSatisfy({ $0 == 0 }) { pending.removeAll(); return } else {
                    throw FlashError.image("The image has data after its end")
                }
            }
        }
    }

    func finish() throws {
        guard state == .done, members > 0 else { throw FlashError.image("The image is cut short") }
    }

    /// The size of a complete gzip header at the start of `pending`; nil until it has arrived.
    private func headerSize() throws -> Int? {
        guard pending.count >= 10 else { return nil }
        let base = pending.startIndex
        guard pending[base] == 0x1F, pending[base + 1] == 0x8B, pending[base + 2] == 8 else { throw FlashError.image("The image is not gzip") }
        let flags = pending[base + 3]
        guard flags & 0xE0 == 0 else { throw FlashError.image("The image uses unknown gzip flags") }
        var offset = 10
        if flags & 0x04 != 0 {
            guard pending.count >= offset + 2 else { return nil }
            offset += 2 + Int(pending.u16(offset))
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            guard let end = pending[(base + min(offset, pending.count))...].firstIndex(of: 0) else { return nil }
            offset = end - base + 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        return pending.count >= offset ? offset : nil
    }
}
