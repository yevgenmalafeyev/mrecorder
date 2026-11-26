import Foundation

/// Locates and runs local command-line tools (claude, mlx_whisper, ffmpeg).
/// A menu-bar app does not inherit the shell PATH, so common install locations are searched explicitly.
enum Tools {
    static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The legacy Claude Code location comes last, so it can't shadow a regular install.
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "\(home)/.claude/local"]
    }()

    /// The tool's real file (symlinks resolved), shown in Configuration so the user can see what runs.
    static func find(_ name: String) -> URL? {
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path).resolvingSymlinksInPath()
            }
        }
        return nil
    }

    /// Only what the tools need; the rest of this app's environment is not passed on.
    private static var environment: [String: String] {
        let mine = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "__CF_USER_TEXT_ENCODING"] { env[key] = mine[key] }
        env["HOME"] = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = (searchPaths + ["/usr/sbin", "/sbin"]).joined(separator: ":")
        return env
    }

    static var claude: URL? { find("claude") }
    static var whisper: URL? { find("mlx_whisper") }
    static var ffmpeg: URL? { find("ffmpeg") }

    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    /// Runs a tool and waits for it. Output is collected while running so large outputs don't block.
    static func run(_ tool: URL, _ args: [String], stdin: String? = nil, cwd: URL? = nil,
                    timeout: TimeInterval = 3600) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                do {
                    cont.resume(returning: try spawn(tool, args, stdin: stdin, cwd: cwd, timeout: timeout))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Makes the spawned program responsible for itself in the eyes of macOS privacy protection (TCC).
    /// Without it a child counts as part of this app and silently gets its Screen Recording, Microphone and
    /// Camera permissions, so a fake `ffmpeg` planted in a user-writable folder could record the screen.
    /// (System function without a public header; also used by browsers and Xcode for the same purpose.)
    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let disclaim: Disclaim? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        else { return nil }
        return unsafeBitCast(sym, to: Disclaim.self)
    }()

    private static func spawn(_ tool: URL, _ args: [String], stdin: String?, cwd: URL?,
                              timeout: TimeInterval) throws -> Result {
        let name = tool.lastPathComponent
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // The child gets only the three pipes below, no other open files of this app.
        // It also starts with default signal handling: the worker thread spawning it blocks signals, and a
        // child that inherited that could not be stopped by the timeout.
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        // Its own process group, so the timeout also stops helpers the tool started.
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
                                              | POSIX_SPAWN_SETPGROUP))
        // Never run a tool with this app's permissions: if they can't be dropped, don't run it.
        guard let disclaim, disclaim(&attr, 1) == 0 else {
            throw ToolError.failed(name, "could not start it without this app's permissions")
        }

        let out = Pipe(), err = Pipe(), inp = Pipe()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if stdin != nil {
            posix_spawn_file_actions_adddup2(&actions, inp.fileHandleForReading.fileDescriptor, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, err.fileHandleForWriting.fileDescriptor, 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd.path) }

        var argv: [UnsafeMutablePointer<CChar>?] = ([tool.path] + args).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, tool.path, &actions, &attr, &argv, &envp)
        guard rc == 0 else { throw ToolError.failed(name, "could not start: " + String(cString: strerror(rc))) }

        // Close this app's copies of the child's ends, so reads finish when the child exits.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        try? inp.fileHandleForReading.close()

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        if let stdin {
            // A tool that exits early closes the pipe; that must not raise (SIGPIPE is ignored at launch).
            try? inp.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        }
        try? inp.fileHandleForWriting.close()

        // On timeout: ask the tool's process group to stop, then force it. The lock and `exited` make sure
        // nothing is signalled after the child was collected (its id could then belong to another program).
        let lock = NSLock()
        var exited = false
        let timer = DispatchWorkItem {
            lock.lock(); defer { lock.unlock() }
            guard !exited else { return }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                lock.lock(); defer { lock.unlock() }
                if !exited { kill(-pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Wait without collecting, mark it exited, and only then collect.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        lock.lock(); exited = true; lock.unlock()
        timer.cancel()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}

        // A helper that outlived the tool can keep the pipes open: stop what is left of the group.
        if group.wait(timeout: .now() + 5) == .timedOut {
            kill(-pid, SIGKILL)
            if group.wait(timeout: .now() + 5) == .timedOut {
                throw ToolError.failed(name, "its output could not be read")
            }
        }

        let signal = status & 0x7f
        return Result(
            status: signal == 0 ? (status >> 8) & 0xff : -signal,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
