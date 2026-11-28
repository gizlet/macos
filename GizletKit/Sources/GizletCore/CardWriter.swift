import CryptoKit
import Foundation

public enum WritePhase: Equatable, Sendable {
    case writing
    case verifying
}

/// Writes a prepared image to an open raw disk and reads it back: every byte
/// written must come back the same. A last piece shorter than a sector is
/// padded with zeros, as raw disks take whole sectors.
public final class CardWriter: @unchecked Sendable {
    public static let chunk = 4 << 20
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// `descriptor` is the open raw disk of `capacity` bytes; it is not closed here.
    public func write(_ image: PreparedImage, to descriptor: Int32, blockSize: Int, capacity: UInt64,
                      progress: (WritePhase, UInt64, UInt64) -> Void) throws {
        guard blockSize > 0, Self.chunk % blockSize == 0 else { throw FlashError.write("The card reports an unusual sector size (\(blockSize))") }
        let padded = (image.size + UInt64(blockSize) - 1) / UInt64(blockSize) * UInt64(blockSize)
        guard padded <= capacity else { throw FlashError.write("The card is smaller than the image") }
        _ = fcntl(descriptor, F_NOCACHE, 1)
        // The image file must still be the one checked: its bytes are hashed as they are written.
        let current = (try? FileManager.default.attributesOfItem(atPath: image.url.path)[.size] as? UInt64) ?? 0
        guard current == image.size else { throw FlashError.image("The image file changed since it was checked; nothing was written") }
        var hasher = SHA256()
        let source = try FileHandle(forReadingFrom: image.url)
        defer { try? source.close() }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 4096)
        let readBack = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 4096)
        defer {
            buffer.deallocate()
            readBack.deallocate()
        }

        var offset: UInt64 = 0
        while offset < image.size {
            if isCancelled { throw FlashError.cancelled }
            let length = try fill(buffer, from: source, at: offset, size: image.size)
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: length))
            let rounded = (length + blockSize - 1) / blockSize * blockSize
            if rounded > length { buffer.advanced(by: length).initializeMemory(as: UInt8.self, repeating: 0, count: rounded - length) }
            try transfer(rounded, at: offset) { pwrite(descriptor, buffer.advanced(by: $0), $1, off_t($2)) }
            offset += UInt64(length)
            progress(.writing, offset, image.size)
        }
        guard hasher.finalize().hex == image.sha256 else {
            throw FlashError.verify("The image file changed while it was written; the card is incomplete. Write it again.")
        }
        guard fsync(descriptor) == 0 else { throw FlashError.write("The card did not finish writing (\(String(cString: strerror(errno))))") }
        _ = ioctl(descriptor, 0x2000_6416)  // DKIOCSYNCHRONIZE: flush the reader's own cache.

        offset = 0
        while offset < image.size {
            if isCancelled { throw FlashError.cancelled }
            let length = try fill(buffer, from: source, at: offset, size: image.size)
            let rounded = (length + blockSize - 1) / blockSize * blockSize
            try transfer(rounded, at: offset) { pread(descriptor, readBack.advanced(by: $0), $1, off_t($2)) }
            guard memcmp(buffer, readBack, length) == 0 else {
                throw FlashError.verify("The card returned different data at byte \(offset); it may be failing. Try another card.")
            }
            offset += UInt64(length)
            progress(.verifying, offset, image.size)
        }
    }

    private func fill(_ buffer: UnsafeMutableRawPointer, from source: FileHandle, at offset: UInt64, size: UInt64) throws -> Int {
        let want = Int(min(UInt64(Self.chunk), size - offset))
        try source.seek(toOffset: offset)
        var filled = 0
        while filled < want {
            guard let data = try source.read(upToCount: want - filled), !data.isEmpty else { throw FlashError.image("The image ended early") }
            data.copyBytes(to: buffer.advanced(by: filled).assumingMemoryBound(to: UInt8.self), count: data.count)
            filled += data.count
        }
        return filled
    }

    /// Repeats a pread or pwrite until `length` bytes moved at `offset`.
    private func transfer(_ length: Int, at offset: UInt64, _ io: (Int, Int, UInt64) -> Int) throws {
        var done = 0
        while done < length {
            let moved = io(done, length - done, offset + UInt64(done))
            if moved < 0 {
                if errno == EINTR { continue }
                throw FlashError.write("The card stopped at byte \(offset + UInt64(done)) (\(String(cString: strerror(errno)))); write it again before using it")
            }
            guard moved > 0 else { throw FlashError.write("The card ended at byte \(offset + UInt64(done))") }
            done += moved
        }
    }
}
