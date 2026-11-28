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
        var pid: Int32 = 0
        try apps.launch("dev.example.a", profile: "0123456789abcdef") {
            pid = try ProcessGroup.spawn(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:], directory: URL(fileURLWithPath: "/"))
            return pid
        }
        defer { kill(-pid, SIGKILL) }
        #expect(apps.isRunning("dev.example.a"))
        #expect(throws: RunningApps.Refusal.running("dev.example.a")) { try apps.launch("dev.example.a", profile: "x") { 0 } }
        #expect(throws: RunningApps.Refusal.running("dev.example.a")) { try apps.reserve("dev.example.a") }

        // The Launcher opens again: the app is still known, with its profile.
        let reopened = RunningApps(root: root)
        #expect(reopened.running.map(\.id) == ["dev.example.a"])
        #expect(reopened.running.first?.profile == "0123456789abcdef")

        reopened.stop("dev.example.a", grace: 1)
        for _ in 0..<40 where reopened.isRunning("dev.example.a") { Thread.sleep(forTimeInterval: 0.1) }
        #expect(!reopened.isRunning("dev.example.a"))
        #expect(RunningApps(root: root).running.isEmpty)
    }

    @Test func tracksAndStopsWhatAScriptEntryStarts() throws {
        let directory = try temporaryDirectory()
        let apps = RunningApps(root: DataRoot(url: directory))
        let marker = directory.appendingPathComponent("child.pid")
        let script = directory.appendingPathComponent("entry")
        // A script entry that starts its game in the background and exits at once.
        try Data("#!/bin/sh\nsleep 60 &\necho $! > \"$1\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try apps.launch("dev.example.script", profile: "x") {
            try ProcessGroup.spawn(script, arguments: [marker.path], environment: ["PATH": "/usr/bin:/bin"], directory: directory)
        }
        var child: Int32 = 0
        for _ in 0..<50 where child == 0 {
            Thread.sleep(forTimeInterval: 0.1)
            child = Int32((try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        }
        #expect(child > 0)
        Thread.sleep(forTimeInterval: 0.3)
        // The entry has exited; its game keeps the app running.
        #expect(apps.isRunning("dev.example.script"))
        #expect(throws: RunningApps.Refusal.running("dev.example.script")) { try apps.reserve("dev.example.script") }
        apps.stop("dev.example.script", grace: 1)
        for _ in 0..<40 where apps.isRunning("dev.example.script") { Thread.sleep(forTimeInterval: 0.1) }
        #expect(!apps.isRunning("dev.example.script"))
        #expect(kill(child, 0) != 0)
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
