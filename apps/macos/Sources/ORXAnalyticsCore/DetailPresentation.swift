import Foundation

// MARK: - three independent dimensions (design §4)

/// The three axes every run presents SEPARATELY: execution status,
/// attention facts, data health. Each text comes from engine facts —
/// an unrecognized raw status stays 未知状态, an unavailable health
/// classification stays 未知, and nothing mixes the three into one
/// red/yellow/green verdict.
public struct RunDimensions: Equatable {
    public let executionStatus: String
    public let attentionSummary: String
    public let dataHealth: String

    public static func build(run: RunFacts?, tasks: [TaskListItem],
                             health: DataHealthBlock?,
                             snapshots: [String: SnapshotView],
                             project: String?) -> RunDimensions {
        let status = run?.status.display ?? "未知状态"

        // Attention = current-facts failures of the CURRENT plan only
        // (design §4: a recovered failure is history, waiting on
        // prerequisites is not an anomaly). We count failed tasks of
        // the current revision as reported by the engine's status
        // mapping — no recovery guessing here; the per-task retry
        // wording lives in the drill-down.
        let currentRevision = run?.progress?.revisionID
        let attention: String
        if let currentRevision {
            let failed = tasks.filter {
                $0.revisionID == currentRevision && $0.status.raw == "failed"
            }
            attention = failed.isEmpty
                ? "无当前失败任务"
                : "当前计划失败任务 \(failed.count)"
        } else {
            attention = "当前计划未知"
        }

        let dataHealthText: String
        if let health, let label = health.health, !label.isEmpty {
            dataHealthText = label          // engine's own classification
        } else if let snap = snapshots[project ?? ""], snap.supported == false {
            dataHealthText = "版本不支持"
        } else {
            dataHealthText = "未知"
        }
        return RunDimensions(executionStatus: status,
                              attentionSummary: attention,
                              dataHealth: dataHealthText)
    }
}

// MARK: - retry wording (design §4)

/// Wording for a task's retry state. "重试中" requires BOTH a failing
/// attempt and a successor; a recovered failure is labeled as history,
/// not an active anomaly.
public enum RetryDisplay {
    public static func text(_ retry: RetrySummary?) -> String {
        guard let retry else { return "—" }
        let failing = retry.failingAttemptIDs ?? []
        let successors = retry.successorAttemptIDs ?? []
        if retry.recovered == true {
            return "已恢复（后续尝试已接替）"
        }
        if !failing.isEmpty && !successors.isEmpty {
            return "重试中"
        }
        if !failing.isEmpty {
            return "失败待重试"
        }
        return "无失败尝试"
    }
}

// MARK: - model distribution (counts only)

/// Attempts-per-model distribution. COUNTING ONLY: the metrics freeze
/// forbids this layer from re-implementing token attribution, so an
/// entry carries no token numbers at all — token books come from the
/// engine's own ledgers.
public struct ModelDistribution: Equatable {
    public struct Entry: Equatable, Identifiable {
        public let id: String
        public let model: String
        public let attempts: Int
    }

    public let entries: [Entry]

    public init(attempts: [AttemptDetail]) {
        var counts: [String: Int] = [:]
        for attempt in attempts {
            counts[attempt.model ?? "未知模型", default: 0] += 1
        }
        entries = counts
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .map { Entry(id: $0.key, model: $0.key, attempts: $0.value) }
    }
}

// MARK: - the two calibers, side by side, never added (design §5)

/// Row groups for the detail's 消耗分析 zone. STRUCTURALLY INCAPABLE of
/// producing a combined number: it holds exactly two independently
/// labeled groups, each row built from ONE engine value through
/// `MetricsFormat.tokenText` — nothing is summed here.
public struct DetailCalibers: Equatable {
    public struct Row: Equatable, Identifiable {
        public let id: String
        public let label: String
        public let text: String
    }

    public let orxRows: [Row]
    public let nativeRows: [Row]

    public init(usage: RunUsage?, preview: NativePreview?) {
        // ORX 已记录用量 — per-field rows; unknown stays "—"; NO total
        // is derived because cache semantics belong to the source.
        let tokens = usage?.tokens
        orxRows = [
            Row(id: "orx.input", label: "输入",
                text: MetricsFormat.tokenText(tokens?.inputTokens)),
            Row(id: "orx.output", label: "输出",
                text: MetricsFormat.tokenText(tokens?.outputTokens)),
            Row(id: "orx.cached", label: "缓存（cached_input）",
                text: MetricsFormat.tokenText(tokens?.cachedTokens)),
        ]
        // 原生会话预览 — the union's own turn sums as its own rows.
        let t = preview?.union?.tokens
        nativeRows = [
            Row(id: "nat.turns", label: "会话轮次",
                text: MetricsFormat.countText(t?.turns)),
            Row(id: "nat.input", label: "输入",
                text: MetricsFormat.tokenText(t?.inputTokens)),
            Row(id: "nat.output", label: "输出",
                text: MetricsFormat.tokenText(t?.outputTokens)),
            Row(id: "nat.reasoning", label: "推理",
                text: MetricsFormat.tokenText(t?.reasoningTokens)),
            Row(id: "nat.cache_read", label: "缓存读",
                text: MetricsFormat.tokenText(t?.cacheRead)),
            Row(id: "nat.cache_write", label: "缓存写",
                text: MetricsFormat.tokenText(t?.cacheCreation)),
        ]
    }
}
