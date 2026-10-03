import Darwin
import Foundation

public final class ManagedProcess {
    public let pid: pid_t
    public let logURL: URL
    private var logTimer: DispatchSourceTimer?

    public init(command: String, directory: String, logURL: URL, onExit: @escaping (pid_t, Int32) -> Void) throws {
        self.logURL = logURL
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LogRotation.rotateIfNeeded(at: logURL)

        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw ConfigError("could not initialize process launcher")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, directory) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logURL.path, O_WRONLY | O_CREAT | O_APPEND, mode_t(S_IRUSR | S_IWUSR)) == 0,
              posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO) == 0 else {
            throw ConfigError("could not configure process launcher")
        }

        let argumentStrings = ["/bin/zsh", "-lic", "exec \(command)"]
        var arguments = argumentStrings.map { strdup($0) }
        arguments.append(nil)
        defer { arguments.compactMap { $0 }.forEach { free($0) } }
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        environment.append(nil)
        defer { environment.compactMap { $0 }.forEach { free($0) } }

        var child: pid_t = 0
        let errorCode = arguments.withUnsafeMutableBufferPointer { buffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(&child, "/bin/zsh", &actions, &attributes, buffer.baseAddress, environmentBuffer.baseAddress)
            }
        }
        guard errorCode == 0 else { throw ConfigError("could not start command: \(String(cString: strerror(errorCode)))") }
        pid = child
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SuperUp.log.\(child)", qos: .utility))
        logTimer = timer
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                try LogRotation.rotateIfNeeded(at: self.logURL)
            } catch {
                NSLog("SuperUp log rotation failed: %@", error.localizedDescription)
                self.logTimer?.cancel()
            }
        }
        timer.resume()
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            _ = waitpid(child, &status, 0)
            // A command wrapper may have left children in its group.
            _ = kill(-child, SIGTERM)
            timer.cancel()
            onExit(child, status)
        }
    }

    deinit { logTimer?.cancel() }

    public func terminate() {
        _ = kill(-pid, SIGTERM)
        let group = pid
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if kill(-group, 0) == 0 { _ = kill(-group, SIGKILL) }
        }
    }

    public func terminateAndWait() {
        _ = kill(-pid, SIGTERM)
        for _ in 0..<50 {
            if kill(-pid, 0) != 0 { return }
            usleep(100_000)
        }
        _ = kill(-pid, SIGKILL)
    }
}
