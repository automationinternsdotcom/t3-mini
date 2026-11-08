import Foundation

/// Where T3 Code keeps its local state, and how to reach the running app.
public struct T3Environment {
    public static let bundleIdentifier = "com.t3tools.t3code"
    public static let urlScheme = "t3code"

    public let home: URL  // ~/.t3 (or $T3CODE_HOME)

    public init(home: URL? = nil) {
        if let home {
            self.home = home
        } else if let env = ProcessInfo.processInfo.environment["T3CODE_HOME"], !env.isEmpty {
            self.home = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        } else {
            self.home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3")
        }
    }

    public var userData: URL { home.appendingPathComponent("userdata") }
    public var database: URL { userData.appendingPathComponent("statev2.sqlite") }
    public var walFile: URL { userData.appendingPathComponent("statev2.sqlite-wal") }
    public var runtimeFile: URL { userData.appendingPathComponent("server-runtime.json") }
    public var cli: URL { home.appendingPathComponent("bin/t3") }

    /// The local environment id used in thread deep links.
    public var environmentId: String? {
        guard let raw = try? String(contentsOf: userData.appendingPathComponent("environment-id"), encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// pid of the running T3 server, if its runtime file names a live process.
    public var serverPid: Int32? {
        guard let data = try? Data(contentsOf: runtimeFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (obj["pid"] as? NSNumber)?.int32Value
        else { return nil }
        return kill(pid, 0) == 0 ? pid : nil
    }

    public var isServerRunning: Bool { serverPid != nil }

    /// t3code://threads/<environmentId>/<threadId> — handled by T3 Code's open-url listener.
    public func threadURL(_ threadId: String) -> URL? {
        guard let env = environmentId else { return nil }
        var c = URLComponents()
        c.scheme = Self.urlScheme
        c.host = "threads"
        c.path = "/\(env)/\(threadId)"
        return c.url
    }
}
