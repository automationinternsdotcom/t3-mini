import Foundation

/// Reads thread facts from T3 Code's v2 projections (read-only).
public final class StateReader {
    public let environment: T3Environment
    private var reader: SQLiteReader?
    /// How far back to look for unviewed Ready/Blocked threads.
    public var lookback: TimeInterval = 7 * 24 * 3600  // Ready cards live 7 days

    public init(environment: T3Environment = T3Environment()) {
        self.environment = environment
    }

    private func connection() throws -> SQLiteReader {
        if let reader { return reader }
        let r = try SQLiteReader(path: environment.database.path)
        reader = r
        return r
    }

    /// Drop the connection (e.g. after T3 restarts or the file moved).
    public func reset() { reader = nil }

    public func dataVersion() -> Int64 { (try? connection().dataVersion()) ?? -1 }

    public func readFacts(now: Date = Date()) throws -> [ThreadFacts] {
        let db = try connection()
        let cutoff = ISODate.string(now.addingTimeInterval(-lookback))

        // Threads touched recently, plus anything with a pending request or an active run regardless of age.
        let threadRows = try db.rows("""
            SELECT t.thread_id, t.project_id, p.title, t.title, t.updated_at,
                   json_extract(t.payload_json, '$.lastVisitedAt'),
                   json_extract(t.payload_json, '$.lineage.relationshipToParent'),
                   json_extract(t.payload_json, '$.lineage.rootThreadId')
            FROM orchestration_v2_projection_threads t
            LEFT JOIN projection_projects p ON p.project_id = t.project_id
            WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
              AND (t.updated_at >= ?1
                   OR t.thread_id IN (SELECT thread_id FROM orchestration_v2_projection_runtime_requests WHERE status = 'pending')
                   OR t.thread_id IN (SELECT thread_id FROM orchestration_v2_projection_runs
                                      WHERE status IN ('preparing','queued','starting','running','waiting')))
            """, [cutoff])

        var facts: [String: ThreadFacts] = [:]
        var order: [String] = []
        for r in threadRows {
            guard let id = r.string(0) else { continue }
            let rel = r.string(6)
            facts[id] = ThreadFacts(
                threadId: id, projectId: r.string(1) ?? "", projectTitle: r.string(2), title: r.string(3) ?? "Untitled",
                updatedAt: ISODate.parse(r.string(4)), lastVisitedAt: ISODate.parse(r.string(5)),
                isSubagent: rel == "subagent", rootThreadId: r.string(7))
            order.append(id)
        }
        guard !facts.isEmpty else { return [] }

        // Latest run per thread.
        for r in try db.rows("""
            SELECT r.thread_id, r.run_id, r.status, r.completed_at
            FROM orchestration_v2_projection_runs r
            JOIN (SELECT thread_id, MAX(ordinal) AS mo FROM orchestration_v2_projection_runs GROUP BY thread_id) m
              ON m.thread_id = r.thread_id AND m.mo = r.ordinal
            """) {
            guard let id = r.string(0), facts[id] != nil else { continue }
            facts[id]!.latestRunId = r.string(1)
            facts[id]!.latestRunStatus = r.string(2)
            facts[id]!.latestRunCompletedAt = ISODate.parse(r.string(3))
        }

        // Pending approvals / questions.
        for r in try db.rows("""
            SELECT thread_id, kind, created_at, runtime_request_id FROM orchestration_v2_projection_runtime_requests
            WHERE status = 'pending' ORDER BY created_at
            """) {
            guard let id = r.string(0), facts[id] != nil else { continue }
            facts[id]!.pendingRequestKinds.append(r.string(1) ?? "approval")
            if let rid = r.string(3) { facts[id]!.pendingRequestIds.append(rid) }
            if facts[id]!.pendingSince == nil { facts[id]!.pendingSince = ISODate.parse(r.string(2)) }
        }

        let ids = Array(facts.keys)
        // Parents need detail; failed sub-agents need their error (it rolls up to the parent).
        let interesting = ids.filter { id in
            let f = facts[id]!
            return f.latestRunStatus != nil && (!f.isSubagent || f.latestRunStatus == "failed")
        }
        for id in interesting {
            let f = facts[id]!
            let status = f.latestRunStatus ?? ""
            if StateDeriver.activeRunStatuses.contains(status) {
                if let row = try db.rows("""
                    SELECT type FROM orchestration_v2_projection_turn_items
                    WHERE thread_id = ?1 AND status IN ('running','in_progress','pending')
                    ORDER BY ordinal DESC LIMIT 1
                    """, [id]).first {
                    facts[id]!.activeItemType = row.string(0)
                }
                // Newest reasoning / agent text in the current run, for the live subtitle.
                for row in try db.rows("""
                    SELECT type, json_extract(payload_json, '$.text') FROM orchestration_v2_projection_turn_items
                    WHERE thread_id = ?1 AND run_id = ?2 AND type IN ('reasoning','assistant_message')
                    ORDER BY ordinal DESC LIMIT 6
                    """, [id, f.latestRunId ?? ""]) {
                    let text = row.string(1)
                    if row.string(0) == "reasoning", facts[id]!.liveReasoning == nil { facts[id]!.liveReasoning = text }
                    if row.string(0) == "assistant_message", facts[id]!.liveAgentText == nil { facts[id]!.liveAgentText = text }
                }
            } else if status == "completed" {
                // The reply arrives as several messages; keep the run's last few for the digest.
                let rows = try db.rows("""
                    SELECT json_extract(payload_json, '$.text') FROM orchestration_v2_projection_messages
                    WHERE thread_id = ?1 AND role = 'assistant' AND streaming = 0
                      AND (?2 = '' OR run_id = ?2)
                    ORDER BY created_at DESC LIMIT 12
                    """, [id, f.latestRunId ?? ""])
                facts[id]!.lastAssistantText = rows.first?.string(0)
                facts[id]!.runReplyChunks = rows.reversed().compactMap { $0.string(0) }
            } else if status == "failed" {
                if let row = try db.rows("""
                    SELECT json_extract(payload_json, '$.lastError') FROM orchestration_v2_projection_provider_sessions
                    WHERE thread_id = ?1 AND json_extract(payload_json, '$.lastError') IS NOT NULL
                    ORDER BY updated_at DESC LIMIT 1
                    """, [id]).first {
                    facts[id]!.lastError = row.string(0)
                }
            }
        }
        return order.compactMap { facts[$0] }
    }

    public func activities(now: Date = Date()) throws -> [ThreadActivity] {
        StateDeriver.activities(from: try readFacts(now: now))
    }

    public struct Message: Equatable, Identifiable {
        public var id: String
        public var role: String
        public var text: String
        public var createdAt: Date?
    }

    /// The latest few messages of a thread, oldest first (for the transcript peek).
    public func recentMessages(threadId: String, limit: Int = 6) throws -> [Message] {
        let rows = try connection().rows("""
            SELECT message_id, role, json_extract(payload_json, '$.text'), created_at
            FROM orchestration_v2_projection_messages
            WHERE thread_id = ?1 AND role IN ('user','assistant') AND streaming = 0
              AND json_extract(payload_json, '$.text') IS NOT NULL
            ORDER BY created_at DESC LIMIT ?2
            """, [threadId, limit])
        return rows.reversed().map {
            Message(id: $0.string(0) ?? UUID().uuidString, role: $0.string(1) ?? "assistant",
                    text: $0.string(2) ?? "", createdAt: ISODate.parse($0.string(3)))
        }
    }

    public struct Project: Equatable, Identifiable, Hashable {
        public var id: String
        public var title: String
        public var root: String
        public var hasDefaultModel: Bool = true
    }

    /// Provider instance + model to use when a project has no default model:
    /// the most recent selection in that project, else the most recent anywhere.
    public func fallbackModel(projectId: String) throws -> (provider: String, model: String)? {
        let rows = try connection().rows("""
            SELECT json_extract(payload_json, '$.modelSelection.instanceId'), json_extract(payload_json, '$.modelSelection.model')
            FROM orchestration_v2_projection_threads
            WHERE deleted_at IS NULL AND json_extract(payload_json, '$.modelSelection.model') IS NOT NULL
              AND COALESCE(json_extract(payload_json, '$.lineage.relationshipToParent'), '') <> 'subagent'
            ORDER BY (project_id = ?1) DESC, updated_at DESC LIMIT 1
            """, [projectId])
        guard let r = rows.first, let p = r.string(0), let m = r.string(1) else { return nil }
        return (p, m)
    }

    /// Projects, most recently active first.
    public func projects() throws -> [Project] {
        try connection().rows("""
            SELECT p.project_id, p.title, p.workspace_root, p.default_model_selection_json,
                   (SELECT MAX(t.updated_at) FROM orchestration_v2_projection_threads t WHERE t.project_id = p.project_id) AS last
            FROM projection_projects p
            WHERE p.deleted_at IS NULL AND p.archived_at IS NULL
            ORDER BY last IS NULL, last DESC
            """).compactMap { r in
            guard let id = r.string(0) else { return nil }
            let dm = r.string(3) ?? ""
            return Project(id: id, title: r.string(1) ?? id, root: r.string(2) ?? "",
                           hasDefaultModel: !dm.isEmpty && dm != "null")
        }
    }
}
