import Foundation

/// The four attention states shown on cards, plus idle (not shown).
public enum AttentionState: String, Codable, CaseIterable, Comparable {
    case needsInput  // waiting on an approval / answer
    case blocked  // failed, not viewed since
    case ready  // finished, not viewed since
    case running  // working
    case idle

    /// Lower = more urgent: needs input, blocked, ready, running.
    public var priority: Int {
        switch self {
        case .needsInput: return 0
        case .blocked: return 1
        case .ready: return 2
        case .running: return 3
        case .idle: return 4
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.priority < b.priority }

    public var label: String {
        switch self {
        case .needsInput: return "Needs input"
        case .blocked: return "Blocked"
        case .ready: return "Ready"
        case .running: return "Running"
        case .idle: return "Idle"
        }
    }
}

/// Raw facts about one thread, as read from T3's projections.
public struct ThreadFacts: Codable, Equatable {
    public var threadId: String
    public var projectId: String
    public var projectTitle: String?
    public var title: String
    public var updatedAt: Date?
    public var lastVisitedAt: Date?
    public var isSubagent: Bool
    public var rootThreadId: String?
    public var latestRunId: String?
    public var latestRunStatus: String?
    public var latestRunCompletedAt: Date?
    public var pendingRequestKinds: [String]
    public var activeItemType: String?
    public var lastAssistantText: String?
    public var lastError: String?
    /// When the oldest still-pending request was raised (Needs input ages from this, not the run).
    public var pendingSince: Date?
    /// Ids of pending requests (each new question is a new card, even within one run).
    public var pendingRequestIds: [String] = []
    /// Latest reasoning / agent text of the running turn (for the live subtitle).
    public var liveReasoning: String?
    public var liveAgentText: String?
    /// Assistant messages of the latest finished run, oldest first (for the Ready-card digest).
    public var runReplyChunks: [String] = []

    public init(threadId: String, projectId: String, projectTitle: String? = nil, title: String,
                updatedAt: Date? = nil, lastVisitedAt: Date? = nil, isSubagent: Bool = false,
                rootThreadId: String? = nil, latestRunId: String? = nil, latestRunStatus: String? = nil,
                latestRunCompletedAt: Date? = nil, pendingRequestKinds: [String] = [],
                activeItemType: String? = nil, lastAssistantText: String? = nil, lastError: String? = nil) {
        self.threadId = threadId
        self.projectId = projectId
        self.projectTitle = projectTitle
        self.title = title
        self.updatedAt = updatedAt
        self.lastVisitedAt = lastVisitedAt
        self.isSubagent = isSubagent
        self.rootThreadId = rootThreadId
        self.latestRunId = latestRunId
        self.latestRunStatus = latestRunStatus
        self.latestRunCompletedAt = latestRunCompletedAt
        self.pendingRequestKinds = pendingRequestKinds
        self.activeItemType = activeItemType
        self.lastAssistantText = lastAssistantText
        self.lastError = lastError
    }
}

/// One card in the activity stack.
public struct ThreadActivity: Codable, Equatable, Identifiable {
    public var id: String { threadId }
    public var threadId: String
    public var projectId: String
    public var projectTitle: String?
    public var title: String
    public var state: AttentionState
    public var subtitle: String
    /// Identifies this particular attention event, so a dismissal hides it only until something new happens.
    public var eventKey: String
    public var since: Date?
    /// Top-level chat this card belongs to (a failed sub-agent's parent), for muting.
    public var rootThreadId: String?
    /// Ready cards: what the user needs to do (nil = nothing) and where things stand.
    public var summary: ReplySummary?
}

public enum StateDeriver {
    static let activeRunStatuses: Set<String> = ["preparing", "queued", "starting", "running", "waiting"]

    /// Derive the attention state of one top-level thread.
    /// `childPending` = pending request kinds raised by its subagent threads.
    public static func state(for f: ThreadFacts, childPending: [String] = []) -> AttentionState {
        if !(f.pendingRequestKinds + childPending).isEmpty { return .needsInput }
        guard let status = f.latestRunStatus else { return .idle }
        if activeRunStatuses.contains(status) { return .running }
        let unviewed: Bool = {
            guard let done = f.latestRunCompletedAt else { return false }
            guard let seen = f.lastVisitedAt else { return true }
            return done > seen
        }()
        switch status {
        case "failed": return unviewed ? .blocked : .idle
        case "completed": return unviewed ? .ready : .idle
        default: return .idle  // interrupted / cancelled / rolled_back: user-initiated, nothing to surface
        }
    }

    public static func subtitle(for f: ThreadFacts, state: AttentionState, pendingKinds: [String]) -> String {
        switch state {
        case .needsInput:
            switch pendingKinds.first ?? "" {
            case "user_input": return "Has a question for you"
            case "auth_refresh": return "Needs you to sign in again"
            case let k where k.contains("command"): return "Wants to run a command"
            case let k where k.contains("file"): return "Wants to change files"
            default: return "Waiting for your approval"
            }
        case .blocked:
            return firstLine(f.lastError) ?? "Run failed"
        case .ready:
            return firstLine(f.lastAssistantText) ?? "Finished"
        case .running:
            // Newest reasoning summary if short, else the newest agent message, else the tool label.
            if let r = firstLine(f.liveReasoning), r.count <= 60 { return r }
            if let t = firstLine(f.liveAgentText) { return t }
            switch f.activeItemType ?? "" {
            case "command_execution": return "Running command"
            case "file_change": return "Editing files"
            case "web_search": return "Searching web"
            case "file_search": return "Searching files"
            case "dynamic_tool", "mcp_tool_call": return "Calling tool"
            case "subagent": return "Running a subagent"
            case "assistant_message": return "Writing"
            default: return "Thinking"
            }
        case .idle:
            return ""
        }
    }

    static func firstLine(_ s: String?) -> String? {
        guard let s else { return nil }
        let line = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line, !line.isEmpty else { return nil }
        let cleaned = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return cleaned.count > 140 ? String(cleaned.prefix(139)) + "…" : cleaned
    }

    /// Fold raw facts (including subagent threads) into the activity list, most urgent first.
    /// Sub-agent threads stay hidden (their questions roll up into the parent), except a failed sub-agent,
    /// which gets its own notification until viewed.
    public static func activities(from facts: [ThreadFacts]) -> [ThreadActivity] {
        var childPending: [String: [String]] = [:]
        var childPendingSince: [String: Date] = [:]
        var childPendingIds: [String: [String]] = [:]
        for f in facts where f.isSubagent {
            guard let root = f.rootThreadId, !f.pendingRequestKinds.isEmpty else { continue }
            childPending[root, default: []] += f.pendingRequestKinds
            childPendingIds[root, default: []] += f.pendingRequestIds
            if let s = f.pendingSince { childPendingSince[root] = min(childPendingSince[root] ?? s, s) }
        }
        let byId = Dictionary(facts.map { ($0.threadId, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ThreadActivity] = []
        for var f in facts {
            var st: AttentionState
            var kinds: [String] = []
            var requestIds: [String] = []
            if f.isSubagent {
                // Unviewed failure (by the child, or by the parent opened after it) → its own Blocked card.
                guard f.latestRunStatus == "failed", let done = f.latestRunCompletedAt else { continue }
                let seen = [f.lastVisitedAt, f.rootThreadId.flatMap { byId[$0]?.lastVisitedAt }].compactMap { $0 }.max()
                guard seen.map({ done > $0 }) ?? true else { continue }
                if f.lastError == nil { f.lastError = "Subagent failed" }
                st = .blocked
            } else {
                kinds = f.pendingRequestKinds + (childPending[f.threadId] ?? [])
                requestIds = f.pendingRequestIds + (childPendingIds[f.threadId] ?? [])
                if f.pendingSince == nil { f.pendingSince = childPendingSince[f.threadId] }
                st = state(for: f, childPending: childPending[f.threadId] ?? [])
                guard st != .idle else { continue }
            }
            // Dismissal lasts for the whole run (per card + run), whatever the status becomes;
            // a new question in the same run is a new card.
            let key = st == .needsInput
                ? "\(f.threadId)|input|\(requestIds.isEmpty ? kinds.joined(separator: ",") : requestIds.sorted().joined(separator: ","))"
                : "\(f.threadId)|run|\(f.latestRunId ?? "")"
            out.append(ThreadActivity(
                threadId: f.threadId, projectId: f.projectId, projectTitle: f.projectTitle, title: f.title,
                state: st, subtitle: subtitle(for: f, state: st, pendingKinds: kinds), eventKey: key,
                since: st == .running ? f.updatedAt
                    : st == .needsInput ? (f.pendingSince ?? f.updatedAt)
                    : (f.latestRunCompletedAt ?? f.updatedAt),
                rootThreadId: f.isSubagent ? f.rootThreadId : nil,
                summary: st == .ready && !f.runReplyChunks.isEmpty ? ReplySummary.from(chunks: f.runReplyChunks) : nil))
        }
        return out.sorted {
            if $0.state != $1.state { return $0.state < $1.state }
            return ($0.since ?? .distantPast) > ($1.since ?? .distantPast)
        }
    }
}
