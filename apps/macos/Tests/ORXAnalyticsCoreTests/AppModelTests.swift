import XCTest
@testable import ORXAnalyticsCore

/// Recording spy for the notification surface (CONTRIBUTING: 测试不弹
/// 真实系统通知 — no UNUserNotificationCenter anywhere in tests).
final class SpyNotifier: NotificationPosting {
    var authorized: Bool
    private(set) var authorizationRequests = 0
    private(set) var posts: [AttentionNotification] = []

    init(authorized: Bool = true) { self.authorized = authorized }

    func systemAuthorizationStatus() async -> NotificationAuthState {
        authorized ? .granted : .denied
    }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return authorized
    }

    func post(_ notification: AttentionNotification) async {
        posts.append(notification)
    }
}

/// A controllable fake engine for AppModel tests: injectable latency,
/// outcomes and errors. Never touches a real socket.
final class FakeEngineClient: EngineClientProtocol {    var latency: TimeInterval = 0
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

    // MARK: T011 — settings (design §8/§9)

    func testSettingsDefaultToConservativeValuesWithoutStore() {
        let model = AppModel(client: FakeEngineClient(),
                             cache: OverviewCacheStore(directory: directory))
        XCTAssertFalse(model.settings.notificationsEnabled,
                       "通知默认关闭")
        XCTAssertNil(model.settings.dataDirectoryOverride)
        XCTAssertEqual(model.settings.panelRefreshInterval, 5)
    }

    func testSettingMutationsPersistThroughTheStore() {
        let store = InMemoryAppSettingsStore()
        let model = AppModel(client: FakeEngineClient(),
                             cache: OverviewCacheStore(directory: directory),
                             settingsStore: store)
        model.setPanelRefreshInterval(30)
        model.setDataDirectoryOverride("/tmp/custom-data")
        let saved = store.load()
        XCTAssertEqual(saved.panelRefreshInterval, 30)
        XCTAssertEqual(saved.dataDirectoryOverride, "/tmp/custom-data")
        XCTAssertEqual(saved.resolvedSocketPath(environment: [:]),
                       "/tmp/custom-data/engine.sock")
        // clearing the override restores the default resolution
        model.setDataDirectoryOverride(nil)
        XCTAssertNil(store.load().dataDirectoryOverride)
    }

    // MARK: T011 — notification enable/disable (permission only on opt-in)

    func testEnableNotificationsRequiresAndRecordsAuthorization() async {
        let denied = SpyNotifier(authorized: false)
        let model = AppModel(client: FakeEngineClient(),
                             cache: OverviewCacheStore(directory: directory),
                             notifications: denied)
        await model.enableNotifications()
        XCTAssertEqual(denied.authorizationRequests, 1,
                       "开启后才向系统申请权限")
        XCTAssertFalse(model.settings.notificationsEnabled,
                       "denied authorization keeps notifications off")
        XCTAssertEqual(model.notificationAuth, .denied)

        denied.authorized = true
        await model.enableNotifications()
        XCTAssertTrue(model.settings.notificationsEnabled)
        XCTAssertEqual(model.notificationAuth, .granted)

        model.disableNotifications()
        XCTAssertFalse(model.settings.notificationsEnabled,
                       "用户关闭后立即停用")
    }

    // MARK: T011 — notification emission (dedup / merge / recovery)

    private func envelope(attention: [AttentionItem]) -> OverviewEnvelope {
        OverviewEnvelope(
            header: EngineEnvelopeHeader(op: "overview", ok: true,
                                         protocolVersion: 1, generatedAt: nil,
                                         error: nil),
            summary: OverviewSummary(activeRuns: 0, attention: attention.count,
                                     recentCompleted: 0),
            active: [], attention: attention, recentCompleted: [],
            projectHealth: [], snapshots: [:], warnings: [])
    }

    private func attention(_ ids: [Int], kind: String = "failed_task") -> [AttentionItem] {
        ids.map { AttentionItem(kind: kind, project: "/tmp/p\($0)", runID: "R001",
                                taskID: "T00\($0)", revisionID: 101, detail: "d\($0)") }
    }

    func testNotificationFlowBaselineDedupMergeRecovery() async {
        let spy = SpyNotifier()
        let fake = FakeEngineClient()
        let model = AppModel(client: fake,
                             cache: OverviewCacheStore(directory: directory),
                             notifications: spy)
        await model.enableNotifications()
        XCTAssertTrue(model.settings.notificationsEnabled)

        // baseline: current anomalies are panel content, no burst
        fake.overviewEnvelope = envelope(attention: attention([1]))
        await model.refresh(reason: "manual")
        XCTAssertEqual(spy.posts.count, 0)

        // same anomaly persists — deduped
        await model.refresh(reason: "manual")
        XCTAssertEqual(spy.posts.count, 0, "相同异常去重")

        // two NEW anomalies in one round — ONE merged notification
        fake.overviewEnvelope = envelope(attention: attention([1, 2, 3]))
        await model.refresh(reason: "manual")
        XCTAssertEqual(spy.posts.count, 1, "同一轮多异常合并通知")
        XCTAssertEqual(spy.posts[0].itemCount, 2)
        XCTAssertEqual(spy.posts[0].project, "/tmp/p2")

        // anomaly 1 recovered (gone), 2/3 persist — silent
        fake.overviewEnvelope = envelope(attention: attention([2, 3]))
        await model.refresh(reason: "manual")
        XCTAssertEqual(spy.posts.count, 1, "恢复后不反复报警")

        // anomaly 1 fails AGAIN — a fresh occurrence notifies once
        fake.overviewEnvelope = envelope(attention: attention([1, 2, 3]))
        await model.refresh(reason: "manual")
        XCTAssertEqual(spy.posts.count, 2)
        XCTAssertEqual(spy.posts[1].itemCount, 1)
        XCTAssertEqual(spy.posts[1].project, "/tmp/p1")
    }

    func testNotificationsNeverFireWhileDisabledByDefault() async {
        let spy = SpyNotifier()
        let fake = FakeEngineClient()
        let model = AppModel(client: fake,
                             cache: OverviewCacheStore(directory: directory),
                             notifications: spy)
        // never enabled: transitions across rounds post nothing
        fake.overviewEnvelope = envelope(attention: attention([1]))
        await model.refresh(reason: "manual")
        fake.overviewEnvelope = envelope(attention: attention([1, 2]))
        await model.refresh(reason: "manual")
        fake.overviewEnvelope = envelope(attention: attention([]))
        await model.refresh(reason: "manual")
        fake.overviewEnvelope = envelope(attention: attention([1]))
        await model.refresh(reason: "manual")
        XCTAssertEqual(spy.posts.count, 0,
                       "通知默认关闭 — no system notification without opt-in")
        // and no permission request happened either
        XCTAssertEqual(spy.authorizationRequests, 0)
    }

    func testLowConfidenceAttentionNeverEmitsNotification() async {
        let spy = SpyNotifier()
        let fake = FakeEngineClient()
        let model = AppModel(client: fake,
                             cache: OverviewCacheStore(directory: directory),
                             notifications: spy)
        await model.enableNotifications()
        fake.overviewEnvelope = envelope(attention: attention([1]))   // baseline
        await model.refresh(reason: "manual")
        fake.overviewEnvelope = envelope(
            attention: attention([1], kind: "stall_suspected") + attention([2]))
        await model.refresh(reason: "manual")
        XCTAssertEqual(spy.posts.count, 1, "only the fact-based item notifies")
        XCTAssertEqual(spy.posts[0].itemCount, 1)
        XCTAssertEqual(spy.posts[0].project, "/tmp/p2")
    }

    // MARK: T011 — diagnostics entry on repeated engine failure

    func testRepeatedEngineFailuresOpenDiagnosticsEntryAndKeepOldData() async {
        let cache = seedCache(active: 7, attention: 0)
        let fake = FakeEngineClient()
        fake.overviewEnvelope = FakeEngineClient.fixture(activeRuns: 7, attention: 0)
        let model = AppModel(client: fake, cache: cache)
        model.bootstrap()
        await model.refresh(reason: "panel-open")
        XCTAssertNotNil(model.diagnostics.lastSuccessAt)

        fake.overviewError = .unreachable("engine died")
        for _ in 0..<3 { await model.refresh(reason: "panel-open") }
        XCTAssertTrue(model.showDiagnosticsEntry,
                      "引擎重复失败显示诊断入口")
        XCTAssertEqual(model.diagnostics.consecutiveFailures, 3)
        XCTAssertNotNil(model.diagnostics.lastFailureText)
        XCTAssertNotNil(model.diagnostics.lastSuccessAt,
                        "旧数据时间 retained alongside the failure reason")
        XCTAssertEqual(model.activeRunCount, 7,
                       "单源失败不拖垮整体 — last successful data still displayed")

        fake.overviewError = nil
        await model.refresh(reason: "manual")
        XCTAssertFalse(model.showDiagnosticsEntry)
        XCTAssertEqual(model.diagnostics.consecutiveFailures, 0)
    }

    // MARK: T011 — sleep/wake resync (§8: 睡眠期间不判定停摆，唤醒后重新同步)

    func testWakeIssuesResyncRoundAndClearsFlagAfterSuccess() async {
        let fake = FakeEngineClient()
        fake.overviewEnvelope = FakeEngineClient.fixture(activeRuns: 1, attention: 0)
        let model = AppModel(client: fake,
                             cache: OverviewCacheStore(directory: directory))
        await model.handleWake()
        XCTAssertTrue(fake.refreshReasons.contains("wake-resync"),
                      "唤醒后重新同步 issues a dedicated refresh round")
        XCTAssertFalse(model.isResyncingAfterWake,
                       "a successful round after wake clears the resync state")
    }

    func testWakeWithFailingEngineKeepsOldDataMarkedAsResyncing() async {
        let cache = seedCache(active: 7, attention: 0)
        let fake = FakeEngineClient()
        fake.overviewError = .unreachable("asleep engine")
        let model = AppModel(client: fake, cache: cache)
        model.bootstrap()
        await model.refresh(reason: "panel-open")
        await model.handleWake()
        XCTAssertTrue(model.isResyncingAfterWake,
                      "resync state stays until the first success lands")
        XCTAssertEqual(model.activeRunCount, 7,
                       "旧数据 continues to display, annotated as resyncing")
    }

    func testIsResyncingAfterWakeFalseBeforeAnyWake() {
        let model = AppModel(client: FakeEngineClient(),
                             cache: OverviewCacheStore(directory: directory))
        XCTAssertFalse(model.isResyncingAfterWake)
    }
}
