import Foundation
import SQLite3
import T3MiniCore

// t3mini-check: headless verification for T3 Mini.
//   t3mini-check dump        print live derived activity as JSON (reads ~/.t3 read-only)
//   t3mini-check selftest    run state-derivation tests against a synthetic T3 database
//   t3mini-check pets [dir]  validate pet packages (built-in dir optional)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("FAIL: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601

switch args.first ?? "dump" {
case "dump":
    let env = T3Environment()
    let reader = StateReader(environment: env)
    do {
        let acts = try reader.activities()
        let out: [String: Any] = [
            "serverRunning": env.isServerRunning,
            "environmentId": env.environmentId ?? NSNull(),
            "count": acts.count,
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
        print(String(data: try encoder.encode(acts), encoding: .utf8)!)
        for a in acts { print("deeplink:", env.threadURL(a.threadId)?.absoluteString ?? "-") }
    } catch { fail("\(error)") }

case "pets":
    let dir = args.dropFirst().first.map { URL(fileURLWithPath: $0) }
    let (pets, errors) = PetCatalog.discover(builtInDir: dir)
    for p in pets { print("ok  \(p.source.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(p.manifest.id) v\(p.version) \(Int(p.sheetSize.width))x\(Int(p.sheetSize.height)) \(p.sheetURL.lastPathComponent)") }
    for e in errors { print("err \(e)") }
    if pets.isEmpty { fail("no pets found") }

case "digests":
    // Ready-card digests for recently finished threads (whether or not they were viewed).
    let reader = StateReader(environment: T3Environment())
    do {
        for f in try reader.readFacts() where !f.isSubagent && f.latestRunStatus == "completed" && !f.runReplyChunks.isEmpty {
            let d = ReplySummary.from(chunks: f.runReplyChunks)
            print("• \(f.title.prefix(60))\n    need: \(d.need ?? "Nothing needed from you")\n    situation: \(d.situation ?? "-")")
        }
    } catch { fail("\(error)") }

case "selftest":
    try selftest()
    print("selftest: all checks passed")

default:
    fail("unknown command \(args.first!)")
}

// MARK: - Self test

func selftest() throws {
    var checks = 0
    func expect(_ cond: Bool, _ what: String) {
        checks += 1
        if !cond { fail(what) }
    }

    // Pure derivation.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let base = ThreadFacts(threadId: "a", projectId: "p", title: "A")
    var f = base
    expect(StateDeriver.state(for: f) == .idle, "no runs -> idle")
    f.latestRunStatus = "running"
    expect(StateDeriver.state(for: f) == .running, "running run -> running")
    f.latestRunStatus = "waiting"
    expect(StateDeriver.state(for: f) == .running, "waiting w/o request -> running")
    f.pendingRequestKinds = ["command_execution_approval"]
    expect(StateDeriver.state(for: f) == .needsInput, "pending request -> needsInput")
    f.pendingRequestKinds = []
    f.latestRunStatus = "completed"
    f.latestRunCompletedAt = t0
    f.lastVisitedAt = t0.addingTimeInterval(-10)
    expect(StateDeriver.state(for: f) == .ready, "completed after last visit -> ready")
    f.lastVisitedAt = t0.addingTimeInterval(10)
    expect(StateDeriver.state(for: f) == .idle, "visited after completion -> idle")
    f.lastVisitedAt = nil
    expect(StateDeriver.state(for: f) == .ready, "never visited -> ready")
    f.latestRunStatus = "failed"
    expect(StateDeriver.state(for: f) == .blocked, "failed unviewed -> blocked")
    f.latestRunStatus = "interrupted"
    expect(StateDeriver.state(for: f) == .idle, "interrupted -> idle")
    f.latestRunStatus = "completed"
    expect(StateDeriver.state(for: f, childPending: ["user_input"]) == .needsInput, "subagent request bubbles up")

    // Ordering: needs input > blocked > ready > running.
    let facts = [
        ThreadFacts(threadId: "run", projectId: "p", title: "r", updatedAt: t0, latestRunId: "r1", latestRunStatus: "running"),
        ThreadFacts(threadId: "ready", projectId: "p", title: "d", latestRunId: "r2", latestRunStatus: "completed", latestRunCompletedAt: t0, lastAssistantText: "**Done.** All good\nmore"),
        ThreadFacts(threadId: "fail", projectId: "p", title: "f", latestRunId: "r3", latestRunStatus: "failed", latestRunCompletedAt: t0),
        ThreadFacts(threadId: "ask", projectId: "p", title: "q", latestRunId: "r4", latestRunStatus: "waiting"),
        ThreadFacts(threadId: "child", projectId: "p", title: "c", isSubagent: true, rootThreadId: "ask", latestRunStatus: "waiting", pendingRequestKinds: ["user_input"]),
        ThreadFacts(threadId: "old", projectId: "p", title: "o", lastVisitedAt: t0.addingTimeInterval(5), latestRunStatus: "completed", latestRunCompletedAt: t0),
    ]
    let acts = StateDeriver.activities(from: facts)
    expect(acts.map(\.threadId) == ["ask", "fail", "ready", "run"], "ordering/filtering: \(acts.map(\.threadId))")
    expect(acts[0].subtitle == "Has a question for you", "needs-input subtitle: \(acts[0].subtitle)")
    expect(acts[2].subtitle == "Done. All good", "ready subtitle strips markdown: \(acts[2].subtitle)")
    expect(acts[3].subtitle == "Thinking", "running default subtitle")
    expect(acts[1].eventKey != acts[2].eventKey, "event keys unique")

    // Ready-card digest: need (one sentence) + situation (one sentence).
    let s1 = ReplySummary.from(chunks: ["Working on it.", "**Answer:** The login bug is fixed and tests pass. More detail follows.\n\n**Need from you:** merge PR #12 when you're ready."])
    expect(s1.need == "Merge PR #12 when you're ready." && s1.situation == "The login bug is fixed and tests pass.", "digest from labelled reply: \(s1)")
    let s2 = ReplySummary.from(chunks: ["I updated the parser and added three tests. Should I also bump the version?"])
    expect(s2.need == "Should I also bump the version?" && s2.situation == "I updated the parser and added three tests.", "digest from question: \(s2)")
    let s3 = ReplySummary.from(chunks: ["Done: deployed v2 to staging.\nNothing needed from you."])
    let s3b = ReplySummary.from(chunks: ["## Result\nDeployed v2 to staging.\n\n**Need from you:** nothing needed."])
    expect(s3.need == nil && s3.situation == "Deployed v2 to staging." && s3b.need == nil && s3b.situation == "Deployed v2 to staging.", "digest when nothing is needed: \(s3) \(s3b)")
    let s4 = ReplySummary.from(chunks: ["| a | b |\n|---|---|\n| 1 | 2 |\n\nAll 30 checks pass on the new build, including the drag tests and the scroll checks."])
    expect(s4.situation?.hasPrefix("All 30 checks pass") == true, "digest skips tables: \(s4)")

    // End-to-end through SQLite with a synthetic T3 v2 schema.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t3mini-selftest-\(UUID().uuidString)")
    let userdata = dir.appendingPathComponent("userdata")
    try FileManager.default.createDirectory(at: userdata, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "env-123\n".write(to: userdata.appendingPathComponent("environment-id"), atomically: true, encoding: .utf8)
    let dbPath = userdata.appendingPathComponent("statev2.sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open(dbPath, &db) == SQLITE_OK else { fail("create fixture db") }
    let now = Date()
    let iso = { (d: Date) in ISODate.string(d) }
    let recent = iso(now.addingTimeInterval(-60))
    let older = iso(now.addingTimeInterval(-120))
    let veryOld = iso(now.addingTimeInterval(-30 * 3600))  // older than the 24 h Needs-input expiry
    let sql = """
    PRAGMA journal_mode=WAL;
    CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_root TEXT NOT NULL, deleted_at TEXT, archived_at TEXT, default_model_selection_json TEXT);
    CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL, created_at TEXT, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT, payload_json TEXT NOT NULL);
    CREATE TABLE orchestration_v2_projection_runs (run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, ordinal INTEGER NOT NULL, status TEXT NOT NULL, requested_at TEXT, completed_at TEXT, payload_json TEXT NOT NULL DEFAULT '{}');
    CREATE TABLE orchestration_v2_projection_runtime_requests (runtime_request_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, payload_json TEXT NOT NULL DEFAULT '{}');
    CREATE TABLE orchestration_v2_projection_turn_items (turn_item_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, run_id TEXT, ordinal INTEGER NOT NULL, type TEXT NOT NULL, status TEXT NOT NULL, payload_json TEXT NOT NULL DEFAULT '{}');
    CREATE TABLE orchestration_v2_projection_messages (message_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, run_id TEXT, role TEXT NOT NULL, streaming INTEGER NOT NULL, created_at TEXT NOT NULL, payload_json TEXT NOT NULL);
    CREATE TABLE orchestration_v2_projection_provider_sessions (provider_session_id TEXT PRIMARY KEY, thread_id TEXT, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL);
    INSERT INTO projection_projects VALUES ('p1','demo','/tmp/demo',NULL,NULL,NULL);
    INSERT INTO orchestration_v2_projection_threads VALUES
      ('t-run','p1','Working thread',NULL,'\(recent)',NULL,NULL,'{"modelSelection":{"instanceId":"claudeAgent","model":"claude-opus-5-5"},"lineage":{"relationshipToParent":null,"rootThreadId":"t-run"}}'),
      ('t-done','p1','Done thread',NULL,'\(recent)',NULL,NULL,'{"lastVisitedAt":"\(older)","lineage":{"rootThreadId":"t-done"}}'),
      ('t-seen','p1','Seen thread',NULL,'\(older)',NULL,NULL,'{"lastVisitedAt":"\(recent)","lineage":{"rootThreadId":"t-seen"}}'),
      ('t-fail','p1','Failing thread',NULL,'\(recent)',NULL,NULL,'{"lineage":{}}'),
      ('t-parent','p1','Parent',NULL,'\(recent)',NULL,NULL,'{"lineage":{}}'),
      ('t-child','p1','Child',NULL,'\(recent)',NULL,NULL,'{"lineage":{"relationshipToParent":"subagent","rootThreadId":"t-parent","parentThreadId":"t-parent"}}'),
      ('t-arch','p1','Archived',NULL,'\(recent)','\(recent)',NULL,'{"lineage":{}}'),
      ('t-p2','p1','Parent seen',NULL,'\(recent)',NULL,NULL,'{"lastVisitedAt":"\(older)","lineage":{}}'),
      ('t-c2','p1','Child failed',NULL,'\(recent)',NULL,NULL,'{"lineage":{"relationshipToParent":"subagent","rootThreadId":"t-p2"}}'),
      ('t-think','p1','Thinking thread',NULL,'\(recent)',NULL,NULL,'{"lineage":{}}');
    INSERT INTO orchestration_v2_projection_runs VALUES
      ('r0','t-run',1,'completed',NULL,'\(older)','{}'),
      ('r1','t-run',2,'running',NULL,NULL,'{}'),
      ('r2','t-done',1,'completed',NULL,'\(recent)','{}'),
      ('r3','t-seen',1,'completed',NULL,'\(older)','{}'),
      ('r4','t-fail',1,'failed',NULL,'\(recent)','{}'),
      ('r5','t-parent',1,'running',NULL,NULL,'{}'),
      ('r6','t-child',1,'waiting',NULL,NULL,'{}'),
      ('r7','t-arch',1,'running',NULL,NULL,'{}'),
      ('r8','t-p2',1,'completed',NULL,'\(veryOld)','{}'),
      ('r9','t-c2',1,'failed',NULL,'\(recent)','{}'),
      ('r10','t-think',1,'running',NULL,NULL,'{}');
    INSERT INTO orchestration_v2_projection_runtime_requests VALUES ('q1','t-child','user_input','pending','\(recent)','{}'), ('q2','t-done','command_execution_approval','resolved','\(older)','{}');
    INSERT INTO orchestration_v2_projection_turn_items VALUES ('i1','t-run','r1',5,'command_execution','running','{}'), ('i0','t-run','r0',4,'reasoning','completed','{"text":"old run thought"}'),
      ('i2','t-think','r10',1,'reasoning','completed','{"text":"Checking the auth flow\\nmore detail"}'), ('i3','t-think','r10',2,'command_execution','running','{}');
    INSERT INTO orchestration_v2_projection_messages VALUES ('m1','t-done','r2','assistant',0,'\(recent)','{"text":"Shipped the fix.\\nDetails..."}'), ('m0','t-done','r2','user',0,'\(older)','{"text":"please fix"}'),
      ('m2','t-done','r2','assistant',0,'\(recent)','{"text":"**Need from you:** approve the deploy to production."}');
    INSERT INTO orchestration_v2_projection_provider_sessions VALUES ('s1','t-fail','\(recent)','{"lastError":"Provider crashed: rate limited"}'),
      ('s2','t-c2','\(recent)','{"lastError":"Subagent ran out of context"}');
    """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { fail("fixture sql: \(String(cString: sqlite3_errmsg(db)))") }

    let env = T3Environment(home: dir)
    expect(env.threadURL("t-done")?.absoluteString == "t3code://threads/env-123/t-done", "deep link format")
    let reader = StateReader(environment: env)
    let v1 = reader.dataVersion()
    let live = try reader.activities(now: now)
    let byId = Dictionary(uniqueKeysWithValues: live.map { ($0.threadId, $0) })
    expect(Set(byId.keys) == ["t-run", "t-done", "t-fail", "t-parent", "t-c2", "t-think"], "fixture set: \(byId.keys.sorted())")
    expect(byId["t-c2"]?.state == .blocked && byId["t-c2"]?.subtitle == "Subagent ran out of context", "failed subagent gets its own Blocked card: \(String(describing: byId["t-c2"]))")
    expect(byId["t-c2"]?.rootThreadId == "t-p2", "failed sub-agent card carries its parent (muting the parent hides it)")
    // Dismissal key is per run, stable across Running -> Ready.
    let k1 = StateDeriver.activities(from: [ThreadFacts(threadId: "k", projectId: "p", title: "k", latestRunId: "r", latestRunStatus: "running")]).first?.eventKey
    let k2 = StateDeriver.activities(from: [ThreadFacts(threadId: "k", projectId: "p", title: "k", latestRunId: "r", latestRunStatus: "completed", latestRunCompletedAt: now)]).first?.eventKey
    expect(k1 != nil && k1 == k2, "dismissal key stable across status changes within a run")
    var q1 = ThreadFacts(threadId: "q", projectId: "p", title: "q", latestRunId: "r", latestRunStatus: "waiting", pendingRequestKinds: ["user_input"])
    q1.pendingRequestIds = ["req-1"]
    var q2 = q1; q2.pendingRequestIds = ["req-2"]
    expect(StateDeriver.activities(from: [q1]).first?.eventKey != StateDeriver.activities(from: [q2]).first?.eventKey,
           "successive questions in one run get distinct dismissal keys")
    expect(byId["t-think"]?.subtitle == "Checking the auth flow", "running subtitle prefers short live reasoning: \(byId["t-think"]?.subtitle ?? "-")")
    expect(byId["t-parent"]?.state == .needsInput, "child request -> parent needs input")
    expect(byId["t-parent"]?.since.map { abs($0.timeIntervalSince(now.addingTimeInterval(-60))) < 2 } == true, "Needs input ages from the pending request")
    expect(byId["t-run"]?.state == .running && byId["t-run"]?.subtitle == "Running command", "running w/ active command")
    expect(byId["t-done"]?.state == .ready, "ready w/ message")
    expect(byId["t-done"]?.summary?.need == "Approve the deploy to production." && byId["t-done"]?.summary?.situation == "Shipped the fix.",
           "Ready card digest from the run's reply chunks: \(String(describing: byId["t-done"]?.summary))")
    expect(byId["t-fail"]?.state == .blocked && byId["t-fail"]?.subtitle == "Provider crashed: rate limited", "blocked w/ error")
    expect(live.first?.threadId == "t-parent", "most urgent first")
    let msgs = try reader.recentMessages(threadId: "t-done")
    expect(msgs.first?.role == "user" && msgs.dropFirst().allSatisfy { $0.role == "assistant" } && msgs.count == 3, "transcript order")
    expect(try reader.projects().first?.title == "demo", "projects")
    expect(try reader.projects().first?.hasDefaultModel == false, "project without default model detected")
    let fb = try reader.fallbackModel(projectId: "p1")
    expect(fb?.provider == "claudeAgent" && fb?.model == "claude-opus-5-5", "fallback model from recent thread")

    // A write by "T3" (another connection) must bump data_version and change the result.
    sqlite3_exec(db, "UPDATE orchestration_v2_projection_threads SET payload_json = json_set(payload_json, '$.lastVisitedAt', '\(iso(now))') WHERE thread_id = 't-done'", nil, nil, nil)
    expect(reader.dataVersion() != v1, "data_version changes on external commit")
    expect(try reader.activities(now: now).contains { $0.threadId == "t-done" } == false, "visiting clears Ready")
    sqlite3_close(db)
    print("selftest: \(checks) checks")
}
