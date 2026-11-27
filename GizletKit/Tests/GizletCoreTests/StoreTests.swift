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
        #expect(StubProtocol.requests.last?.value(forHTTPHeaderField: "Range") == "bytes=100000-")
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
