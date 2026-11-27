import Foundation
import zlib

/// A streaming raw DEFLATE decoder (RFC 1951), as zip entries and gzip members
/// hold. zlib stops at the exact end of the stream, so the bytes after it (a
/// gzip trailer, the next member) are left to the caller.
final class Inflater {
    private var stream = z_stream()
    private let output: UnsafeMutablePointer<UInt8>
    private let outputSize = 1 << 20
    private(set) var finished = false

    init() throws {
        output = .allocate(capacity: outputSize)
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            output.deallocate()
            throw PackageError.io("cannot start the decompressor")
        }
    }

    deinit {
        inflateEnd(&stream)
        output.deallocate()
    }

    /// Decodes `input`, the next compressed bytes, handing each decoded piece to
    /// `sink`. Returns how many input bytes were used: fewer than given once the
    /// DEFLATE stream ended. With `final`, the stream must end within `input`.
    @discardableResult
    func feed(_ input: Data, final: Bool = false, _ sink: (UnsafeRawBufferPointer) throws -> Void) throws -> Int {
        if finished { return 0 }
        let used = try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress, !raw.isEmpty else { return 0 }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(raw.count)
            while true {
                stream.next_out = output
                stream.avail_out = uInt(outputSize)
                let status = inflate(&stream, Z_NO_FLUSH)
                let produced = outputSize - Int(stream.avail_out)
                if produced > 0 {
                    try sink(UnsafeRawBufferPointer(start: output, count: produced))
                }
                switch status {
                case Z_STREAM_END:
                    finished = true
                    return raw.count - Int(stream.avail_in)
                case Z_OK, Z_BUF_ERROR:
                    if stream.avail_in == 0 && produced < outputSize { return raw.count }
                    if status == Z_BUF_ERROR && produced == 0 { throw PackageError.invalid("damaged compressed data") }
                default:
                    throw PackageError.invalid("damaged compressed data")
                }
            }
        }
        if final && !finished { throw PackageError.invalid("damaged compressed data") }
        return used
    }
}
