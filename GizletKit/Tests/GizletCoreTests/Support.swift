import CryptoKit
import Foundation
@testable import GizletCore
import Testing
import zlib

/// A fresh folder under the temporary directory.
func temporaryDirectory(_ name: String = #function) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gizlet-tests-\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// One zip entry: its name, bytes and Unix mode (0o100644 for a file, 0o120777 for a link).
struct ZipFile {
    var name: String
    var data: Data
    var mode: UInt32 = 0o100644
    var deflate = false
}

/// Writes a zip with stored or deflated entries, as a `.gzl` build does.
func makeZip(_ files: [ZipFile], unicodeExtra: Bool = false) -> Data {
    var out = Data()
    var directory = Data()
    func u16(_ value: Int, _ data: inout Data) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
    func u32(_ value: UInt32, _ data: inout Data) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(value >> UInt32(shift) & 0xFF)) } }
    for file in files {
        let name = Data(file.name.utf8)
        let crc = file.data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
        let body = file.deflate ? deflate(file.data) : file.data
        let extra = unicodeExtra ? Data([0x75, 0x70, 0x00, 0x00]) : Data()
        let offset = UInt32(out.count)
        u32(0x0403_4B50, &out); u16(20, &out); u16(0x800, &out); u16(file.deflate ? 8 : 0, &out); u16(0, &out); u16(0, &out)
        u32(crc, &out); u32(UInt32(body.count), &out); u32(UInt32(file.data.count), &out)
        u16(name.count, &out); u16(0, &out); out.append(name); out.append(body)
        u32(0x0201_4B50, &directory); u16(0x31E, &directory); u16(20, &directory); u16(0x800, &directory); u16(file.deflate ? 8 : 0, &directory)
        u16(0, &directory); u16(0, &directory); u32(crc, &directory); u32(UInt32(body.count), &directory); u32(UInt32(file.data.count), &directory)
        u16(name.count, &directory); u16(extra.count, &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory)
        u32(file.mode << 16, &directory); u32(offset, &directory); directory.append(name); directory.append(extra)
    }
    let directoryOffset = UInt32(out.count)
    out.append(directory)
    u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
    u32(UInt32(directory.count), &out); u32(directoryOffset, &out); u16(0, &out)
    return out
}

/// Raw DEFLATE of `data`, through zlib with negative window bits.
func deflate(_ data: Data) -> Data {
    var stream = z_stream()
    deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    defer { deflateEnd(&stream) }
    var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))) + 64)
    var input = [UInt8](data)
    input.withUnsafeMutableBufferPointer { inputBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer in
            stream.next_in = inputBuffer.baseAddress
            stream.avail_in = uInt(inputBuffer.count)
            stream.next_out = outputBuffer.baseAddress
            stream.avail_out = uInt(outputBuffer.count)
            deflate(&stream, Z_FINISH)
        }
    }
    return Data(output.prefix(Int(stream.total_out)))
}

let hostTarget = Platform.current.primaryTarget

func manifestJSON(id: String = "dev.example.hello", name: String = "Hello", version: String = "1.0.0",
                  target: String = hostTarget, tier: String = "lite", entry: String = "bin/hello", extra: String = "") -> String {
    #"{"schema": 1, "id": "\#(id)", "name": "\#(name)", "version": "\#(version)", "target": "\#(target)", "tier": "\#(tier)", "entry": "\#(entry)"\#(extra)}"#
}

let helloScript = Data("#!/bin/sh\necho \"hello $GIZLET_APP_ID\"\n".utf8)

/// A package with `manifest.json`, the files given and a `CHECKSUMS` listing them all.
func makePackage(manifest: String = manifestJSON(), files: [ZipFile] = [ZipFile(name: "bin/hello", data: helloScript, mode: 0o100755)],
                 checksums: String? = nil, deflate: Bool = true) -> Data {
    var all = [ZipFile(name: "manifest.json", data: Data(manifest.utf8), deflate: deflate)] + files.map {
        var file = $0
        file.deflate = deflate && file.mode & 0o170000 == 0o100000
        return file
    }
    let sums = checksums ?? all.filter { $0.mode & 0o170000 == 0o100000 }.map { "\(sha256(of: $0.data))  \($0.name)\n" }.joined()
    all.append(ZipFile(name: "CHECKSUMS", data: Data(sums.utf8)))
    return makeZip(all)
}

func write(_ data: Data, to directory: URL, name: String = "package.gzl") throws -> URL {
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Signs `message` with a fresh Ed25519 key through ssh-keygen; returns the
/// public key line and the armored signature.
func sshSign(_ message: Data, namespace: String) throws -> (key: String, signature: String) {
    let directory = try temporaryDirectory("sshsign")
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = directory.appendingPathComponent("key")
    try runTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path])
    let file = directory.appendingPathComponent("message")
    try message.write(to: file)
    try runTool("/usr/bin/ssh-keygen", ["-q", "-Y", "sign", "-f", key.path, "-n", namespace, file.path])
    let publicKey = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
    let signature = try String(contentsOf: file.appendingPathExtension("sig"), encoding: .utf8)
    return (publicKey.trimmingCharacters(in: .whitespacesAndNewlines), signature)
}

@discardableResult
func runTool(_ tool: String, _ arguments: [String], input: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    if let input {
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(input)
        try pipe.fileHandleForWriting.close()
    } else {
        try process.run()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw PackageError.io("\(tool) failed") }
    return data
}

/// Serves canned answers to URLSession requests by URL, for the Store and download tests.
final class StubProtocol: URLProtocol {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    // Suites run in parallel and share these: every read and change holds the lock.
    nonisolated(unsafe) private static var storedResponses: [String: Response] = [:]
    nonisolated(unsafe) private static var storedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var storedOnLoad: [String: () -> Void] = [:]
    static let lock = NSLock()

    static var responses: [String: Response] {
        get { lock.withLock { storedResponses } }
        _modify {
            lock.lock()
            defer { lock.unlock() }
            yield &storedResponses
        }
    }

    static var requests: [URLRequest] {
        get { lock.withLock { storedRequests } }
        _modify {
            lock.lock()
            defer { lock.unlock() }
            yield &storedRequests
        }
    }

    /// Runs before the answer to a URL is sent, as something happening during a download.
    static var onLoad: [String: () -> Void] {
        get { lock.withLock { storedOnLoad } }
        _modify {
            lock.lock()
            defer { lock.unlock() }
            yield &storedOnLoad
        }
    }

    static func session(_ responses: [String: Response]) -> URLSession {
        self.responses.merge(responses) { $1 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url!.absoluteString
        let (stub, hook) = Self.lock.withLock { () -> (Response?, (() -> Void)?) in
            Self.storedRequests.append(request)
            return (Self.storedResponses[key] ?? Self.storedResponses[key.components(separatedBy: "?")[0]], Self.storedOnLoad.removeValue(forKey: key))
        }
        hook?()
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        var body = stub.body
        var status = stub.status
        var headers = stub.headers
        if let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).dropLast()), status == 200 {
            body = body.subdata(in: start..<body.count)
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(stub.body.count - 1)/\(stub.body.count)"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
