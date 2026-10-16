import XCTest
@testable import ORXAnalyticsCore

/// Run/task detail loader behavior (design §3/§4/§5/§8):
/// cache-free but failure-tolerant detail loads, task drill-down, and the
/// presentation derivations that must stay honest (retry wording, model
/// distribution by COUNT only, three-dimension status separation).
@MainActor
final class RunDetailModelTests: XCTestCase {

    private var client: FakeDetailClient!

    override func setUp() {
        super.setUp()
        client = FakeDetailClient()
    }

    // MARK: loads

    func testLoadFetchesRunDetailOffTheMainThread() async throws {
        client.runDetail = Self.fixtureRunDetail()
        let model = RunDetailModel(client: client,
                                   identity: RunIdentity(project: "/tmp/projA",
                                                         runID: "R001"))
        await model.load()
        let detail = try XCTUnwrap(model.detail)
        XCTAssertTrue(detail.found)
        XCTAssertEqual(model.lastFailureText, nil)
        XCTAssertNotNil(model.lastLoadedAt)
        // 刷新不阻塞界面：the engine IO must never run on the main thread
        XCTAssertFalse(client.sawMainThreadDuringFetch,
                       "engine fetches must hop off the main actor")
    }

    func testLoadFailureKeepsLastSuccessfulDataWithReason() async throws {
        client.runDetail = Self.fixtureRunDetail()
        let model = RunDetailModel(client: client,
                                   identity: RunIdentity(project: "/tmp/projA",
                                                         runID: "R001"))
        await model.load()
        let first = try XCTUnwrap(model.detail)

        client.runDetailError = .unreachable("socket closed")
        await model.refresh()
        XCTAssertEqual(model.detail, first,
                       "失败保留最后成功数据（design §8）")
        XCTAssertNotNil(model.lastFailureText)
        XCTAssertTrue(model.lastFailureText?.contains("引擎连接失败") == true)
    }

    func testConcurrentLoadsCoalesceIntoOneRequest() async throws {
        client.runDetail = Self.fixtureRunDetail()
        client.latency = 0.15
        let model = RunDetailModel(client: client,
                                   identity: RunIdentity(project: "/tmp/projA",
                                                         runID: "R001"))
        async let a: Void = model.load()
        async let b: Void = model.load()
        _ = await (a, b)
        XCTAssertEqual(client.runFetchCount, 1, "刷新请求合并，不重复请求")
    }

    // MARK: task drill-down

    func testSelectTaskFetchesTaskDetailWithStableIdentity() async throws {
        client.runDetail = Self.fixtureRunDetail()
        client.taskDetail = Self.fixtureTaskDetail()
        let model = RunDetailModel(client: client,
                                   identity: RunIdentity(project: "/tmp/projA",
                                                         runID: "R001"))
        await model.load()
        let task = try XCTUnwrap(model.detail?.tasks.last)
        await model.select(task: task)
        XCTAssertEqual(model.selectedTask?.revisionID, 102)
        XCTAssertEqual(model.selectedTask?.taskID, "T002")
        XCTAssertEqual(client.lastTaskParams?.revisionID, 102,
                       "Task 身份 = Project+Run+Revision+task_id，短编号不作键")
        XCTAssertEqual(client.lastTaskParams?.taskID, "T002")
        XCTAssertNotNil(model.taskDetail)
    }

    func testTaskLoadFailureKeepsLastTaskDataAndReportsReason() async throws {
        client.runDetail = Self.fixtureRunDetail()
        client.taskDetail = Self.fixtureTaskDetail()
        let model = RunDetailModel(client: client,
                                   identity: RunIdentity(project: "/tmp/projA",
                                                         runID: "R001"))
        await model.load()
        let task = try XCTUnwrap(model.detail?.tasks.last)
        await model.select(task: task)
        let first = try XCTUnwrap(model.taskDetail)

        client.taskDetailError = .refused(code: "invalid_request", message: "boom")
        let again = model.detail?.tasks.last
        await model.select(task: try XCTUnwrap(again))
        XCTAssertEqual(model.taskDetail, first)
        XCTAssertNotNil(model.taskFailureText)
    }

    // MARK: honest derivations

    func testRetryWordingDistinguishesRetryingRecoveredAndPlainFailure() {
        XCTAssertEqual(RetryDisplay.text(RetrySummary(recovered: false,
                                                      failingAttemptIDs: [4],
                                                      successorAttemptIDs: [5])),
                       "重试中")
        XCTAssertEqual(RetryDisplay.text(RetrySummary(recovered: true,
                                                      failingAttemptIDs: [4],
                                                      successorAttemptIDs: [5])),
                       "已恢复（后续尝试已接替）")
        XCTAssertEqual(RetryDisplay.text(RetrySummary(recovered: false,
                                                      failingAttemptIDs: [4],
                                                      successorAttemptIDs: [])),
                       "失败待重试")
        XCTAssertEqual(RetryDisplay.text(nil), "—")
    }

    func testModelDistributionCountsAttemptsOnlyNeverTokens() {
        let attempts = [
            AttemptDetail(attemptID: 1, role: "worker", revisionID: 1, taskID: "T1",
                          result: "completed", failureReason: nil, startedAt: nil,
                          endedAt: nil, harness: "zcode", model: "glm-4.7",
                          usageMissingReason: nil, observation: nil, sessionLink: nil),
            AttemptDetail(attemptID: 2, role: "worker", revisionID: 1, taskID: "T1",
                          result: "failed", failureReason: nil, startedAt: nil,
                          endedAt: nil, harness: "zcode", model: "glm-4.7",
                          usageMissingReason: nil, observation: nil, sessionLink: nil),
            AttemptDetail(attemptID: 3, role: "verifier", revisionID: 1, taskID: "T1",
                          result: "completed", failureReason: nil, startedAt: nil,
                          endedAt: nil, harness: "zcode", model: "glm-4.7-air",
                          usageMissingReason: nil, observation: nil, sessionLink: nil),
            AttemptDetail(attemptID: 4, role: "worker", revisionID: 1, taskID: "T1",
                          result: nil, failureReason: nil, startedAt: nil,
                          endedAt: nil, harness: "zcode", model: nil,
                          usageMissingReason: "still running", observation: nil,
                          sessionLink: nil),
        ]
        let dist = ModelDistribution(attempts: attempts)
        XCTAssertEqual(dist.entries.map(\.model), ["glm-4.7", "glm-4.7-air", "未知模型"])
        XCTAssertEqual(dist.entries.map(\.attempts), [2, 1, 1])
        // Counting only: the entry type has no token field at all.
        XCTAssertEqual(dist.entries.first?.attempts, 2)
    }

    func testRunDimensionsKeepTheThreeAxesSeparate() throws {
        let run = try XCTUnwrap(Self.fixtureRunDetail().run)
        let tasks = Self.fixtureRunDetail().tasks
        let snapshots = Self.fixtureRunDetail().snapshots
        // unknown raw status stays unknown — never guessed terminal;
        // attention is a SEPARATE axis and still counts current failures
        let unknownRun = RunFacts(project: "/tmp/projA", runID: "R001",
                                  goal: nil,
                                  status: DisplayStatus(raw: "hibernating",
                                                        known: false,
                                                        display: "未知状态"),
                                  startedAt: nil, completedAt: nil, updatedAt: nil,
                                  createdAt: nil, timeBasis: nil,
                                  progress: ProgressBlock(completed: 2, total: 5,
                                                          revisionID: 102, revision: 2),
                                  consumption: nil, dataAsOf: nil, schemaVersion: nil)
        var unsupported = snapshots
        unsupported["/tmp/projA"] = SnapshotView(snapshotID: 7, takenAt: nil,
                                                 schemaVersion: "99",
                                                 supported: false, sourcePath: nil)
        let dims = RunDimensions.build(run: unknownRun, tasks: tasks,
                                       health: nil, snapshots: unsupported,
                                       project: "/tmp/projA")
        XCTAssertEqual(dims.executionStatus, "未知状态")
        XCTAssertEqual(dims.attentionSummary, "当前计划失败任务 1")
        XCTAssertEqual(dims.dataHealth, "版本不支持")

        // no current plan at all -> attention stays honestly unknown
        let noPlanRun = RunFacts(project: "/tmp/projA", runID: "R001", goal: nil,
                                 status: DisplayStatus(raw: "running", known: true,
                                                       display: "执行中"),
                                 startedAt: nil, completedAt: nil, updatedAt: nil,
                                 createdAt: nil, timeBasis: nil, progress: nil,
                                 consumption: nil, dataAsOf: nil, schemaVersion: nil)
        let noPlan = RunDimensions.build(run: noPlanRun, tasks: tasks,
                                         health: nil, snapshots: [:],
                                         project: "/tmp/projA")
        XCTAssertEqual(noPlan.attentionSummary, "当前计划未知")

        let healthy = DataHealthBlock(health: "更新延迟", sourceReadable: true,
                                      schemaSupported: true, stale: true)
        let dims2 = RunDimensions.build(run: run, tasks: [], health: healthy,
                                        snapshots: snapshots, project: "/tmp/projA")
        XCTAssertEqual(dims2.executionStatus, "执行中")
        XCTAssertEqual(dims2.attentionSummary, "无当前失败任务")
        XCTAssertEqual(dims2.dataHealth, "更新延迟")

        let dims3 = RunDimensions.build(run: run, tasks: [], health: nil,
                                        snapshots: [:], project: "/tmp/projA")
        XCTAssertEqual(dims3.dataHealth, "未知")
    }

    // MARK: fixtures

    nonisolated static func fixtureRunDetail() -> RunDetailEnvelope {
        let data = DetailModelsTests.runDetailJSON
        do {
            return try JSONDecoder().decode(RunDetailEnvelope.self, from: data)
        } catch {
            fatalError("run detail fixture decode failed: \(error)")
        }
    }

    nonisolated static func fixtureTaskDetail() -> TaskDetailEnvelope {
        let data = DetailModelsTests.taskDetailJSON
        do {
            return try JSONDecoder().decode(TaskDetailEnvelope.self, from: data)
        } catch {
            fatalError("task detail fixture decode failed: \(error)")
        }
    }
}

/// Injectable engine for detail-model tests. Records fetch metadata so
/// tests can assert params, coalescing and thread placement.
final class FakeDetailClient: EngineClientProtocol {
    var latency: TimeInterval = 0
    var runDetail: RunDetailEnvelope?
    var runDetailError: EngineFailure?
    var taskDetail: TaskDetailEnvelope?
    var taskDetailError: EngineFailure?
    struct TaskParams { let project: String; let runID: String; let revisionID: Int; let taskID: String }
    private(set) var lastTaskParams: TaskParams?
    private(set) var runFetchCount = 0
    private(set) var taskFetchCount = 0
    private(set) var sawMainThreadDuringFetch = false
    private let lock = NSLock()

    private func nap() {
        if latency > 0 { Thread.sleep(forTimeInterval: latency) }
    }

    func negotiate() -> NegotiationOutcome { .compatible(engineVersion: 1) }

    func fetchOverview() throws -> OverviewEnvelope {
        throw EngineFailure.refused(code: "test", message: "not used")
    }

    func requestRefresh(reason: String) throws -> RefreshAccepted {
        RefreshAccepted(jobID: "job-1")
    }

    func fetchRunDetail(project: String, runID: String) throws -> RunDetailEnvelope {
        lock.lock(); runFetchCount += 1; lock.unlock()
        sawMainThreadDuringFetch = sawMainThreadDuringFetch || Thread.isMainThread
        nap()
        if let runDetailError { throw runDetailError }
        return runDetail ?? RunDetailModelTests.fixtureRunDetail()
    }

    func fetchTaskDetail(project: String, runID: String, revisionID: Int,
                         taskID: String) throws -> TaskDetailEnvelope {
        lock.lock()
        taskFetchCount += 1
        lastTaskParams = TaskParams(project: project, runID: runID,
                                    revisionID: revisionID, taskID: taskID)
        lock.unlock()
        sawMainThreadDuringFetch = sawMainThreadDuringFetch || Thread.isMainThread
        nap()
        if let taskDetailError { throw taskDetailError }
        return taskDetail ?? RunDetailModelTests.fixtureTaskDetail()
    }

    // History ops (T010) — not exercised by detail tests; canned so the
    // conformance stays complete.
    func fetchRunsList(query: RunsListQuery) throws -> RunsListEnvelope {
        sawMainThreadDuringFetch = sawMainThreadDuringFetch || Thread.isMainThread
        let data = EngineSimulator.encode(EngineSimulator.runsListResponse())
        do {
            return try JSONDecoder().decode(RunsListEnvelope.self, from: data)
        } catch {
            throw EngineFailure.invalidResponse("fake runs list: \(error)")
        }
    }

    func fetchProjectsList(limit: Int) throws -> ProjectsListEnvelope {
        sawMainThreadDuringFetch = sawMainThreadDuringFetch || Thread.isMainThread
        let data = EngineSimulator.encode(EngineSimulator.projectsListResponse())
        do {
            return try JSONDecoder().decode(ProjectsListEnvelope.self, from: data)
        } catch {
            throw EngineFailure.invalidResponse("fake projects list: \(error)")
        }
    }
}
