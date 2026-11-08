import AppKit
import T3MiniCore

/// Everything T3 Mini does *to* T3 Code goes through public surfaces:
/// the registered t3code:// URL scheme, app activation, and the official `t3 thread` CLI.
enum T3Actions {
    static let env = T3Environment()

    static var t3AppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: T3Environment.bundleIdentifier)
    }

    /// Bring T3 Code forward without changing its current thread.
    /// Uses LaunchServices (like `open -a`): macOS 14+ ignores NSRunningApplication.activate()
    /// from an app that isn't active itself, and T3 Mini never takes activation.
    static func activateT3() {
        trace("activateT3")
        if let url = t3AppURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            NSRunningApplication.runningApplications(withBundleIdentifier: T3Environment.bundleIdentifier).first?
                .activate(options: [.activateAllWindows])
        }
    }

    static func trace(_ s: String) {
        guard UserDefaults.standard.bool(forKey: "traceEvents") else { return }
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/T3Mini/trace.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    }

    /// Open a specific thread in T3 Code.
    static func openThread(_ threadId: String) {
        guard let url = env.threadURL(threadId) else { return activateT3() }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let app = t3AppURL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    struct CLIResult { let ok: Bool; let output: String }

    /// Run `t3 <args>` with `stdin` as the message body (so no quoting/length issues).
    static func runCLI(_ args: [String], stdin: String, completion: @escaping (CLIResult) -> Void) {
        let cli = env.cli
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            return completion(CLIResult(ok: false, output: "t3 CLI not found at \(cli.path)"))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = cli
            p.arguments = args
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe
            do {
                try p.run()
                inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
                try? inPipe.fileHandleForWriting.close()
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = (String(data: out, encoding: .utf8) ?? "") + (String(data: err, encoding: .utf8) ?? "")
                DispatchQueue.main.async {
                    completion(CLIResult(ok: p.terminationStatus == 0, output: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            } catch {
                DispatchQueue.main.async { completion(CLIResult(ok: false, output: "\(error)")) }
            }
        }
    }

    /// Follow up on an existing thread. A busy thread queues it as its next turn.
    static func send(threadId: String, message: String, completion: @escaping (CLIResult) -> Void) {
        runCLI(["thread", "send", threadId, "-"], stdin: message, completion: completion)
    }

    /// Start a new thread in a project. Returns the new thread id in `output` on success.
    /// `model` is required by T3 when the project has no default model.
    static func start(projectId: String, message: String, model: (provider: String, model: String)? = nil,
                      completion: @escaping (CLIResult) -> Void) {
        var args = ["thread", "start", projectId, "-"]
        if let model { args += ["--provider", model.provider, "--model", model.model] }
        runCLI(args, stdin: message) { r in
            let id = r.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            completion(CLIResult(ok: r.ok, output: r.ok ? id : r.output))
        }
    }
}
