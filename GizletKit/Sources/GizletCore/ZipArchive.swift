import CryptoKit
import Foundation

/// One file or folder in a package's zip directory.
public struct ZipEntry: Equatable, Sendable {
    public var name: String
    public var method: UInt16
    public var compressedSize: UInt64
    public var size: UInt64
    public var localOffset: UInt64
    public var isDirectory: Bool
    public var isExecutable: Bool
}

/// Reads `.gzl` packages: zips with stored or deflated entries whose names are
/// canonical relative paths. Links, devices, setuid files, encryption, ZIP64,
/// split archives, renamed entries and names that collide by case or Unicode
/// form are refused, as Gizlet OS and the Store refuse them.
public final class ZipArchive {
    public static let maxEntries = 65_535
    public static let maxDirectoryBytes: UInt64 = 16 << 20

    public let url: URL
    public let entries: [ZipEntry]
    private let handle: FileHandle
    private let length: UInt64

    public init(url: URL) throws {
        self.url = url
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PackageError.io("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        length = try handle.seekToEnd()
        entries = try Self.readDirectory(handle, length: length)
    }

    deinit {
        try? handle.close()
    }

    public func entry(named name: String) -> ZipEntry? {
        entries.first { $0.name == name && !$0.isDirectory }
    }

    /// The whole contents of a small entry, at most `limit` bytes.
    public func read(_ entry: ZipEntry, limit: UInt64) throws -> Data {
        guard entry.size <= limit else { throw PackageError.invalid("\(entry.name) is too large") }
        var data = Data()
        try extract(entry) { data.append(contentsOf: $0) }
        return data
    }

    /// Streams an entry's decoded bytes to `sink`; fails unless exactly its size comes out.
    public func extract(_ entry: ZipEntry, to sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        try withoutActuallyEscaping(sink) { sink in try extractEscaping(entry, to: sink) }
    }

    private func extractEscaping(_ entry: ZipEntry, to sink: @escaping (UnsafeRawBufferPointer) throws -> Void) throws {
        let damaged = PackageError.invalid("damaged entry for \(entry.name)")
        try handle.seek(toOffset: entry.localOffset)
        guard let local = try handle.read(upToCount: 30), local.count == 30, local.u32(0) == 0x0403_4B50 else { throw damaged }
        let nameLength = Int(local.u16(26))
        let extraLength = UInt64(local.u16(28))
        guard let rawName = try handle.read(upToCount: nameLength), rawName.count == nameLength else { throw damaged }
        let localName = String(decoding: rawName, as: UTF8.self)
        guard localName.hasSuffix("/") ? String(localName.dropLast()) == entry.name : localName == entry.name else {
            throw PackageError.invalid("\(entry.name) is named differently in its local header")
        }
        let dataStart = entry.localOffset + 30 + UInt64(nameLength) + extraLength
        guard dataStart + entry.compressedSize <= length else { throw damaged }
        try handle.seek(toOffset: dataStart)

        var remaining = entry.compressedSize
        var produced: UInt64 = 0
        let count: (UnsafeRawBufferPointer) throws -> Void = { piece in
            produced += UInt64(piece.count)
            guard produced <= entry.size else { throw PackageError.invalid("\(entry.name) has the wrong size") }
            try sink(piece)
        }
        let inflater = entry.method == 8 ? try Inflater() : nil
        while remaining > 0 {
            let piece = try handle.read(upToCount: Int(min(remaining, 1 << 20))) ?? Data()
            guard !piece.isEmpty else { throw damaged }
            remaining -= UInt64(piece.count)
            if let inflater {
                try inflater.feed(piece, final: remaining == 0, count)
            } else {
                try piece.withUnsafeBytes { try count($0) }
            }
        }
        if let inflater, !inflater.finished {
            try inflater.feed(Data(), final: true, count)
        }
        guard produced == entry.size else { throw PackageError.invalid("\(entry.name) has the wrong size") }
    }

    private static func readDirectory(_ handle: FileHandle, length: UInt64) throws -> [ZipEntry] {
        func bad(_ what: String) -> PackageError { .invalid(what) }
        let tailLength = min(length, 22 + 0xFFFF)
        try handle.seek(toOffset: length - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        guard tail.count >= 22,
              let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: { tail.u32($0) == 0x0605_4B50 })
        else { throw bad("no zip directory") }
        let disk = tail.u16(eocd + 4), directoryDisk = tail.u16(eocd + 6)
        let countHere = tail.u16(eocd + 8), count = tail.u16(eocd + 10)
        let directorySize = UInt64(tail.u32(eocd + 12)), directoryOffset = UInt64(tail.u32(eocd + 16))
        guard disk == 0, directoryDisk == 0, countHere == count else { throw bad("split archives are not supported") }
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else { throw bad("ZIP64 is not supported") }
        guard Int(count) <= maxEntries else { throw bad("too many files") }
        guard directoryOffset + directorySize <= length else { throw bad("a damaged zip directory") }
        guard directorySize <= maxDirectoryBytes else { throw bad("a zip directory larger than 16 MiB") }
        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()
        guard directory.count == Int(directorySize) else { throw bad("a damaged zip directory") }

        var entries: [ZipEntry] = []
        var seen = Set<String>()
        var position = 0
        for _ in 0..<Int(count) {
            guard position + 46 <= directory.count, directory.u32(position) == 0x0201_4B50 else { throw bad("a damaged zip directory") }
            let madeBy = directory.u16(position + 4)
            let flags = directory.u16(position + 8)
            let method = directory.u16(position + 10)
            let compressed = UInt64(directory.u32(position + 20))
            let size = UInt64(directory.u32(position + 24))
            let nameLength = Int(directory.u16(position + 28))
            let extraLength = Int(directory.u16(position + 30))
            let commentLength = Int(directory.u16(position + 32))
            let external = directory.u32(position + 38)
            let localOffset = UInt64(directory.u32(position + 42))
            let end = position + 46 + nameLength + extraLength + commentLength
            guard end <= directory.count else { throw bad("a damaged zip directory") }
            let rawName = directory.subdata(in: (position + 46)..<(position + 46 + nameLength))
            let extra = directory.subdata(in: (position + 46 + nameLength)..<(position + 46 + nameLength + extraLength))
            position = end

            guard flags & 0x41 == 0 else { throw bad("encrypted files") }
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else { throw bad("ZIP64 is not supported") }
            if flags & 0x800 == 0, rawName.contains(where: { $0 >= 0x80 }) {
                throw bad("a file name that is neither ASCII nor UTF-8")
            }
            guard let name = String(data: rawName, encoding: .utf8) else { throw bad("a file name that is not UTF-8") }
            var x = 0
            while x + 4 <= extra.count {
                if extra.u16(x) == 0x7075 { throw bad("a renamed file (Unicode Path extra field)") }
                x += 4 + Int(extra.u16(x + 2))
            }
            let directoryName = name.hasSuffix("/")
            let path = directoryName ? String(name.dropLast()) : name
            if let problem = relativePathProblem(path) { throw bad("\(path) \(problem)") }
            let mode = madeBy >> 8 == 3 ? external >> 16 : 0
            let type = mode & 0o170000
            guard type == 0 || type == 0o100000 || type == 0o040000 else { throw bad("\(path) is a link or a device") }
            guard mode & 0o6000 == 0 else { throw bad("\(path) is setuid or setgid") }
            if !directoryName, method != 0, method != 8 { throw bad("\(path) uses compression method \(method)") }
            // macOS file systems fold case and Unicode form: two such names would land on one file.
            guard seen.insert(path.decomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw bad("\(path) appears twice")
            }
            entries.append(ZipEntry(name: path, method: method, compressedSize: compressed, size: size, localOffset: localOffset,
                                    isDirectory: directoryName || type == 0o040000, isExecutable: mode & 0o111 != 0))
        }
        let files = Set(entries.filter { !$0.isDirectory }.map { $0.name.decomposedStringWithCanonicalMapping.lowercased() })
        for entry in entries {
            var parent = Substring(entry.name.decomposedStringWithCanonicalMapping.lowercased())
            while let slash = parent.lastIndex(of: "/") {
                parent = parent[..<slash]
                if files.contains(String(parent)) { throw bad("\(parent) is both a file and a folder") }
            }
        }
        return entries
    }
}

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func u32BE(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
}
