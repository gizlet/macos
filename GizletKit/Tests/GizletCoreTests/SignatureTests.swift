import Foundation
@testable import GizletCore
import Testing

@Suite struct SignatureTests {
    @Test func verifiesTheGizletOSReleaseManifest() throws {
        let manifest = try fixture("os-v0.4.4-manifest.json")
        let signature = String(decoding: try fixture("os-v0.4.4-manifest.json.sig"), as: UTF8.self)
        let verifier = try SSHSignatureVerifier(key: TrustedKeys.osRelease, namespace: TrustedKeys.osReleaseNamespace)
        try verifier.verify(manifest, armored: signature)
        var tampered = manifest
        tampered[tampered.startIndex + 30] ^= 1
        #expect(throws: SignatureError.invalid) { try verifier.verify(tampered, armored: signature) }
        let otherNamespace = try SSHSignatureVerifier(key: TrustedKeys.osRelease, namespace: TrustedKeys.launcherUpdateNamespace)
        #expect(throws: SignatureError.wrongNamespace) { try otherNamespace.verify(manifest, armored: signature) }
        let otherKey = try SSHSignatureVerifier(key: TrustedKeys.launcherUpdate, namespace: TrustedKeys.osReleaseNamespace)
        #expect(throws: SignatureError.untrustedSigner) { try otherKey.verify(manifest, armored: signature) }
    }

    @Test func readsTheOSReleaseImage() throws {
        let feed = try OSReleaseFeed()
        let release = try feed.parse(manifest: try fixture("os-v0.4.4-manifest.json"),
                                     signature: String(decoding: try fixture("os-v0.4.4-manifest.json.sig"), as: UTF8.self),
                                     base: URL(string: "https://dl.gizlet.io/releases/v0.4.4/")!)
        #expect(release.tag == "v0.4.4")
        #expect(release.image.absoluteString == "https://dl.gizlet.io/releases/v0.4.4/boards/gameconsole/r36s/gizlet-os-r36s.img.gz")
        #expect(release.checksums.lastPathComponent == "SHA256SUMS")
        #expect(throws: FlashError.self) {
            try feed.parse(manifest: try fixture("os-v0.4.4-manifest.json"),
                           signature: String(decoding: try fixture("os-v0.4.4-manifest.json.sig"), as: UTF8.self),
                           base: URL(string: "https://dl.gizlet.io/releases/v0.4.3/")!)
        }
    }

    @Test func readsChecksumFiles() {
        let sum = String(repeating: "ab", count: 32)
        #expect(checksum(in: "\(sum)  gizlet-os-r36s.img.gz\n", for: "gizlet-os-r36s.img.gz") == sum)
        #expect(checksum(in: "\(sum) *gizlet-os-r36s.img.gz\n", for: "gizlet-os-r36s.img.gz") == sum)
        #expect(checksum(in: "\(sum)  other.img.gz\n", for: "gizlet-os-r36s.img.gz") == nil)
    }

    @Test func discoversTheLatestReleaseThroughTheAPI() async throws {
        let manifest = try fixture("os-v0.4.4-manifest.json")
        let signature = try fixture("os-v0.4.4-manifest.json.sig")
        let api = "https://os.test/api/v1/os/releases/latest"
        let assets = "https://os.test/assets/releases/v0.4.4/manifest.json"
        let session = StubProtocol.session([
            assets: .init(status: 200, body: manifest),
            assets + ".sig": .init(status: 200, body: signature),
            api: .init(status: 200, body: Data(#"{"tag": "v0.4.4", "manifest_url": "\#(assets)", "signature_url": "\#(assets).sig"}"#.utf8)),
        ])
        let feed = try OSReleaseFeed(latestURL: URL(string: api)!, session: session)
        let release = try await feed.latest()
        #expect(release.image.absoluteString == "https://os.test/assets/releases/v0.4.4/boards/gameconsole/r36s/gizlet-os-r36s.img.gz")

        let elsewhere = "https://evil.test/assets/releases/v0.4.4/manifest.json"
        StubProtocol.responses[api] = .init(status: 200, body: Data(#"{"tag": "v0.4.4", "manifest_url": "\#(elsewhere)", "signature_url": "\#(elsewhere).sig"}"#.utf8))
        await #expect(throws: FlashError.self) { try await feed.latest() }
    }

    @Test func readsSignedUpdateManifests() throws {
        let manifest = """
            {"schema": 1, "version": "0.2.0", "tag": "v0.2.0", "minimum_macos": "14.0", "notes": {"en": "Faster", "zh-CN": "更快"},
             "archive": {"path": "Gizlet-0.2.0.zip", "sha256": "\(String(repeating: "1", count: 64))", "bytes": 10},
             "dmg": {"path": "Gizlet-0.2.0.dmg", "sha256": "\(String(repeating: "2", count: 64))", "bytes": 20}}
            """
        let (key, signature) = try sshSign(Data(manifest.utf8), namespace: TrustedKeys.launcherUpdateNamespace)
        let feed = try UpdateFeed(key: key)
        let envelope = try JSONEncoder().encode(UpdateEnvelope(schema: 1, manifest: manifest, signature: signature))
        let release = try feed.parse(envelope)
        #expect(release.version == "0.2.0")
        #expect(release.notes(for: "zh-CN") == "更快")
        #expect(feed.url(of: release.archive, in: release).absoluteString == "https://gizlet.io/assets/macos/releases/v0.2.0/Gizlet-0.2.0.zip")
        #expect(try compare(release, running: "0.1.0") == .available(release))
        #expect(try compare(release, running: "0.2.0") == .upToDate(release))
        #expect(try compare(release, running: "0.3.0") == .upToDate(release))
        #expect(throws: UpdateError.incompatible("14.0")) {
            try compare(release, running: "0.1.0", os: OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0))
        }

        let forged = try JSONEncoder().encode(UpdateEnvelope(schema: 1, manifest: manifest.replacingOccurrences(of: "0.2.0", with: "0.2.1"), signature: signature))
        #expect(throws: UpdateError.self) { try feed.parse(forged) }
        #expect(throws: UpdateError.self) { try UpdateFeed().parse(envelope) }
    }

    @Test func comparesVersions() {
        #expect(ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.9")!)
        #expect(ReleaseVersion("v0.1.0")?.tag == "v0.1.0")
        for bad in ["1.0", "1.0.0.0", "01.0.0", "1.a.0", "", "1.0.0-beta"] {
            #expect(ReleaseVersion(bad) == nil, "\(bad)")
        }
    }

    /// latest.json as devops/release.py writes it, signed with the production update key.
    @Test func readsAManifestTheReleaseToolSigned() throws {
        let release = try UpdateFeed().parse(try fixture("launcher-latest-v0.9.0.json"))
        #expect(release.version == "0.9.0")
        #expect(release.minimumMacOS == "14.0")
        #expect(release.archive.path == "Gizlet-0.9.0.zip")
        #expect(release.notes(for: "zh-CN") == "Fixture release.")
    }
}

@Suite struct UpdateInstallerTests {
    @Test func refusesAnAppThatIsNotGizletsRelease() throws {
        let directory = try temporaryDirectory()
        let app = directory.appendingPathComponent("Gizlet.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let release = LauncherRelease(schema: 1, version: "0.2.0", tag: "v0.2.0", commit: nil, minimumMacOS: "14.0", publishedAt: nil, notes: [:],
                                      archive: ReleaseFile(path: "a.zip", sha256: String(repeating: "1", count: 64), bytes: 1),
                                      dmg: ReleaseFile(path: "a.dmg", sha256: String(repeating: "2", count: 64), bytes: 1))
        let installer = UpdateInstaller(feed: try UpdateFeed(), workDirectory: directory)
        try (["CFBundleIdentifier": "io.gizlet.macos", "CFBundleShortVersionString": "0.1.9"] as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        #expect(throws: UpdateError.verification("the app is not Gizlet 0.2.0")) { try installer.verify(directory.appendingPathComponent("Gizlet.app"), release: release) }
        try (["CFBundleIdentifier": "io.gizlet.macos", "CFBundleShortVersionString": "0.2.0"] as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        #expect(throws: UpdateError.self) { try installer.verify(directory.appendingPathComponent("Gizlet.app"), release: release) }
    }

    @Test func knowsWhereTheAppCannotBeReplaced() {
        #expect(UpdateInstaller.replaceableLocation(of: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1/d/Gizlet.app")) != nil)
        #expect(UpdateInstaller.replaceableLocation(of: URL(fileURLWithPath: "/Volumes/Gizlet/Gizlet.app")) != nil)
        #expect(UpdateInstaller.replaceableLocation(of: URL(fileURLWithPath: "/System/Applications/Calculator.app")) != nil)
    }
}
