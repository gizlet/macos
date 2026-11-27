import Foundation
@testable import GizletCore
import Testing

@Suite struct RunningAppsTests {
    func sleeper(_ seconds: Int) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [String(seconds)]
        return process
    }

    @Test func tracksAppsAcrossLauncherRuns() throws {
        let root = DataRoot(url: try temporaryDirectory())
        let apps = RunningApps(root: root)
        let process = try sleeper(30)
        try apps.launch("dev.example.a", profile: "0123456789abcdef") {
            try process.run()
            return process.processIdentifier
        }
        defer { process.terminate() }
        #expect(apps.isRunning("dev.example.a"))
        #expect(throws: RunningApps.Refusal.running("dev.example.a")) { try apps.launch("dev.example.a", profile: "x") { 0 } }
        #expect(throws: RunningApps.Refusal.running("dev.example.a")) { try apps.reserve("dev.example.a") }

        // The Launcher opens again: the app is still known, with its profile.
        let reopened = RunningApps(root: root)
        #expect(reopened.running.map(\.id) == ["dev.example.a"])
        #expect(reopened.running.first?.profile == "0123456789abcdef")

        reopened.stop("dev.example.a", grace: 1)
        process.waitUntilExit()
        #expect(!reopened.isRunning("dev.example.a"))
        #expect(RunningApps(root: root).running.isEmpty)
    }

    @Test func refusesToLaunchAnAppBeingReplaced() throws {
        let apps = RunningApps(root: DataRoot(url: try temporaryDirectory()))
        try apps.reserve("dev.example.b")
        #expect(throws: RunningApps.Refusal.busy("dev.example.b")) { try apps.reserve("dev.example.b") }
        var started = false
        #expect(throws: RunningApps.Refusal.busy("dev.example.b")) {
            try apps.launch("dev.example.b", profile: "x") { started = true; return 0 }
        }
        #expect(!started)
        apps.release("dev.example.b")
        try apps.reserve("dev.example.b")
    }

    @Test func dropsRecordsOfOtherProcesses() throws {
        let root = DataRoot(url: try temporaryDirectory())
        // This test's own process, but with another start time: a reused process ID.
        let reused = RunningApps.Record(id: "dev.example.c", pid: ProcessInfo.processInfo.processIdentifier, started: 1, profile: "x")
        let gone = RunningApps.Record(id: "dev.example.d", pid: 99_999_999, started: 1, profile: "x")
        try writeAtomically(JSONEncoder().encode([reused, gone]), to: root.device.appendingPathComponent("running.json"))
        #expect(RunningApps(root: root).running.isEmpty)
    }
}
