import Foundation
import Combine

/// Engine connection state as shown in the panel header. Distinct from
/// run status and data health (design §4: three independent dimensions).
public enum EngineConnectionState: Equatable {
    case idle
    case connecting
    case ready(engineVersion: Int)
    /// Protocol negotiation failed — reported explicitly, queries stopped.
    case incompatible(requested: Int, supported: Int)
    /// Socket unreachable — engine probably not running yet.
    case notRunning(String)

    public var isFatal: Bool {
        if case .incompatible = self { return true }
        return false
    }
}

/// Cache-first view state for the quick panel (design §3):
/// `bootstrap()` publishes the cached overview SYNCHRONOUSLY (if any),
/// then refreshes asynchronously. The panel is never blank while a
/// refresh is in flight, and the main thread is never blocked by IO.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var cachedOverview: CachedOverview?
    @Published public private(set) var connection: EngineConnectionState = .idle
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastFailureText: String?
    /// When the last SUCCESSFUL network refresh landed (nil = cache only).
    @Published public private(set) var lastRefreshedAt: Date?
    /// The run whose detail window is open (nil = the all-runs entry
    /// list). Set before opening the window so the view keeps the
    /// project + run context (design §3: 保留项目和执行上下文).
    @Published public private(set) var selectedRun: RunIdentity?

    public let client: EngineClientProtocol
    public let cache: OverviewCacheStore
    /// The history query window's model. Owned here (not per-view) so
    /// results and filter state survive navigating into a run detail
    /// and back — the window keeps its context (design §3).
    public let historyModel: HistoryModel

    /// Serializes refresh rounds; multiple concurrent `refresh()` calls
    /// coalesce into the in-flight one (design §8: 多个刷新请求合并).
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?

    public init(client: EngineClientProtocol, cache: OverviewCacheStore) {
        self.client = client
        self.cache = cache
        self.historyModel = HistoryModel(client: client)
    }

    // MARK: - Badge (menu bar)

    /// The menu-bar number: in-progress Run count ONLY. It never switches
    /// to task counts, session counts or token sums (design §3), and it
    /// reads from whatever data is currently displayed — cache counts
    /// until a fresher fetch lands.
    public var activeRunCount: Int {
        cachedOverview?.envelope.summary.activeRuns ?? 0
    }

    /// Independent attention marker (text+icon, never color alone).
    public var attentionCount: Int {
        cachedOverview?.envelope.summary.attention ?? 0
    }

    // MARK: - Lifecycle

    /// Open path: publish cache first, refresh in the background. Never
    /// downgrades: once fresher in-memory data exists, re-opening the
    /// panel does not clobber it with an older cache file.
    public func bootstrap() {
        if cachedOverview == nil {
            cachedOverview = cache.load()
        }
        Task { await self.refresh(reason: "panel-open") }
    }

    /// User-visible refresh (button) — same coalescing.
    public func refreshNow() async {
        await refresh(reason: "manual")
    }

    // MARK: - detail navigation

    /// Point the detail window at one run and let the caller open it.
    public func openRunDetail(project: String, runID: String) {
        selectedRun = RunIdentity(project: project, runID: runID)
    }

    /// Show the all-runs entry list instead of a specific run.
    public func openAllRuns() {
        selectedRun = nil
    }

    /// One refresh round: negotiate -> request collection -> fetch the
    /// read model. Runs entirely off the main actor (the client's async
    /// wrappers hop to the engine IO queue), publishes on main.
    ///
    /// Coalescing: if a round is already in flight this call returns when
    /// THAT round returns — no second request is issued.
    public func refresh(reason: String) async {
        if let existing = refreshTask, !existing.isCancelled {
            _ = await existing.value
            return
        }
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.runRefreshRound(reason: reason)
        }
        refreshTask = task
        _ = await task.value
        refreshTask = nil
    }

    private func runRefreshRound(reason: String) async {
        guard !connection.isFatal else { return }   // incompatible: stop querying
        isRefreshing = true
        defer { isRefreshing = false }
        connection = .connecting

        let outcome = await client.negotiateAsync()
        switch outcome {
        case let .compatible(engineVersion):
            connection = .ready(engineVersion: engineVersion)
        case let .incompatible(requested, supported):
            // Explicit downgrade report; no further queries this session
            // until the user retries explicitly.
            connection = .incompatible(requested: requested, supported: supported)
            lastFailureText = EngineFailure.incompatible(requested: requested,
                                                         supported: supported,
                                                         message: "").localizedDescription
            return
        case .engineNotRunning:
            connection = .notRunning("引擎未运行（socket 无监听）。缓存数据继续展示。")
            lastFailureText = nil    // not an error worth alarming about
            return
        }

        do {
            // Ask the engine to collect, then read whatever is already in
            // the read model. The refresh job itself completes later; the
            // panel never waits for it (cache-first, §8).
            _ = try await client.requestRefreshAsync(reason: reason)
            let envelope = try await client.fetchOverviewAsync()
            let cached = CachedOverview(envelope: envelope, cachedAt: Date())
            cache.save(cached)
            cachedOverview = cached
            lastRefreshedAt = cached.cachedAt
            lastFailureText = nil
        } catch let failure as EngineFailure {
            lastFailureText = failure.localizedDescription
            if case let .incompatible(requested, supported, _) = failure {
                connection = .incompatible(requested: requested, supported: supported)
            } else if case .unreachable = failure {
                connection = .notRunning("引擎连接中断。缓存数据继续展示。")
            }
            // A failed round keeps the last successful data displayed —
            // cachedOverview is untouched here.
        } catch {
            lastFailureText = "刷新失败：\(error)"
        }
    }

    // MARK: - Auto refresh (panel-open tier, design §8: ~5s)

    /// While the panel is open the app holds a "panel-open" demand and
    /// re-reads the read model about every 5 seconds. This is a STATUS
    /// cadence — it does not mean token numbers change every 5 seconds.
    public func startAutoRefresh(interval: TimeInterval = 5) {
        stopAutoRefresh()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(reason: "panel-open")
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// App termination: release THIS client's collection demand only.
    /// A CLI watcher's demand lives on its own connection (design §7).
    public func shutdown() {
        stopAutoRefresh()
        refreshTask?.cancel()
        if let socketClient = client as? EngineSocketClient {
            socketClient.disconnect()
        }
    }

    /// The separate, explicit cache-clean action (never automatic).
    public func clearDisplayCache() {
        cache.clear()
        cachedOverview = nil
    }
}
