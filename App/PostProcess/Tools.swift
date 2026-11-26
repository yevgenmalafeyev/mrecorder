import Foundation

/// Locates and runs local command-line tools (claude, mlx_whisper, ffmpeg).
/// A menu-bar app does not inherit the shell PATH, so common install locations are searched explicitly.
enum Tools {
    static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local", "/usr/bin", "/bin"]
    }()

    static func find(_ name: String) -> URL? {
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
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
                let p = Process()
                p.executableURL = tool
                p.arguments = args
                if let cwd { p.currentDirectoryURL = cwd }
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
                p.environment = env

                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = stdin == nil ? FileHandle.nullDevice : inp

                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter(); group.enter()
                DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

                do { try p.run() } catch { cont.resume(throwing: error); return }
                if let stdin {
                    inp.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inp.fileHandleForWriting.close()
                }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                p.waitUntilExit()
                timer.cancel()
                group.wait()
                cont.resume(returning: Result(
                    status: p.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
