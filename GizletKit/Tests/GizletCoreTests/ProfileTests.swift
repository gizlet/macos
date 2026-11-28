import Foundation
@testable import GizletCore
import Testing

@Suite struct ProfileTests {
    @Test func createsTheFirstProfileAndSwitches() throws {
        let profiles = Profiles(root: DataRoot(url: try temporaryDirectory()))
        let first = try profiles.current()
        #expect(first.label == "Default")
        #expect(Profiles.isValidID(first.id))
        let second = try profiles.create(name: "Ana")
        #expect(try profiles.current() == first)
        try profiles.switchTo(second.id)
        #expect(try profiles.current() == second)
        #expect(profiles.list().map(\.id) == [first.id, second.id] || profiles.list().map(\.id).sorted() == [first.id, second.id].sorted())
    }

    @Test func checksNames() throws {
        let profiles = Profiles(root: DataRoot(url: try temporaryDirectory()))
        _ = try profiles.current()
        for bad in ["", " ana", "ana ", String(repeating: "a", count: 25), "a\nb", "default"] {
            #expect(throws: ProfileError.self, "\(bad)") { try profiles.create(name: bad) }
        }
        let ana = try profiles.create(name: "Ana")
        #expect(throws: ProfileError.taken("ANA")) { try profiles.create(name: "ANA") }
        #expect(try profiles.rename(ana.id, to: "Ana B").name == "Ana B")
    }

    @Test func deletesOnlyAnotherProfile() throws {
        let profiles = Profiles(root: DataRoot(url: try temporaryDirectory()))
        let current = try profiles.current()
        let other = try profiles.create(name: "Other")
        #expect(throws: ProfileError.isCurrent) { try profiles.delete(current.id) }
        try FileManager.default.createDirectory(at: profiles.directory(other.id).appendingPathComponent("apps/x.y"), withIntermediateDirectories: true)
        try profiles.delete(other.id)
        #expect(!FileManager.default.fileExists(atPath: profiles.directory(other.id).path))
        #expect(profiles.list() == [current])
        #expect(throws: ProfileError.notFound("../x")) { try profiles.delete("../x") }
    }

    @Test func keepsSettingsAndFavoritesPerProfile() throws {
        let profiles = Profiles(root: DataRoot(url: try temporaryDirectory()))
        let first = ProfileStore(directory: profiles.directory(try profiles.current().id))
        let second = ProfileStore(directory: profiles.directory(try profiles.create(name: "Two").id))
        try first.save(ProfileSettings(language: .chinese, appearance: .dark, favorites: ["io.gizlet.a"]))
        try second.save(ProfileSettings(favorites: ["io.gizlet.b", "io.gizlet.c"]))
        #expect(first.loadSettings() == ProfileSettings(language: .chinese, appearance: .dark, favorites: ["io.gizlet.a"]))
        #expect(second.loadSettings().favorites == ["io.gizlet.b", "io.gizlet.c"])
        try first.markPlayed("io.gizlet.a", at: Date(timeIntervalSince1970: 100))
        #expect(first.recent() == ["io.gizlet.a": 100])
        #expect(second.recent().isEmpty)
    }

    @Test func readsAHandheldSettingsFile() {
        let settings = ProfileSettings.parse("language = zh-CN\ntheme = light\nswap_ab = true\nfavorite = io.gizlet.a\nfavorite = io.gizlet.a\nfavorite = BAD\n")
        #expect(settings == ProfileSettings(language: .chinese, appearance: .light, favorites: ["io.gizlet.a"]))
    }
}
