import XCTest
@testable import ORXAnalyticsCore

/// Quick-panel presentation rules (design §3), tested against decoded
/// wire envelopes so the merge logic is proven without a GUI:
///
/// - 同一 Run 只出现一次：a run with attention lives ONLY in 需要关注.
/// - 异常优先排序：the attention section is the first section.
/// - 进度是当前计划的任务分数；消耗是全部版本的已观测量——两个
///   表达分开存在，不合成百分比。
/// - Attention for a run missing from both lists is never dropped.
/// - 数据健康 per project rides along as its own dimension.
final class PanelSectionsTests: XCTestCase {

    func testRunWithAttentionAppearsOnceAndOnlyInAttentionSection() throws {
        let panel = PanelModel.build(try fixture())
        // run /tmp/projA#R001 is active AND has attention; /tmp/projC#R777
        // has attention but is listed nowhere (synthetic card). Both live
        // ONLY in the attention section.
        XCTAssertEqual(panel.needsAttention.count, 2)
        XCTAssertEqual(panel.needsAttention.first?.run.runID, "R001")
        XCTAssertEqual(panel.needsAttention.first?.attention.count, 1)
        XCTAssertFalse(panel.active.contains { $0.run.runID == "R001" },
                       "同一 Run 只出现一次：带关注事项的 Run 不得再出现在进行中区")
        XCTAssertEqual(panel.active.map(\.run.runID), ["R002"])
        XCTAssertEqual(panel.recentCompleted.map(\.run.runID), ["R009"])
    }

    func testAttentionSectionSortsAheadOfActiveAndRecent() throws {
        let panel = PanelModel.build(try fixture())
        // The API exposes the three sections in fixed priority order; the
        // view renders needsAttention first. Assert the model marks it.
        XCTAssertEqual(panel.sectionOrder.first, .needsAttention)
        XCTAssertEqual(panel.sectionOrder, [.needsAttention, .active, .recentCompleted])
    }

    func testAttentionWithoutListedRunStillGetsACard() throws {
        let panel = PanelModel.build(try fixture())
        // /tmp/projC#R777 has attention but is in neither active nor recent
        // (a terminal failed run). It must not vanish from the panel.
        XCTAssertEqual(panel.needsAttention.last?.run.project, "/tmp/projC")
        XCTAssertEqual(panel.needsAttention.last?.run.runID, "R777")
        XCTAssertEqual(panel.needsAttention.last?.attention.first?.kind, "failed_task")
        // its display status is unknown, never guessed terminal
        XCTAssertEqual(panel.needsAttention.last?.run.status.known, false)
    }

    func testProgressAndConsumptionAreSeparateExpressions() throws {
        let panel = PanelModel.build(try fixture())
        let card = panel.active[0]
        // progress = current plan only (revision 2: 1/3), never a percentage
        XCTAssertEqual(card.run.progress?.completed, 1)
        XCTAssertEqual(card.run.progress?.total, 3)
        XCTAssertEqual(card.run.progress?.revision, 2)
        // consumption = observed tokens across ALL revisions, its own field
        XCTAssertEqual(card.run.consumption?.observedTotal, 4200)
        // the card model never fabricates a combined progress-consumption value
        XCTAssertNil(card.combinedProgressConsumption)
    }

    func testRecentCompletedKeepsEntriesAndHealthRidesAlong() throws {
        let panel = PanelModel.build(try fixture())
        XCTAssertEqual(panel.recentCompleted.first?.run.status.display, "完成")
        XCTAssertEqual(panel.health(for: "/tmp/projA")?.health, "更新延迟")
        XCTAssertEqual(panel.health(for: "/tmp/projB")?.health, "正常")
        XCTAssertNil(panel.health(for: "/tmp/unknown"))
    }

    func testEmptyEnvelopeYieldsEmptySections() {
        let empty = PanelModel.build(OverviewEnvelope(
            header: EngineEnvelopeHeader(op: "overview", ok: true,
                                         protocolVersion: 1, generatedAt: nil, error: nil),
            summary: OverviewSummary(activeRuns: 0, attention: 0, recentCompleted: 0,
                                     projects: nil),
            active: [], attention: [], recentCompleted: []))
        XCTAssertTrue(empty.needsAttention.isEmpty)
        XCTAssertTrue(empty.active.isEmpty)
        XCTAssertTrue(empty.recentCompleted.isEmpty)
    }

    // MARK: lifecycle layering (G011 matrix)

    /// The Goal control layer and the Run execution facts travel TOGETHER
    /// on every card — grouping comes from the engine, the badge from
    /// `run.goal.status`; neither dimension rewrites the other.
    func testLifecycleCardsCarryControlLayerBesideExecutionFacts() throws {
        let panel = PanelModel.build(try lifecycleFixture())
        XCTAssertEqual(panel.active.map(\.run.runID), ["R100", "R110"])
        // paused/running: execution fact 执行中, control badge 已暂停
        let paused = panel.active[0]
        XCTAssertEqual(paused.run.status.display, "执行中")
        XCTAssertEqual(paused.controlStatus?.raw, "paused")
        XCTAssertEqual(paused.controlStatus?.display, "已暂停")
        // cancelling keeps the unclosed execution visible with its badge
        let cancelling = panel.active[1]
        XCTAssertEqual(cancelling.run.status.raw, "running")
        XCTAssertEqual(cancelling.controlStatus?.raw, "cancelling")
        XCTAssertEqual(cancelling.controlStatus?.display, "取消中")
        // recent: the run finishing DURING the pause stays recent while
        // its control layer stays paused — never masquerading as goal done
        let recent = panel.recentCompleted.map(\.run.runID)
        XCTAssertEqual(recent, ["R101", "R130"])
        let pausedDone = panel.recentCompleted[0]
        XCTAssertEqual(pausedDone.run.status.display, "完成")
        XCTAssertEqual(pausedDone.controlStatus?.display, "已暂停")
        XCTAssertEqual(panel.recentCompleted[1].controlStatus?.display, "已完成")
        // the status line can summarize the control layer of the active
        // section (runs whose control is plain active add no noise)
        XCTAssertEqual(panel.activeControlCounts.map(\.label), ["已暂停", "取消中"])
        XCTAssertEqual(panel.activeControlCounts.map(\.count), [1, 1])
    }

    /// 分组与汇总不重复计数：a run appears in exactly ONE section and
    /// the summary numbers mirror the section lengths.
    func testLifecycleGroupingNeverDoubleCounts() throws {
        let panel = PanelModel.build(try lifecycleFixture())
        var seen: Set<String> = []
        for card in panel.needsAttention + panel.active + panel.recentCompleted {
            XCTAssertFalse(seen.contains(card.id),
                           "同一 Run 只出现一次：\(card.id)")
            seen.insert(card.id)
        }
    }

    /// 旧字段/缓存兼容：a payload WITHOUT goal blocks (older engine or
    /// legacy cache) still decodes — the control layer is simply absent
    /// and nothing crashes or guesses.
    func testLegacyPayloadWithoutGoalBlocksStillDecodes() throws {
        let json = """
        {"op": "overview", "ok": true, "protocol_version": 1,
         "generated_at": "2026-10-16T10:00:00+00:00",
         "summary": {"active_runs": 1, "attention": 0, "recent_completed": 0},
         "active": [
           {"project": "/tmp/projA", "run_id": "R900",
            "status": {"raw": "running", "known": true, "display": "执行中"},
            "started_at": "2026-10-16T09:00:00+00:00"}],
         "attention": [
           {"kind": "blocked_run", "project": "/tmp/projA", "run_id": "R901",
            "detail": "run blocked"}],
         "recent_completed": [],
         "project_health": [], "snapshots": {}, "coverage": {}, "warnings": []}
        """
        let envelope = try JSONDecoder().decode(OverviewEnvelope.self,
                                                from: Data(json.utf8))
        let panel = PanelModel.build(envelope)
        XCTAssertEqual(panel.active.map(\.run.runID), ["R900"])
        XCTAssertNil(panel.active[0].controlStatus,
                     "无 goal 块：控制层缺省，不猜")
        XCTAssertTrue(panel.activeControlCounts.isEmpty)
        // the attention item without evidence/goal fields still renders a
        // synthetic card (attention facts are never dropped)
        XCTAssertEqual(panel.needsAttention.first?.attention.first?.kind,
                       "blocked_run")
    }

    private func lifecycleFixture() throws -> OverviewEnvelope {
        let json = """
        {"op": "overview", "ok": true, "protocol_version": 1,
         "generated_at": "2026-10-16T10:00:00+00:00",
         "summary": {"active_runs": 2, "attention": 0, "recent_completed": 2,
                     "projects": {"considered": 1, "queried": 1, "excluded": []}},
         "active": [
           {"project": "/tmp/projL", "run_id": "R100",
            "goal": {"id": "G100", "objective": "暂停目标",
                     "status": {"raw": "paused", "known": true, "display": "已暂停"}},
            "status": {"raw": "running", "known": true, "display": "执行中"},
            "started_at": "2026-10-16T09:00:00+00:00",
            "progress": {"completed": 1, "total": 3, "revision_id": 50, "revision": 1,
                         "basis": "current revision only"},
            "consumption": {"caliber": "orx_recorded",
                            "tokens": {"input_tokens": 900, "output_tokens": 100, "cached_input": null},
                            "observed_total": 1000,
                            "coverage": {"observed": 1, "attempts": 2,
                                         "missing_recorded": 1, "unassessed": 0}},
            "data_as_of": "2026-10-16T09:59:00+00:00"},
           {"project": "/tmp/projL", "run_id": "R110",
            "goal": {"id": "G101", "objective": "取消中目标",
                     "status": {"raw": "cancelling", "known": true, "display": "取消中"}},
            "status": {"raw": "running", "known": true, "display": "执行中"},
            "started_at": "2026-10-16T09:10:00+00:00",
            "progress": {"completed": 0, "total": 2, "revision_id": 52, "revision": 1,
                         "basis": "current revision only"},
            "consumption": {"caliber": "orx_recorded",
                            "tokens": {"input_tokens": 4000, "output_tokens": 200, "cached_input": 50},
                            "observed_total": 4200,
                            "coverage": {"observed": 3, "attempts": 3,
                                         "missing_recorded": 0, "unassessed": 0}},
            "data_as_of": "2026-10-16T09:59:00+00:00"}],
         "attention": [],
         "recent_completed": [
           {"project": "/tmp/projL", "run_id": "R101",
            "goal": {"id": "G100", "objective": "暂停目标",
                     "status": {"raw": "paused", "known": true, "display": "已暂停"}},
            "status": {"raw": "done", "known": true, "display": "完成"},
            "started_at": "2026-10-16T08:00:00+00:00",
            "completed_at": "2026-10-16T08:40:00+00:00",
            "progress": {"completed": 4, "total": 4, "revision_id": 51, "revision": 1,
                         "basis": "current revision only"},
            "consumption": {"caliber": "orx_recorded",
                            "tokens": {"input_tokens": 500, "output_tokens": 80, "cached_input": null},
                            "observed_total": 580,
                            "coverage": {"observed": 2, "attempts": 2,
                                         "missing_recorded": 0, "unassessed": 0}},
            "data_as_of": "2026-10-16T09:59:00+00:00"},
           {"project": "/tmp/projL", "run_id": "R130",
            "goal": {"id": "G103", "objective": "已完成目标",
                     "status": {"raw": "done", "known": true, "display": "已完成"}},
            "status": {"raw": "done", "known": true, "display": "完成"},
            "started_at": "2026-10-15T09:00:00+00:00",
            "completed_at": "2026-10-15T12:00:00+00:00",
            "progress": {"completed": 3, "total": 3, "revision_id": 56, "revision": 1,
                         "basis": "current revision only"},
            "consumption": {"caliber": "orx_recorded",
                            "tokens": {"input_tokens": 300, "output_tokens": 30, "cached_input": null},
                            "observed_total": 330,
                            "coverage": {"observed": 1, "attempts": 1,
                                         "missing_recorded": 0, "unassessed": 0}},
            "data_as_of": "2026-10-16T09:59:00+00:00"}],
         "project_health": [
           {"project": "/tmp/projL",
            "data_health": {"health": "正常", "source_readable": true,
                            "schema_supported": true, "stale": false},
            "snapshot_id": 9, "taken_at": "2026-10-16T09:59:00+00:00"}],
         "snapshots": {}, "coverage": {}, "warnings": []}
        """
        do {
            return try JSONDecoder().decode(OverviewEnvelope.self, from: Data(json.utf8))
        } catch {
            fatalError("lifecycle fixture decode failed: \(error)")
        }
    }

    // MARK: fixture

    private func fixture() throws -> OverviewEnvelope {
        let json = """
        {"op": "overview", "ok": true, "protocol_version": 1,
         "generated_at": "2026-10-16T10:00:00+00:00",
         "summary": {"active_runs": 2, "attention": 2, "recent_completed": 1,
                     "projects": {"considered": 3, "queried": 3, "excluded": []}},
         "active": [
           {"project": "/tmp/projA", "run_id": "R001",
            "goal": {"id": "G1", "objective": "带关注的目标",
                     "status": {"raw": "active", "known": true, "display": "进行中"}},
            "status": {"raw": "running", "known": true, "display": "执行中"},
            "started_at": "2026-10-16T09:00:00+00:00",
            "progress": {"completed": 2, "total": 5, "revision_id": 102, "revision": 2,
                         "basis": "current revision only"},
            "consumption": {"caliber": "orx_recorded",
                            "tokens": {"input_tokens": 900, "output_tokens": 100, "cached_input": null},
                            "observed_total": 1000,
                            "missing_fields": {"input_tokens": 0, "output_tokens": 0, "cached_input": 1},
                            "accuracy": {"exact": 1, "estimated": 0, "unknown": 0},
                            "coverage": {"observed": 1, "attempts": 2, "missing_recorded": 1, "unassessed": 0}},
            "data_as_of": "2026-10-16T09:59:00+00:00"},
           {"project": "/tmp/projB", "run_id": "R002",
            "goal": {"id": "G2", "objective": "健康执行",
                     "status": {"raw": "active", "known": true, "display": "进行中"}},
            "status": {"raw": "running", "known": true, "display": "执行中"},
            "started_at": "2026-10-16T09:10:00+00:00",
            "progress": {"completed": 1, "total": 3, "revision_id": 201, "revision": 2,
                         "basis": "current revision only"},
            "consumption": {"caliber": "orx_recorded",
                            "tokens": {"input_tokens": 4000, "output_tokens": 200, "cached_input": 50},
                            "observed_total": 4200,
                            "missing_fields": {"input_tokens": 0, "output_tokens": 0, "cached_input": 0},
                            "accuracy": {"exact": 3, "estimated": 0, "unknown": 0},
                            "coverage": {"observed": 3, "attempts": 3, "missing_recorded": 0, "unassessed": 0}},
            "data_as_of": "2026-10-16T09:59:00+00:00"}],
         "attention": [
           {"kind": "failed_task", "project": "/tmp/projA", "run_id": "R001",
            "revision_id": 102, "task_id": "T003", "detail": "超时失败",
            "evidence": {"failing_attempt_ids": [4], "successor_attempt_ids": [],
                         "recovered": false}},
           {"kind": "failed_task", "project": "/tmp/projC", "run_id": "R777",
            "revision_id": 301, "task_id": "T001", "detail": "旧失败执行"}],
         "recent_completed": [
           {"project": "/tmp/projA", "run_id": "R009",
            "goal": {"id": "G1", "objective": "已完成的目标",
                     "status": {"raw": "done", "known": true, "display": "已完成"}},
            "status": {"raw": "done", "known": true, "display": "完成"},
            "started_at": "2026-10-15T09:00:00+00:00",
            "completed_at": "2026-10-15T12:00:00+00:00",
            "progress": {"completed": 4, "total": 4, "revision_id": 90, "revision": 1,
                         "basis": "current revision only"},
            "consumption": {"caliber": "orx_recorded",
                            "tokens": {"input_tokens": 500, "output_tokens": 80, "cached_input": null},
                            "observed_total": 580,
                            "missing_fields": {"input_tokens": 0, "output_tokens": 0, "cached_input": 0},
                            "accuracy": {"exact": 2, "estimated": 0, "unknown": 0},
                            "coverage": {"observed": 2, "attempts": 2, "missing_recorded": 0, "unassessed": 0}},
            "data_as_of": "2026-10-16T08:00:00+00:00"}],
         "project_health": [
           {"project": "/tmp/projA",
            "data_health": {"health": "更新延迟", "source_readable": true,
                            "schema_supported": true, "stale": true},
            "snapshot_id": 7, "taken_at": "2026-10-15T08:00:00+00:00"},
           {"project": "/tmp/projB",
            "data_health": {"health": "正常", "source_readable": true,
                            "schema_supported": true, "stale": false},
            "snapshot_id": 8, "taken_at": "2026-10-16T09:59:00+00:00"}],
         "snapshots": {}, "coverage": {}, "warnings": []}
        """
        do {
            return try JSONDecoder().decode(OverviewEnvelope.self, from: Data(json.utf8))
        } catch {
            fatalError("fixture decode failed: \(error)")
        }
    }
}
