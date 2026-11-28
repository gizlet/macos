import Darwin
import Foundation

/// Starts an app in a process group of its own, whose ID is its first
/// process's, so quitting it ends everything it started (a script entry's
/// game included) and the app counts as running while any of them does.
public enum ProcessGroup {
    public static func spawn(_ executable: URL, arguments: [String] = [], environment: [String: String], directory: URL) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw PackageError.io("cannot start \(executable.lastPathComponent): \(String(cString: strerror(status)))")
        }
        // Reap the first process when it exits, so it never lingers as a zombie.
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler {
            var code: Int32 = 0
            waitpid(pid, &code, 0)
            source.cancel()
        }
        source.resume()
        var code: Int32 = 0
        if waitpid(pid, &code, WNOHANG) == pid { source.cancel() }
        return pid
    }
}
