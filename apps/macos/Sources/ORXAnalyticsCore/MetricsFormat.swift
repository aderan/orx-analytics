import Foundation

/// Presentation rules for token numbers — these are FROZEN CONTRACTS,
/// not styling choices (design §5 + docs/metrics.md):
///
/// 1. 完全未知显示 "—"。Only a source that explicitly recorded zero may
///    show "0". Unknown must never be zero-filled.
/// 2. "ORX 已记录用量" and "原生会话预览" are two INDEPENDENT calibers.
///    They may describe the same tokens, so they are displayed side by
///    side, never added, and no mixed total exists anywhere in this layer.
/// 3. There is no "今日消耗" derivation here — adding one requires a new
///    contract entry plus regression tests first.
public enum MetricsFormat {

    /// nil -> "—" (unknown); 0 -> "0" (explicitly recorded zero).
    public static func tokenText(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value == 0 ? "0" : format(value)
    }

    /// Same rule for any counted quantity (attempts, fields, ...).
    public static func countText(_ value: Int?) -> String {
        tokenText(value)
    }

    private static func format(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ""
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "已完成任务数 / 当前计划任务数" — a fraction of the CURRENT plan
    /// only; never presented as a work-percentage (design §3).
    public static func progressText(_ progress: ProgressBlock?) -> String {
        guard let progress else { return "—" }
        return "\(progress.completed)/\(progress.total)"
    }

    /// Summary line for one run's observed consumption with its coverage
    /// honesty ("已观测 N；覆盖 a/b 次尝试" style), caliber-tagged.
    public static func consumptionText(_ consumption: ConsumptionBlock?) -> String {
        guard let consumption else { return "已观测 token —" }
        let caliber = consumption.caliber == "orx_recorded" ? "ORX 已记录" : (consumption.caliber ?? "未知口径")
        return "已观测 token \(tokenText(consumption.observedTotal))（\(caliber)）"
    }
}

/// The two calibers the UI may show for the same run. Constructed with
/// explicit fields and rendered with explicit labels — there is no API
/// here that combines them, by design (metrics freeze).
public struct UsageCalibers: Equatable {
    /// ORX 已记录用量 — the primary statistic, always shown with its
    /// coverage.
    public let recordedTotal: Int?
    /// 原生会话预览 — shown SEPARATELY with source and update time when
    /// a source supports it; nil means not provided.
    public let nativePreviewTotal: Int?

    public init(recordedTotal: Int?, nativePreviewTotal: Int? = nil) {
        self.recordedTotal = recordedTotal
        self.nativePreviewTotal = nativePreviewTotal
    }

    /// Two independent rows — never one merged number.
    public var rows: [(label: String, text: String)] {
        [("ORX 已记录", MetricsFormat.tokenText(recordedTotal)),
         ("原生会话预览", MetricsFormat.tokenText(nativePreviewTotal))]
    }
}
