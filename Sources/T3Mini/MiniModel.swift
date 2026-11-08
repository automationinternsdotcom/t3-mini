import AppKit
import Combine
import T3MiniCore

/// Live view of T3 Code's threads, polled read-only from its SQLite projections.
final class MiniModel: ObservableObject {
    @Published private(set) var all: [ThreadActivity] = []
    @Published private(set) var serverRunning = false
    @Published private(set) var projects: [StateReader.Project] = []
    @Published private(set) var lastError: String?
    /// Fires with the thread whose state just escalated (new Ready / Needs input / Blocked).
    let transitions = PassthroughSubject<ThreadActivity, Never>()

    private let reader = StateReader()
    private let queue = DispatchQueue(label: "t3mini.reader")
    private var timer: Timer?
    private var lastVersion: Int64 = .min
    private var lastFullRead = Date.distantPast
    private var previous: [String: AttentionState] = [:]
    private var bag = Set<AnyCancellable>()
    let settings = Settings.shared

    init() {
        settings.$mutedThreads.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        settings.$dismissedEvents.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    /// Cards to show: not dismissed, not muted, not expired; most urgent first.
    var visible: [ThreadActivity] {
        let now = Date()
        let dismissed = Set(settings.dismissedEvents)
        // Muted chats stop producing cards (unmute from the right-click / menu-bar "Muted chats").
        return all.filter {
            !dismissed.contains($0.eventKey) && !isMuted($0) && !Self.expired($0, now: now)
        }
    }

    /// Card lifetimes: Blocked 1 h, Needs input 24 h, Ready 7 days, Running until it changes.
    static func expired(_ a: ThreadActivity, now: Date) -> Bool {
        guard let since = a.since else { return false }
        let ttl: TimeInterval
        switch a.state {
        case .blocked: ttl = 3600
        case .needsInput: ttl = 24 * 3600
        case .ready: ttl = 7 * 24 * 3600
        default: return false
        }
        return now.timeIntervalSince(since) > ttl
    }
    var attention: [ThreadActivity] { visible }
    /// Titles for muted chats (from the chat's own card, or a sub-agent card that belongs to it).
    var mutedTitles: [String: String] {
        var t: [String: String] = [:]
        for a in all {
            if settings.mutedThreads.contains(a.threadId) { t[a.threadId] = a.title }
            if let r = a.rootThreadId, settings.mutedThreads.contains(r), t[r] == nil { t[r] = "\(a.title) (sub-agent's chat)" }
        }
        return t
    }

    /// Muting a chat also silences its sub-agents' cards.
    func isMuted(_ a: ThreadActivity) -> Bool {
        settings.mutedThreads.contains(a.threadId) || a.rootThreadId.map(settings.mutedThreads.contains) == true
    }
    var top: ThreadActivity? { attention.first }
    var aggregate: AttentionState { top?.state ?? .idle }

    func start() {
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh(force: false) }
    }

    func refresh(force: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let running = self.reader.environment.isServerRunning
            let version = self.reader.dataVersion()
            // Re-read on any commit by T3, and every 15s regardless (relative-time cutoffs, reconnects).
            let stale = Date().timeIntervalSince(self.lastFullRead) > 15
            guard force || stale || version != self.lastVersion else {
                if running != self.serverRunning { DispatchQueue.main.async { self.serverRunning = running } }
                return
            }
            self.lastVersion = version
            self.lastFullRead = Date()
            do {
                let acts = try self.reader.activities()
                let projects = (try? self.reader.projects()) ?? []
                DispatchQueue.main.async { self.apply(acts, projects: projects, running: running, error: nil) }
            } catch {
                self.reader.reset()
                DispatchQueue.main.async { self.apply(self.all, projects: self.projects, running: running, error: "\(error)") }
            }
        }
    }

    private func apply(_ acts: [ThreadActivity], projects: [StateReader.Project], running: Bool, error: String?) {
        let firstLoad = previous.isEmpty && all.isEmpty
        var next: [String: AttentionState] = [:]
        for a in acts {
            next[a.threadId] = a.state
            let before = previous[a.threadId] ?? .idle
            let escalated = a.state != before && a.state != .running
            if escalated && !firstLoad && !isMuted(a) {
                transitions.send(a)
            }
        }
        previous = next
        if acts != all { all = acts }
        if projects != self.projects { self.projects = projects }
        serverRunning = running
        lastError = error
    }

    func dismiss(_ a: ThreadActivity) {
        if !settings.dismissedEvents.contains(a.eventKey) { settings.dismissedEvents.append(a.eventKey) }
    }

    func toggleMute(_ a: ThreadActivity) {
        let id = a.rootThreadId ?? a.threadId  // muting a sub-agent card mutes its chat
        if settings.mutedThreads.contains(id) { settings.mutedThreads.remove(id) }
        else { settings.mutedThreads.insert(id) }
    }

    func messages(for threadId: String, completion: @escaping ([StateReader.Message]) -> Void) {
        queue.async { [weak self] in
            let m = (try? self?.reader.recentMessages(threadId: threadId, limit: 6)) ?? []
            DispatchQueue.main.async { completion(m) }
        }
    }

    func fallbackModel(projectId: String) -> (provider: String, model: String)? {
        queue.sync { try? reader.fallbackModel(projectId: projectId) }
    }

    /// Default project for new chats: last used, else the most recently active.
    var defaultProject: StateReader.Project? {
        if let id = settings.lastProjectId, let p = projects.first(where: { $0.id == id }) { return p }
        return projects.first
    }
}
