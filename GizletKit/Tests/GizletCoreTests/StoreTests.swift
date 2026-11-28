import Darwin
import Foundation
@testable import GizletCore
import Testing

@Suite(.serialized) struct StoreTests {
    let api = URL(string: "https://store.test")!

    func offer(repo: String, repositoryID: UInt64, package: Data, version: String = "1.0.0") -> StubProtocol.Response {
        let sha = sha256(of: package)
        let url = "https://dl.test/\(repo.replacingOccurrences(of: "/", with: "_"))-\(version).gzl"
        StubProtocol.responses[url] = .init(status: 200, body: package)
        let body = """
            {"repo": "\(repo)", "repository_id": \(repositoryID), "id": "dev.example.hello", "name": "Hello", "kind": "app",
             "version": "\(version)", "tag": "v\(version)",
             "package": {"file": "x.gzl", "target": "\(hostTarget)", "tier": "lite", "size": \(package.count), "sha256": "\(sha)", "url": "\(url)"}}
            """
        return .init(status: 200, body: Data(body.utf8))
    }

    func installer(_ directory: URL, _ stubs: [String: StubProtocol.Response]) -> StoreInstaller {
        let session = StubProtocol.session(stubs)
        return StoreInstaller(library: AppLibrary(root: DataRoot(url: directory)), client: StoreClient(api: api, session: session),
                              downloader: Downloader(session: session))
    }

    @Test func installsFromTheStoreAndRecordsTheOrigin() async throws {
        let directory = try temporaryDirectory()
        let stubs = ["https://store.test/v1/gizlets/github.com/dev/hello/install": offer(repo: "github.com/dev/hello", repositoryID: 7, package: makePackage())]
        let store = installer(directory, stubs)
        let app = try await store.install(repo: "github.com/dev/hello", isRunning: { _ in false }, progress: { _, _ in })
        #expect(app.id == "dev.example.hello")
        #expect(store.origins()["dev.example.hello"]?.repositoryID == 7)
        #expect(store.origins()["dev.example.hello"]?.repo == "github.com/dev/hello")
    }

    @Test func refusesAnotherRepositoryClaimingAnInstalledApp() async throws {
        let directory = try temporaryDirectory()
        let store = installer(directory, [
            "https://store.test/v1/gizlets/github.com/dev/hello/install": offer(repo: "github.com/dev/hello", repositoryID: 7, package: makePackage()),
            "https://store.test/v1/gizlets/github.com/evil/hello/install": offer(repo: "github.com/evil/hello", repositoryID: 9, package: makePackage(manifest: manifestJSON(version: "9.0.0"))),
        ])
        try await store.install(repo: "github.com/dev/hello", isRunning: { _ in false }, progress: { _, _ in })
        await #expect(throws: StoreInstallError.otherSource(id: "dev.example.hello", from: "github.com/dev/hello")) {
            try await store.install(repo: "github.com/evil/hello", isRunning: { _ in false }, progress: { _, _ in })
        }
        #expect(store.library.app("dev.example.hello")?.manifest.version == "1.0.0")
    }

    @Test func rejectedOriginDoesNotReplaceInstalledPackage() throws {
        let directory = try temporaryDirectory()
        let store = installer(directory, [:])
        let id = "dev.example.hello"
        let firstPackage = try write(makePackage(), to: directory, name: "first.gzl")
        let firstOrigin = StoreOrigin(repo: "github.com/dev/hello", repositoryID: 7, version: "1.0.0",
                                      tag: "v1.0.0", sha256: try sha256(of: firstPackage))
        _ = try store.library.install(firstPackage, expectedID: id, origin: firstOrigin, isRunning: { _ in false })
        let replacement = try write(makePackage(manifest: manifestJSON(version: "2.0.0")), to: directory, name: "replacement.gzl")
        var invalidOrigin = firstOrigin
        invalidOrigin.tag = String(repeating: "a", count: 65_537)
        #expect(throws: PackageError.invalid("the app source record is too large")) {
            try store.library.install(replacement, expectedID: id, origin: invalidOrigin, isRunning: { _ in false })
        }
        let reopened = installer(directory, [:])
        #expect(reopened.library.app(id)?.manifest.version == "1.0.0")
        #expect(reopened.origin(for: id) == firstOrigin)
    }

    @Test func localReplacementIgnoresLegacyStoreOrigin() throws {
        let directory = try temporaryDirectory()
        let store = installer(directory, [:])
        let firstPackage = try write(makePackage(), to: directory, name: "first.gzl")
        let first = try store.library.install(firstPackage)
        let legacyOrigin = StoreOrigin(repo: "github.com/dev/hello", repositoryID: 7, version: "1.0.0",
                                       tag: "v1.0.0", sha256: try sha256(of: firstPackage))
        let legacyFile = store.library.root.store.appendingPathComponent("origins.json")
        try writeAtomically(JSONEncoder().encode([first.id: legacyOrigin]), to: legacyFile)
        try #require(removexattr(first.directory.path, "io.gizlet.store-origin", XATTR_NOFOLLOW) == 0)
        #expect(store.origin(for: first.id) == legacyOrigin)
        let replacement = try write(makePackage(manifest: manifestJSON(version: "2.0.0")), to: directory, name: "replacement.gzl")
        try store.installFile(replacement, isRunning: { _ in false })
        let reopened = installer(directory, [:])
        #expect(reopened.library.app(first.id)?.manifest.version == "2.0.0")
        #expect(reopened.origin(for: first.id) == nil)
        #expect(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    @Test func refusesARepositoryReplacedAtTheSamePath() async throws {
        let directory = try temporaryDirectory()
        let key = "https://store.test/v1/gizlets/github.com/dev/hello/install"
        let store = installer(directory, [key: offer(repo: "github.com/dev/hello", repositoryID: 7, package: makePackage())])
        try await store.install(repo: "github.com/dev/hello", isRunning: { _ in false }, progress: { _, _ in })
        StubProtocol.responses[key] = offer(repo: "github.com/dev/hello", repositoryID: 8, package: makePackage(manifest: manifestJSON(version: "2.0.0")))
        await #expect(throws: StoreInstallError.repositoryChanged(id: "dev.example.hello")) {
            try await store.install(repo: "github.com/dev/hello", isRunning: { _ in false }, progress: { _, _ in })
        }
    }

    @Test func checksAgainWhatIsInstalledAfterDownloading() async throws {
        let directory = try temporaryDirectory()
        let response = offer(repo: "github.com/dev/late", repositoryID: 5, package: makePackage(manifest: manifestJSON(version: "2.0.0")))
        let store = installer(directory, ["https://store.test/v1/gizlets/github.com/dev/late/install": response])
        let local = try write(makePackage(manifest: manifestJSON(version: "1.5.0")), to: directory, name: "local.gzl")
        // While the Store package downloads, the user installs the same app from a file.
        let packageURL = try #require(String(decoding: response.body, as: UTF8.self).range(of: #"https://dl\.test/[^"]+"#, options: .regularExpression))
        StubProtocol.onLoad[String(String(decoding: response.body, as: UTF8.self)[packageURL])] = {
            _ = try? store.installFile(local, isRunning: { _ in false })
        }
        await #expect(throws: StoreInstallError.otherSource(id: "dev.example.hello", from: nil)) {
            try await store.install(repo: "github.com/dev/late", isRunning: { _ in false }, progress: { _, _ in })
        }
        #expect(store.library.app("dev.example.hello")?.manifest.version == "1.5.0")
        #expect(store.origins()["dev.example.hello"] == nil)
    }

    @Test func refusesADamagedDownload() async throws {
        let directory = try temporaryDirectory()
        var response = offer(repo: "github.com/dev/broken", repositoryID: 3, package: makePackage())
        let text = String(decoding: response.body, as: UTF8.self)
        let sha = try #require(text.range(of: #"[0-9a-f]{64}"#, options: .regularExpression))
        response.body = Data(text.replacingCharacters(in: sha, with: String(repeating: "a", count: 64)).utf8)
        let store = installer(directory, ["https://store.test/v1/gizlets/github.com/dev/broken/install": response])
        await #expect(throws: DownloadError.checksumMismatch) {
            try await store.install(repo: "github.com/dev/broken", isRunning: { _ in false }, progress: { _, _ in })
        }
        #expect(store.library.list().isEmpty)
    }

    @Test func resumesAPartialDownload() async throws {
        let directory = try temporaryDirectory()
        let body = Data((0..<300_000).map { UInt8($0 % 251) })
        let session = StubProtocol.session(["https://dl.test/big": .init(status: 200, body: body)])
        let destination = directory.appendingPathComponent("big")
        try body.prefix(100_000).write(to: destination.appendingPathExtension("part"))
        StubProtocol.requests.removeAll()
        try await Downloader(session: session).download(URL(string: "https://dl.test/big")!, to: destination, size: UInt64(body.count), sha256: sha256(of: body))
        #expect(try Data(contentsOf: destination) == body)
        #expect(StubProtocol.requests.last { $0.url?.absoluteString == "https://dl.test/big" }?.value(forHTTPHeaderField: "Range") == "bytes=100000-")
    }

    @Test func asksForUpdatesOfStoreAppsOnly() async throws {
        let directory = try temporaryDirectory()
        let store = installer(directory, [
            "https://store.test/v1/gizlets/github.com/dev/hello/install": offer(repo: "github.com/dev/hello", repositoryID: 7, package: makePackage()),
            "https://store.test/v1/updates": .init(status: 200, body: Data(#"{"gizlets": [{"repo": "github.com/dev/hello", "repository_id": 7, "id": "dev.example.hello", "installed": "1.0.0", "status": "current"}]}"#.utf8)),
        ])
        #expect(try await store.updates().isEmpty)
        try await store.install(repo: "github.com/dev/hello", isRunning: { _ in false }, progress: { _, _ in })
        let updates = try await store.updates()
        #expect(updates.map(\.status) == ["current"])
        let request = try #require(StubProtocol.requests.last { $0.url?.path == "/v1/updates" })
        let body = try JSONSerialization.jsonObject(with: request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        } ?? request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["target"] as? String == hostTarget)
    }

    @Test func asksForUpdatesInBatchesOf200() async throws {
        // Answers each app in the request as current, whatever the batch.
        final class Echo: URLProtocol {
            nonisolated(unsafe) static var batches: [Int] = []
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                var body = Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
                    stream.close()
                }
                let sent = (try? JSONSerialization.jsonObject(with: request.httpBody ?? body) as? [String: Any])?["installed"] as? [[String: Any]] ?? []
                Echo.batches.append(sent.count)
                let answers = sent.map { #"{"repo": "\#($0["repo"] as! String)", "id": "\#($0["id"] as! String)", "installed": "1.0.0", "status": "current"}"# }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"gizlets": [\#(answers.joined(separator: ","))]}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Echo.self]
        let client = StoreClient(api: api, platform: Platform(targets: ["aarch64-apple-darwin"]), session: URLSession(configuration: configuration))
        let installed = (0..<450).map { StoreClient.InstalledItem(repo: "github.com/dev/app\($0)", repositoryID: UInt64($0), id: "dev.example.app\($0)", version: "1.0.0") }
        let statuses = try await client.updates(installed)
        #expect(Echo.batches == [200, 200, 50])
        #expect(Set(statuses.map(\.appID)).count == 450)
    }

    @Test func reportsStoreErrors() async throws {
        let session = StubProtocol.session([
            "https://store.test/v1/gizlets/github.com/dev/linux/install": .init(status: 404, body: Data(#"{"error": {"code": "no_compatible_package", "message": "No package for this Mac"}}"#.utf8)),
        ])
        let client = StoreClient(api: api, platform: Platform(targets: ["aarch64-apple-darwin"]), session: session)
        await #expect(throws: StoreAPIError(status: 404, code: "no_compatible_package", message: "No package for this Mac")) {
            try await client.offer("github.com/dev/linux")
        }
        await #expect(throws: StoreAPIError.self) { try await client.detail("github.com/../etc") }
    }

    @Test func decodesTheLiveDetailShape() throws {
        let json = #"{"repo":"github.com/gizlet/little-prince","id":"io.gizlet.littleprince","name":"The Little Prince","names":{"zh-CN":"小王子"},"kind":"app","category":"game","targets":["aarch64-unknown-linux-gnu","aarch64-apple-darwin"],"tiers":["lite"],"screenshots":["https://dl.gizlet.io/a.png"],"controls":[{"button":"a","action":"Jump","actions":{"zh-CN":"跳跃"}}],"packages":[{"file":"a.gzl","target":"aarch64-apple-darwin","tier":"lite","size":1,"sha256":null,"url":null}],"about_urls":{"en":"https://dl.gizlet.io/about.md"}}"#
        let detail = try JSONDecoder().decode(StoreDetail.self, from: Data(json.utf8))
        #expect(detail.summary.name(for: "zh-CN") == "小王子")
        #expect(detail.summary.runs(on: Platform(targets: ["aarch64-apple-darwin"])))
        #expect(!detail.summary.runs(on: Platform(targets: ["x86_64-apple-darwin"])))
        #expect(detail.package(for: Platform(targets: ["aarch64-apple-darwin"]))?.file == "a.gzl")
        #expect(detail.controls.first?.action(for: "zh-CN") == "跳跃")
    }
}
