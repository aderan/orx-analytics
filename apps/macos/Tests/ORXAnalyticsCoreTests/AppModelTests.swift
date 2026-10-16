import XCTest
@testable import ORXAnalyticsCore

/// A controllable fake engine for AppModel tests: injectable latency,
/// outcomes and errors. Never touches a real socket.
final class FakeEngineClient: EngineClientProtocol {
    var latency: TimeInterval = 0
    var negotiateOutcome: NegotiationOutcome = .compatible(engineVersion: 1)
    var overviewEnvelope: OverviewEnvelope?
    var overviewError: EngineFailure?
    var refreshError: EngineFailure?

    private let lock = NSLock()
    private(set) var negotiateCount = 0
    private(set) var fetchCount = 0
    private(set) var refreshReasons: [String] = []

    private func nap() {
        if latency > 0 { Thread.sleep(forTimeInterval: latency) }
    }

    func negotiate() -> NegotiationOutcome {
        lock.lock(); negotiateCount += 1; lock.unlock()
        nap()
        return negotiateOutcome
    }

    func fetchOverview() throws -> OverviewEnvelope {
        lock.lock(); fetchCount += 1; lock.unlock()
        nap()
        if let overviewError { throw overviewError }
        return overviewEnvelope ?? Self.fixture(activeRuns: 0, attention: 0)
    }

    func requestRefresh(reason: String) throws -> RefreshAccepted {
        lock.lock(); refreshReasons.append(reason); lock.unlock()
        nap()
        if let refreshError { throw refreshError }
        return RefreshAccepted(jobID: "job-1")
    }

    // Detail ops (T009): the fake serves simulator-shaped payloads so
    // AppModel-driven windows can drill in without a live engine.
    func fetchRunDetail(project: String, runID: String) throws -> RunDetailEnvelope {
        nap()
        let data = EngineSimulator.encode(
            EngineSimulator.runDetailResponse(project: project, runID: runID))
        do {
            return try JSONDecoder().decode(RunDetailEnvelope.self, from: data)
        } catch {
            throw EngineFailure.invalidResponse("fake run detail: \(error)")
        }
    }

    func fetchTaskDetail(project: String, runID: String, revisionID: Int,
                         taskID: String) throws -> TaskDetailEnvelope {
        nap()
        let data = EngineSimulator.encode(
            EngineSimulator.taskDetailResponse(project: project, runID: runID,
                                               revisionID: revisionID,
                                               taskID: taskID))
        do {
            return try JSONDecoder().decode(TaskDetailEnvelope.self, from: data)
        } catch {
            throw EngineFailure.invalidResponse("fake task detail: \(error)")
        }
    }

    // History ops (T010): simulator-shaped canned payloads so the
    // AppModel-owned HistoryModel works without a live engine.
    func fetchRunsList(query: RunsListQuery) throws -> RunsListEnvelope {
        nap()
        let data = EngineSimulator.encode(EngineSimulator.runsListResponse())
        do {
            return try JSONDecoder().decode(RunsListEnvelope.self, from: data)
        } catch {
            throw EngineFailure.invalidResponse("fake runs list: \(error)")
        }
    }

    func fetchProjectsList(limit: Int) throws -> ProjectsListEnvelope {
        nap()
        let data = EngineSimulator.encode(EngineSimulator.projectsListResponse())
        do {
            return try JSONDecoder().decode(ProjectsListEnvelope.self, from: data)
        } catch {
            throw EngineFailure.invalidResponse("fake projects list: \(error)")
        }
    }

    static func fixture(activeRuns: Int, attention: Int,
                        recentCompleted: Int = 0) -> OverviewEnvelope {
        let data = EngineSimulator.encode(
            EngineSimulator.overviewResponse(activeRuns: activeRuns,
                                             attention: attention,
                                             recentCompleted: recentCompleted))
        do {
            return try JSONDecoder().decode(OverviewEnvelope.self, from: data)
        } catch {
            fatalError("fixture decode failed: \(error)")
        }
    }
}

/// Cache-first behavior of the app model (design §3: 打开面板先展示缓存，
/// 再异步刷新；刷新不阻塞主线程).
@MainActor
final class AppModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orx-appmodel-tests-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func seedCache(active: Int, attention: Int) -> OverviewCacheStore {
        let store = OverviewCacheStore(directory: directory)
        store.save(CachedOverview(
            envelope: FakeEngineClient.fixture(activeRuns: active, attention: attention),
            cachedAt: Date(timeIntervalSinceNow: -120)))
        return store
    }

    // MARK: cache-first

    func testBootstrapPublishesCacheSynchronouslyBeforeRefreshCompletes() {
        let cache = seedCache(active: 5, attention: 0)
        let fake = FakeEngineClient()
        fake.latency = 0.5   // a refresh round clearly slower than the assert
        fake.overviewEnvelope = FakeEngineClient.fixture(activeRuns: 2, attention: 0)
        let model = AppModel(client: fake, cache: cache)

        model.bootstrap()

        // The panel opens showing the CACHE immediately — the in-flight
        // refresh must not gate the first render.
        XCTAssertEqual(model.cachedOverview?.envelope.summary.activeRuns, 5)
        XCTAssertEqual(model.activeRunCount, 5)
    }

    func testRefreshUpdatesFromEngineAndPersistsToCache() async {
        let cache = seedCache(active: 5, attention: 0)
        let fake = FakeEngineClient()
        fake.overviewEnvelope = FakeEngineClient.fixture(activeRuns: 2, attention: 1)
        let model = AppModel(client: fake, cache: cache)
        model.bootstrap()
        await model.refresh(reason: "panel-open")

        XCTAssertEqual(model.activeRunCount, 2)
        XCTAssertEqual(model.attentionCount, 1)
        XCTAssertEqual(model.connection, .ready(engineVersion: 1))
        XCTAssertNotNil(model.lastRefreshedAt)
        XCTAssertNil(model.lastFailureText)
        XCTAssertEqual(cache.load()?.envelope.summary.activeRuns, 2,
                       "successful refresh persists to the display cache")
        XCTAssertTrue(fake.refreshReasons.contains("panel-open"))
    }

    func testFailedRefreshKeepsLastGoodCacheDisplayed() async {
        let cache = seedCache(active: 7, attention: 0)
        let fake = FakeEngineClient()
        fake.overviewError = .unreachable("engine died mid-round")
        let model = AppModel(client: fake, cache: cache)
        model.bootstrap()
        await model.refresh(reason: "panel-open")

        XCTAssertEqual(model.activeRunCount, 7,
                       "failed round keeps the last successful data displayed")
        XCTAssertNotNil(model.lastFailureText)
        guard case .notRunning = model.connection else {
            return XCTFail("expected .notRunning after unreachable refresh, got \(model.connection)")
        }
        XCTAssertEqual(cache.load()?.envelope.summary.activeRuns, 7,
                       "failures never overwrite the cache")
    }

    // MARK: coalescing

    func testConcurrentRefreshCallsCoalesceIntoOneRound() async {
        let cache = OverviewCacheStore(directory: directory)
        let fake = FakeEngineClient()
        fake.latency = 0.25
        fake.overviewEnvelope = FakeEngineClient.fixture(activeRuns: 1, attention: 0)
        let model = AppModel(client: fake, cache: cache)

        async let first: Void = model.refresh(reason: "panel-open")
        async let second: Void = model.refresh(reason: "panel-open")
        _ = await (first, second)

        XCTAssertEqual(fake.negotiateCount, 1,
                       "多个刷新请求合并 — no second engine round for an in-flight one")
        XCTAssertEqual(model.activeRunCount, 1)
    }

    // MARK: badge semantics

    func testBadgeCountsOnlyActiveRunsNeverAttentionOrTasks() async {
        let cache = OverviewCacheStore(directory: directory)
        let fake = FakeEngineClient()
        // 3 active runs, 9 attention items, 4 recent — the badge is 3.
        fake.overviewEnvelope = FakeEngineClient.fixture(activeRuns: 3, attention: 9,
                                                         recentCompleted: 4)
        let model = AppModel(client: fake, cache: cache)
        await model.refresh(reason: "manual")
        XCTAssertEqual(model.activeRunCount, 3)
        XCTAssertEqual(model.attentionCount, 9)
    }

    // MARK: incompatibility handling

    func testIncompatibleEngineStopsQueryingAndReportsVersions() async {
        let cache = seedCache(active: 4, attention: 0)
        let fake = FakeEngineClient()
        fake.negotiateOutcome = .incompatible(requested: 1, supported: 99)
        let model = AppModel(client: fake, cache: cache)
        model.bootstrap()
        await model.refresh(reason: "panel-open")

        XCTAssertEqual(model.connection, .incompatible(requested: 1, supported: 99))
        XCTAssertEqual(fake.fetchCount, 0,
                       "incompatible engine: overview is never queried")
        XCTAssertEqual(model.activeRunCount, 4,
                       "cache stays displayed under an explicit incompatibility report")
        XCTAssertNotNil(model.lastFailureText)
        XCTAssertTrue(model.lastFailureText?.contains("v99") ?? false)
    }

    // MARK: explicit cache clear

    func testClearDisplayCacheIsExplicit() async {
        let cache = seedCache(active: 2, attention: 0)
        let fake = FakeEngineClient()
        let model = AppModel(client: fake, cache: cache)
        model.bootstrap()
        await model.refresh(reason: "panel-open")
        XCTAssertNotNil(model.cachedOverview)

        model.clearDisplayCache()
        XCTAssertNil(model.cachedOverview)
        XCTAssertNil(cache.load())
    }
}
