import XCTest
@testable import ORXAnalyticsCore

/// Wire-contract tests for `runs.get` / `tasks.get` payloads. The JSON
/// below mirrors EXACTLY what the Python query layer serializes
/// (`query_model.runs_get` / `tasks_get` + `usage_readmodel` blocks):
/// `cached_input` (not cached_tokens), per-field `missing_fields`
/// dicts, `coverage` blocks, INTEGER revision ids, 0/1 `passed`, and a
/// native preview that carries `never_sum_with`. If the Swift models
/// drift from the engine's wire format these tests go red before the
/// UI silently shows "—" everywhere.
final class DetailModelsTests: XCTestCase {

    // MARK: - runs.get

    func testRunDetailDecodesFullWirePayload() throws {
        let envelope = try JSONDecoder().decode(RunDetailEnvelope.self,
                                                from: Self.runDetailJSON)
        XCTAssertEqual(envelope.header.op, "runs.get")
        XCTAssertTrue(envelope.found)
        XCTAssertEqual(envelope.run?.progress?.revisionID, 102)
        XCTAssertEqual(envelope.run?.progress?.revision, 2)
        XCTAssertEqual(envelope.run?.consumption?.tokens?.cachedTokens, nil)
        XCTAssertEqual(envelope.run?.consumption?.observedTotal, 1200)
        // per-field missing dict, not a scalar
        XCTAssertEqual(envelope.run?.consumption?.missingFields?["output_tokens"], 1)
        XCTAssertEqual(envelope.run?.consumption?.coverage?.observed, 3)
        XCTAssertEqual(envelope.run?.consumption?.coverage?.attempts, 5)
        XCTAssertEqual(envelope.revisions.count, 2)
        XCTAssertEqual(envelope.revisions.last?.revisionID, 102)
        XCTAssertEqual(envelope.tasks.count, 2)
        XCTAssertEqual(envelope.tasks.first?.revisionID, 101)
        XCTAssertEqual(envelope.tasks.first?.status.display, "完成")
        XCTAssertEqual(envelope.tasks.last?.failureReason, "timeout")
        XCTAssertEqual(envelope.tasks.last?.attemptCount, 2)
    }

    func testRunUsageBooksDecodeWithRolesAndNotes() throws {
        let envelope = try JSONDecoder().decode(RunDetailEnvelope.self,
                                                from: Self.runDetailJSON)
        let usage = try XCTUnwrap(envelope.usage)
        XCTAssertEqual(usage.caliber, "orx_recorded")
        XCTAssertEqual(usage.books?.tasks?.attempts, 5)
        XCTAssertEqual(usage.books?.planner?.revisionIDs, [nil])
        XCTAssertEqual((usage.books?.controller?.note ?? "").isEmpty, false)
        XCTAssertEqual(usage.books?.unattributedWithinRun?.attempts, 1)
        XCTAssertEqual(usage.perTask?.first?.taskID, "T001")
        XCTAssertEqual(usage.perTask?.first?.revision, 1)
        XCTAssertEqual(usage.perRevision?.count, 2)
        XCTAssertEqual(usage.normalizedProcessing?.version, 1)
        XCTAssertEqual(usage.normalizedProcessing?.partial, true)
    }

    func testNativePreviewIsASeparateCaliberAndDeclaresIt() throws {
        let envelope = try JSONDecoder().decode(RunDetailEnvelope.self,
                                                from: Self.runDetailJSON)
        let preview = try XCTUnwrap(envelope.nativePreview)
        XCTAssertEqual(preview.caliber, "native_session_preview")
        XCTAssertEqual(preview.neverSumWith, "orx_recorded")
        XCTAssertEqual(preview.union?.tokens?.inputTokens, 600)
        XCTAssertEqual(preview.union?.sessions?.count, 2)
        XCTAssertEqual(preview.linkedAttempts?.first?.treeTotals?.turns, 10)
        XCTAssertEqual(preview.controllerSessions?.first?.ownUsage?.inputTokens, 100)
    }

    func testRunNotFoundStillDecodes() throws {
        let json = """
        {"op": "runs.get", "ok": true, "protocol_version": 1,
         "generated_at": "2026-10-16T10:00:00+00:00",
         "project": "/tmp/p", "run_id": "R404", "found": false,
         "reason": "run not found",
         "snapshots": {}, "coverage": {}, "warnings": []}
        """
        let envelope = try JSONDecoder().decode(RunDetailEnvelope.self,
                                                from: Data(json.utf8))
        XCTAssertFalse(envelope.found)
        XCTAssertEqual(envelope.reason, "run not found")
        XCTAssertNil(envelope.run)
    }

    // MARK: - tasks.get

    func testTaskDetailDecodesAttemptsWithEvidenceAndVerifications() throws {
        let envelope = try JSONDecoder().decode(TaskDetailEnvelope.self,
                                                from: Self.taskDetailJSON)
        XCTAssertEqual(envelope.header.op, "tasks.get")
        XCTAssertTrue(envelope.found)
        XCTAssertEqual(envelope.task?.status?.display, "失败")
        XCTAssertEqual(envelope.task?.failureReason, "timeout")
        let usage = try XCTUnwrap(envelope.usage)
        XCTAssertEqual(usage.books?.worker?.attempts, 2)
        XCTAssertEqual(usage.books?.verifier?.attempts, 1)
        XCTAssertEqual(usage.attempts.count, 3)
        let first = usage.attempts.first
        XCTAssertEqual(first?.model, "glm-4.7")
        XCTAssertEqual(first?.observation?.source, "zcode_db")
        XCTAssertEqual(first?.observation?.tokens?.inputTokens, 200)
        XCTAssertEqual(first?.sessionLink?.sessionID, "sess-1")
        XCTAssertEqual(first?.sessionLink?.confidence, "high")
        let missingAttempt = usage.attempts[1]
        XCTAssertEqual(missingAttempt.usageMissingReason, "attempt still running")
        XCTAssertNil(missingAttempt.observation)
        // SQLite INTEGER booleans: 0 -> false
        XCTAssertEqual(envelope.verifications.first?.passed, false)
        XCTAssertEqual(envelope.verifications.first?.exitCode, 1)
        XCTAssertEqual(envelope.retry?.recovered, false)
        XCTAssertEqual(envelope.retry?.successorAttemptIDs, [5])
    }

    // MARK: - calibers never combine

    func testDetailCalibersExposeTwoIndependentGroupsAndNoMergedRow() {
        let calibers = DetailCalibers(usage: decodedRunDetail()?.usage,
                                      preview: decodedRunDetail()?.nativePreview)
        XCTAssertEqual(calibers.orxRows.map(\.label),
                       ["输入", "输出", "缓存（cached_input）"])
        XCTAssertEqual(calibers.orxRows.map(\.text), ["1000", "200", "—"])
        XCTAssertEqual(calibers.nativeRows.map(\.label).first, "会话轮次")
        XCTAssertEqual(calibers.nativeRows.map(\.text),
                       ["12", "600", "120", "30", "60", "6"])
        // The two groups may describe the same tokens; nothing combines
        // them: there is no row and no accessor producing 1600 or 1720.
        let allTexts = calibers.orxRows.map(\.text) + calibers.nativeRows.map(\.text)
        XCTAssertFalse(allTexts.contains("1600"))
        XCTAssertFalse(allTexts.contains { $0.contains("+") })
    }

    func testDetailCalibersUnknownFieldsStayDash() throws {
        let calibers = DetailCalibers(usage: nil, preview: nil)
        XCTAssertEqual(calibers.orxRows.map(\.text), ["—", "—", "—"])
        XCTAssertEqual(calibers.nativeRows.map(\.text).prefix(1), ["—"])
    }

    private func decodedRunDetail() -> RunDetailEnvelope? {
        try? JSONDecoder().decode(RunDetailEnvelope.self, from: Self.runDetailJSON)
    }

    // MARK: - fixtures (mirror the Python wire format exactly)

    static let runDetailJSON: Data = {
        let consumption = """
        {"caliber": "orx_recorded",
         "tokens": {"input_tokens": 1000, "output_tokens": 200, "cached_input": null},
         "observed_total": 1200,
         "missing_fields": {"input_tokens": 0, "output_tokens": 1, "cached_input": 3},
         "accuracy": {"exact": 2, "estimated": 1, "unknown": 0},
         "coverage": {"observed": 3, "attempts": 5, "missing_recorded": 1, "unassessed": 1}}
        """
        // inner fields of a usage book (no braces) so per-task /
        // per-revision entries can append their identity keys
        let book = { (attempts: Int, ids: String, revs: String, note: String?) in
            var s = """
            "attempts": \(attempts), "attempt_ids": [\(ids)], "revision_ids": [\(revs)],
             "coverage": {"observed": \(attempts), "attempts": \(attempts), "missing_recorded": 0, "unassessed": 0},
             "tokens": {"input_tokens": 100, "output_tokens": 20, "cached_input": null},
             "missing_fields": {"input_tokens": 0, "output_tokens": 0, "cached_input": 0},
             "accuracy": {"exact": 1, "estimated": 0, "unknown": 0},
             "as_of": "2026-10-16T09:59:30+00:00"
            """
            if let note { s += ", \"note\": \"\(note)\"" }
            return s
        }
        let json = """
        {"op": "runs.get", "ok": true, "protocol_version": 1,
         "generated_at": "2026-10-16T10:00:00+00:00",
         "project": "/tmp/projA", "run_id": "R001", "found": true,
         "run": {
           "project": "/tmp/projA", "run_id": "R001",
           "identity": {"project": "/tmp/projA", "run_id": "R001"},
           "goal": {"id": "G001", "objective": "交付面板",
                    "status": {"raw": "active", "known": true, "display": "进行中"}},
           "status": {"raw": "running", "known": true, "display": "执行中"},
           "started_at": "2026-10-16T09:00:00+00:00",
           "completed_at": null, "updated_at": "2026-10-16T09:59:00+00:00",
           "created_at": "2026-10-16T09:00:00+00:00",
           "time_basis": {"field": "started_at", "value": "2026-10-16T09:00:00+00:00"},
           "progress": {"completed": 2, "total": 5, "revision_id": 102, "revision": 2,
                        "basis": "tasks of the current (highest) revision only"},
           "consumption": \(consumption),
           "data_as_of": "2026-10-16T09:59:30+00:00",
           "schema_version": "11"},
         "revisions": [
           {"revision_id": 101, "revision": 1, "status": "superseded",
            "created_at": "2026-10-16T09:05:00+00:00", "task_count": 3},
           {"revision_id": 102, "revision": 2, "status": "active",
            "created_at": "2026-10-16T09:30:00+00:00", "task_count": 5}],
         "tasks": [
           {"project": "/tmp/projA", "run_id": "R001",
            "identity": {"project": "/tmp/projA", "run_id": "R001",
                         "revision_id": 101, "task_id": "T001"},
            "revision_id": 101, "revision": 1, "task_id": "T001",
            "objective": "旧计划任务",
            "status": {"raw": "passed", "known": true, "display": "完成"},
            "failure_reason": null, "attempt_count": 2, "consumption": \(consumption)},
           {"project": "/tmp/projA", "run_id": "R001",
            "identity": {"project": "/tmp/projA", "run_id": "R001",
                         "revision_id": 102, "task_id": "T002"},
            "revision_id": 102, "revision": 2, "task_id": "T002",
            "objective": "当前失败任务",
            "status": {"raw": "failed", "known": true, "display": "失败"},
            "failure_reason": "timeout", "attempt_count": 2, "consumption": \(consumption)}],
         "usage": {
           "caliber": "orx_recorded", "project": "/tmp/projA", "run_id": "R001",
           "revision_scope": "all revisions via attempts.run_id",
           "snapshot_id": 7, "as_of": "2026-10-16T09:59:30+00:00",
           "tokens": {"input_tokens": 1000, "output_tokens": 200, "cached_input": null},
           "missing_fields": {"input_tokens": 0, "output_tokens": 1, "cached_input": 3},
           "accuracy": {"exact": 2, "estimated": 1, "unknown": 0},
           "coverage": {"observed": 3, "attempts": 5, "missing_recorded": 1, "unassessed": 1},
           "books": {
             "tasks": {\(book(5, "1, 2, 3, 4, 5", "101, 102", nil))},
             "planner": {\(book(1, "6", "null", nil))},
             "controller": {\(book(0, "", "", "ORX-recorded controller attempts only"))},
             "unattributed_within_run": {\(book(1, "7", "101", "never prorated"))}},
           "per_task": [{\(book(2, "1, 2", "101", nil)), "revision_id": 101, "revision": 1, "task_id": "T001"}],
           "per_revision": [{\(book(2, "1, 2", "101", nil)), "revision_id": 101, "revision": 1},
                            {\(book(3, "3, 4, 5", "102", nil)), "revision_id": 102, "revision": 2}],
           "normalized_processing": {"version": 1, "value": 1200, "partial": true,
                                     "rows_derived": 2, "rows_missing": 1,
                                     "cache_semantics": {"cache_subset": 2, "cache_separate": 0, "unknown": 1},
                                     "note": "separate versioned derived volume"},
           "attribution": {"rule": "run attribution via attempts.run_id ONLY"}},
         "native_preview": {
           "caliber": "native_session_preview", "project": "/tmp/projA",
           "run_id": "R001", "snapshot_id": 7,
           "as_of": "2026-10-16T09:59:30+00:00", "as_of_sessions_ms": 1790000000000,
           "linked_attempts": [
             {"attempt_id": 1, "role": "worker", "revision_id": 101, "task_id": "T001",
              "harness": "zcode", "authority": "session_metadata", "confidence": "high",
              "session_id": "sess-1",
              "tree_totals": {"root": "sess-1", "sessions_in_tree": 2, "turns": 10,
                              "input_tokens": 500, "output_tokens": 100,
                              "reasoning_tokens": null, "cache_read": 50, "cache_creation": 5}}],
           "union": {"sessions": ["sess-1", "sess-2"],
                     "tokens": {"turns": 12, "input_tokens": 600, "output_tokens": 120,
                                "reasoning_tokens": 30, "cache_read": 60, "cache_creation": 6}},
           "shared_session_trees": [], "subtree_conflicts": [],
           "controller_sessions": [
             {"session_id": "root-sess",
              "own_usage": {"turns": 2, "input_tokens": 100, "output_tokens": 20,
                            "reasoning_tokens": null, "cache_read": null, "cache_creation": null},
              "run_attribution": {"attributed": true, "runs": ["R001"],
                                  "basis": "parent of sessions linked to attempts"}}],
           "never_sum_with": "orx_recorded",
           "note": "cumulative native-session numbers, a separate caliber"},
         "snapshots": {"/tmp/projA": {"snapshot_id": 7,
                                      "taken_at": "2026-10-16T09:59:30+00:00",
                                      "schema_version": "11", "supported": true,
                                      "source_path": "/tmp/projA/.orx/state.db"}},
         "coverage": {"project": "/tmp/projA", "found": true, "snapshot_id": 7},
         "warnings": []}
        """
        return Data(json.utf8)
    }()

    static let taskDetailJSON: Data = {
        let json = """
        {"op": "tasks.get", "ok": true, "protocol_version": 1,
         "generated_at": "2026-10-16T10:00:00+00:00",
         "project": "/tmp/projA", "run_id": "R001",
         "revision_id": 102, "task_id": "T002", "found": true,
         "task": {
           "identity": {"project": "/tmp/projA", "run_id": "R001",
                        "revision_id": 102, "task_id": "T002"},
           "objective": "修复失败用例",
           "status": {"raw": "failed", "known": true, "display": "失败"},
           "failure_reason": "timeout",
           "created_at": "2026-10-16T09:30:00+00:00",
           "updated_at": "2026-10-16T09:50:00+00:00"},
         "usage": {
           "caliber": "orx_recorded", "project": "/tmp/projA", "run_id": "R001",
           "revision_id": 102, "task_id": "T002", "snapshot_id": 7,
           "as_of": "2026-10-16T09:59:30+00:00",
           "tokens": {"input_tokens": 400, "output_tokens": 80, "cached_input": null},
           "missing_fields": {"input_tokens": 0, "output_tokens": 0, "cached_input": 2},
           "accuracy": {"exact": 1, "estimated": 0, "unknown": 1},
           "coverage": {"observed": 2, "attempts": 3, "missing_recorded": 1, "unassessed": 0},
           "books": {
             "worker": {"attempts": 2, "attempt_ids": [4, 5], "revision_ids": [102],
                        "coverage": {"observed": 2, "attempts": 2, "missing_recorded": 0, "unassessed": 0},
                        "tokens": {"input_tokens": 400, "output_tokens": 80, "cached_input": null},
                        "missing_fields": {"input_tokens": 0, "output_tokens": 0, "cached_input": 2},
                        "accuracy": {"exact": 1, "estimated": 0, "unknown": 1},
                        "as_of": "2026-10-16T09:59:30+00:00"},
             "verifier": {"attempts": 1, "attempt_ids": [9], "revision_ids": [102],
                          "coverage": {"observed": 1, "attempts": 1, "missing_recorded": 0, "unassessed": 0},
                          "tokens": {"input_tokens": 50, "output_tokens": 10, "cached_input": null},
                          "missing_fields": {"input_tokens": 0, "output_tokens": 0, "cached_input": 0},
                          "accuracy": {"exact": 1, "estimated": 0, "unknown": 0},
                          "as_of": "2026-10-16T09:59:30+00:00"}},
           "normalized_processing": {"version": 1, "value": 480, "partial": false,
                                     "rows_derived": 2, "rows_missing": 0,
                                     "cache_semantics": {"cache_subset": 2, "cache_separate": 0, "unknown": 0},
                                     "note": "separate versioned derived volume"},
           "attempts": [
             {"attempt_id": 4, "role": "worker", "revision_id": 102, "task_id": "T002",
              "result": "failed", "failure_reason": "timeout",
              "started_at": "2026-10-16T09:30:00+00:00",
              "ended_at": "2026-10-16T09:40:00+00:00",
              "harness": "zcode", "model": "glm-4.7", "usage_missing_reason": null,
              "observation": {"source": "zcode_db", "accuracy": "exact",
                              "tokens": {"input_tokens": 200, "output_tokens": 40, "cached_input": null}},
              "session_link": {"session_id": "sess-1", "authority": "session_metadata",
                               "confidence": "high"}},
             {"attempt_id": 5, "role": "worker", "revision_id": 102, "task_id": "T002",
              "result": null, "failure_reason": null,
              "started_at": "2026-10-16T09:41:00+00:00", "ended_at": null,
              "harness": "zcode", "model": "glm-4.7",
              "usage_missing_reason": "attempt still running",
              "observation": null},
             {"attempt_id": 9, "role": "verifier", "revision_id": 102, "task_id": "T002",
              "result": "completed", "failure_reason": null,
              "started_at": "2026-10-16T09:45:00+00:00",
              "ended_at": "2026-10-16T09:46:00+00:00",
              "harness": "zcode", "model": "glm-4.7-air", "usage_missing_reason": null,
              "observation": {"source": "native_cli", "accuracy": "exact",
                              "tokens": {"input_tokens": 50, "output_tokens": 10, "cached_input": 0}},
              "session_link": {"session_id": "sess-9", "authority": "session_metadata",
                               "confidence": "high"}}],
           "attribution": {"rule": "task consumption = every attributable attempt"}},
         "verifications": [
           {"id": 1, "attempt_id": 4, "kind": "command", "command": "pytest -q",
            "exit_code": 1, "passed": 0, "created_at": "2026-10-16T09:39:00+00:00"},
           {"id": 2, "attempt_id": 4, "kind": "command", "command": "swift test",
            "exit_code": 0, "passed": 1, "created_at": "2026-10-16T09:39:30+00:00"}],
         "retry": {"recovered": false, "failing_attempt_ids": [4],
                   "successor_attempt_ids": [5]},
         "snapshots": {"/tmp/projA": {"snapshot_id": 7,
                                      "taken_at": "2026-10-16T09:59:30+00:00",
                                      "schema_version": "11", "supported": true,
                                      "source_path": "/tmp/projA/.orx/state.db"}},
         "coverage": {"project": "/tmp/projA", "found": true, "snapshot_id": 7},
         "warnings": []}
        """
        return Data(json.utf8)
    }()
}
