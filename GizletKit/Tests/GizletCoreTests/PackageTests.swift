import Foundation
@testable import GizletCore
import Testing

@Suite struct ManifestTests {
    @Test func readsSchemaOneAndTwoApps() throws {
        let one = try Manifest.parse(Data(manifestJSON().utf8))
        #expect(one.kind == .app)
        let two = try Manifest.parse(Data(manifestJSON(extra: #", "kind": "app", "schema": 2"#).replacingOccurrences(of: #""schema": 1, "#, with: "").utf8))
        #expect(two.kind == .app)
    }

    @Test func refusesBadManifests() {
        let bad = [
            #"[1]"#,
            #"{"schema": 3, "id": "a.b", "name": "x", "version": "1", "target": "a-b-c", "tier": "lite", "entry": "x"}"#,
            #"{"schema": 2, "id": "a.b", "name": "x", "version": "1", "target": "a-b-c", "tier": "lite", "entry": "x"}"#,
            #"{"schema": 1, "kind": "service", "id": "a.b", "name": "x", "version": "1", "target": "a-b-c", "tier": "lite", "entry": "x"}"#,
            manifestJSON(id: "Hello.World"),
            manifestJSON(id: "hello"),
            manifestJSON(tier: "max"),
            manifestJSON(target: "darwin"),
            manifestJSON(entry: "../escape"),
            manifestJSON(entry: "/bin/sh"),
            manifestJSON(extra: #", "runtime": 2"#),
            manifestJSON(name: " "),
        ]
        for text in bad {
            #expect(throws: PackageError.self, "\(text)") { try Manifest.parse(Data(text.utf8)) }
        }
    }

    @Test func localizesNamesByPrimarySubtag() throws {
        let manifest = try Manifest.parse(Data(manifestJSON(extra: #", "names": {"zh-CN": "你好"}"#).utf8))
        #expect(manifest.name(for: "zh-CN") == "你好")
        #expect(manifest.name(for: "zh-Hans") == "你好")
        #expect(manifest.name(for: "en") == "Hello")
    }

    @Test func checksIDsAndPaths() {
        #expect(isValidAppID("io.gizlet.rocket-snail"))
        #expect(!isValidAppID("io..gizlet"))
        #expect(!isValidAppID("io.Gizlet"))
        #expect(relativePathProblem("bin/a") == nil)
        for bad in ["", "/a", "a//b", "a/./b", "a/../b", "a\\b", "C:/a"] {
            #expect(relativePathProblem(bad) != nil, "\(bad)")
        }
    }
}

@Suite struct LibraryTests {
    @Test func installsListsAndRunsAPackage() throws {
        let directory = try temporaryDirectory()
        let library = AppLibrary(root: DataRoot(url: directory.appendingPathComponent("data")))
        let installed = try library.install(write(makePackage(), to: directory))
        #expect(installed.id == "dev.example.hello")
        #expect(library.list().map(\.id) == ["dev.example.hello"])
        let mode = try FileManager.default.attributesOfItem(atPath: installed.entry.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        let output = try runTool(installed.entry.path, [])
        #expect(String(decoding: output, as: UTF8.self) == "hello \n")
    }

    @Test func acceptsAMachOEntryForThisMac() throws {
        let directory = try temporaryDirectory()
        let library = AppLibrary(root: DataRoot(url: directory))
        let binary = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        _ = try library.install(write(makePackage(files: [ZipFile(name: "bin/hello", data: binary, mode: 0o100755)]), to: directory))
        #expect(library.app("dev.example.hello") != nil)
    }

    @Test func refusesPackagesThisMacCannotRun() throws {
        let directory = try temporaryDirectory()
        let library = AppLibrary(root: DataRoot(url: directory.appendingPathComponent("data")))
        let elf = Data([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0] + [UInt8](repeating: 0, count: 56))
        let cases: [(Data, String)] = [
            (makePackage(manifest: manifestJSON(target: "aarch64-unknown-linux-gnu")), "built for"),
            (makePackage(manifest: manifestJSON(extra: #", "kind": "service", "schema": 2"#).replacingOccurrences(of: #""schema": 1, "#, with: "")), "service"),
            (makePackage(files: [ZipFile(name: "bin/hello", data: elf, mode: 0o100755)]), "not a macOS executable"),
        ]
        for (package, message) in cases {
            let error = #expect(throws: PackageError.self) { try library.install(write(package, to: directory)) }
            #expect(error?.localizedDescription.contains(message) == true, "\(String(describing: error))")
        }
        #expect(library.list().isEmpty)
    }

    @Test func refusesUnsafeOrDamagedPackages() throws {
        let directory = try temporaryDirectory()
        let library = AppLibrary(root: DataRoot(url: directory.appendingPathComponent("data")))
        let hello = ZipFile(name: "bin/hello", data: helloScript, mode: 0o100755)
        let cases: [(Data, String)] = [
            (makePackage(files: [hello, ZipFile(name: "../evil", data: Data("x".utf8))]), "evil"),
            (makePackage(files: [hello, ZipFile(name: "link", data: Data("bin/hello".utf8), mode: 0o120777)]), "link"),
            (makePackage(files: [hello, ZipFile(name: "BIN/HELLO", data: Data("x".utf8))]), "twice"),
            (makePackage(files: [hello, ZipFile(name: "setuid", data: Data("x".utf8), mode: 0o104755)]), "setuid"),
            (makePackage(files: [hello, ZipFile(name: "Cafe\u{301}", data: Data("x".utf8)), ZipFile(name: "Caf\u{e9}", data: Data("y".utf8))]), "twice"),
            (makePackage(files: [hello, ZipFile(name: "bin/hello/x", data: Data("x".utf8))]), "both a file and a folder"),
            (makePackage(checksums: "\(String(repeating: "0", count: 64))  bin/hello\n"), "checksum"),
            (makePackage(checksums: ""), "not listed"),
            (makeZip([ZipFile(name: "manifest.json", data: Data(manifestJSON().utf8))]), "CHECKSUMS"),
            (makeZip([ZipFile(name: "manifest.json", data: Data(manifestJSON().utf8))], unicodeExtra: true), "renamed"),
            (Data("not a zip".utf8), "zip"),
        ]
        for (package, message) in cases {
            let error = #expect(throws: PackageError.self) { try library.install(write(package, to: directory)) }
            #expect(error?.localizedDescription.contains(message) == true, "expected \(message): \(String(describing: error))")
        }
        #expect(library.list().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.root.apps.path).isEmpty)
    }

    @Test func updatesInPlaceAndUninstallKeepsEveryProfilesSaves() throws {
        let directory = try temporaryDirectory()
        let root = DataRoot(url: directory.appendingPathComponent("data"))
        let library = AppLibrary(root: root)
        let profiles = Profiles(root: root)
        let first = try profiles.current()
        let second = try profiles.create(name: "Second")
        try library.install(write(makePackage(), to: directory))
        for profile in [first, second] {
            let saves = ProfileStore(directory: profiles.directory(profile.id)).saveDirectory(for: "dev.example.hello")
            try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
            try Data(profile.id.utf8).write(to: saves.appendingPathComponent("save.dat"))
        }
        #expect(throws: PackageError.running("dev.example.hello")) {
            try library.install(write(makePackage(manifest: manifestJSON(version: "2.0.0")), to: directory), isRunning: { _ in true })
        }
        let updated = try library.install(write(makePackage(manifest: manifestJSON(version: "2.0.0")), to: directory))
        #expect(updated.manifest.version == "2.0.0")
        try library.uninstall("dev.example.hello")
        #expect(library.app("dev.example.hello") == nil)
        for profile in [first, second] {
            let save = ProfileStore(directory: profiles.directory(profile.id)).saveDirectory(for: "dev.example.hello").appendingPathComponent("save.dat")
            #expect(try Data(contentsOf: save) == Data(profile.id.utf8))
        }
    }

    @Test func refusesAPackageNamingAnotherApp() throws {
        let directory = try temporaryDirectory()
        let library = AppLibrary(root: DataRoot(url: directory.appendingPathComponent("data")))
        #expect(throws: PackageError.self) { try library.install(write(makePackage(), to: directory), expectedID: "dev.example.other") }
    }

    @Test func readsUniversalBinaries() throws {
        let format = ExecutableFormat.of(URL(fileURLWithPath: "/usr/bin/true"))
        guard case .machO(let types) = format else { Issue.record("not Mach-O: \(format)"); return }
        #expect(types.contains(Platform.cpuType(of: hostTarget)!))
    }
}
