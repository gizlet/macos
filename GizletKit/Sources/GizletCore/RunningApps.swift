import Darwin
import Foundation

/// The apps running from a data folder, kept in `device/running.json` so a
/// Launcher that quits and opens again (after an update, say) still knows
/// them. A record names the process by its ID and start time, so a reused
/// process ID is never taken for the app.
///
/// An app is also *reserved* while an update or uninstall replaces its files:
/// it cannot be launched then, and it cannot be reserved while it runs.
/// Every check and change happens under one lock, so the answer holds until
/// the caller is done.
public final class RunningApps: @unchecked Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var id: String
        public var pid: Int32
        /// When the process started, in microseconds since 1970.
        public var started: UInt64
        public var profile: String
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        case running(String)
        case busy(String)

        public var errorDescription: String? {
            switch self {
            case .running(let id): "\(id) is running; quit it first"
            case .busy(let id): "\(id) is being updated; try again when it is done"
            }
        }
    }

    let file: URL
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var reserved = Set<String>()

    public init(root: DataRoot) {
        file = root.device.appendingPathComponent("running.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Record].self, from: data) {
            for record in saved where Self.isAlive(record) { records[record.id] = record }
        }
        persist()
    }

    /// The apps running now; records of processes that ended are dropped.
    public var running: [Record] {
        lock.lock()
        defer { lock.unlock() }
        prune()
        return records.values.sorted { $0.id < $1.id }
    }

    public func isRunning(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        prune()
        return records[id] != nil
    }

    public func isReserved(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reserved.contains(id)
    }

    /// Starts `id` with `start`, which runs the process and returns its ID, unless
    /// it runs already or is reserved. The record is written before this returns.
    public func launch(_ id: String, profile: String, start: () throws -> Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        prune()
        if records[id] != nil { throw Refusal.running(id) }
        if reserved.contains(id) { throw Refusal.busy(id) }
        let pid = try start()
        records[id] = Record(id: id, pid: pid, started: Self.startTime(of: pid) ?? 0, profile: profile)
        persist()
    }

    /// Forgets `id` once process `pid` has ended.
    public func ended(_ id: String, pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if records[id]?.pid == pid {
            records.removeValue(forKey: id)
            persist()
        }
    }

    /// Keeps `id` from launching while its files are replaced; fails while it runs.
    public func reserve(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        prune()
        if records[id] != nil { throw Refusal.running(id) }
        if !reserved.insert(id).inserted { throw Refusal.busy(id) }
    }

    public func release(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        reserved.remove(id)
    }

    /// Asks every process of a running app's group to quit, and ends them
    /// `grace` seconds later if they have not.
    public func stop(_ id: String, grace: TimeInterval = 3) {
        guard let record = running.first(where: { $0.id == id }) else { return }
        kill(-record.pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            if running.contains(record) { kill(-record.pid, SIGKILL) }
        }
    }

    /// Must hold the lock.
    private func prune() {
        let before = records.count
        records = records.filter { Self.isAlive($0.value) }
        if records.count != before { persist() }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? writeAtomically(encoder.encode(records.values.sorted { $0.id < $1.id }), to: file)
    }

    /// Whether the app's process group still has a process. While its first
    /// process lives, its start time tells it from a reused process ID; once it
    /// has ended, the group lives on in what it started. macOS never gives a new
    /// process the ID of a group that still exists, so the group is the app's.
    static func isAlive(_ record: Record) -> Bool {
        guard record.pid > 0 else { return false }
        if let started = startTime(of: record.pid) { return started == record.started }
        return kill(-record.pid, 0) == 0 || errno == EPERM
    }

    /// When process `pid` started, in microseconds since 1970; nil when there is none.
    static func startTime(of pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}
