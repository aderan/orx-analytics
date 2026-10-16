import Foundation

/// Protocol-level types for the engine's JSON contract (Python side:
/// `src/orxanalytics/engine.py` + `query_model.py`).
///
/// Wire shape (newline-delimited JSON over `<data-dir>/engine.sock`):
///
///     request  {"op": "...", "protocol_version": 1, ...params}
///     response {"op": "...", "ok": true|false, "protocol_version": 1,
///               "generated_at": "...", <payload>, "error": {...}?}
///
/// A version mismatch is REPORTED (`unsupported_protocol` with the
/// engine's supported version) — the engine never force-takes-over and
/// the client must surface the mismatch instead of retrying blindly.

/// The protocol version this app speaks. Must equal the Python engine's
/// `query_model.PROTOCOL_VERSION`; the negotiation flow below verifies it
/// against the live engine rather than assuming it.
public enum EngineProtocol {
    public static let version = 1

    /// Ops served by the engine (design §7 query interfaces).
    public static let knownOps: Set<String> = [
        "overview", "runs.list", "runs.get", "tasks.get",
        "projects.list", "health", "refresh.request",
    ]
}

/// How a request ended at the protocol level. `.incompatible` is a
/// first-class outcome: version negotiation failure must be REPORTED
/// (app version vs engine version), never swallowed into a generic error.
public enum EngineFailure: Error, Equatable {
    /// Socket missing / refused / timeout — engine likely not running.
    case unreachable(String)
    /// `unsupported_protocol`: the engine speaks another version.
    /// `requested` is what we sent, `supported` is what the engine
    /// advertises; both go into the user-facing report.
    case incompatible(requested: Int, supported: Int, message: String)
    /// Engine refused the op (`unknown_op`, `invalid_request`, ...).
    case refused(code: String, message: String)
    /// Response was not decodable JSON / not the expected shape.
    case invalidResponse(String)

    public var localizedDescription: String {
        switch self {
        case .unreachable(let why):
            return "引擎连接失败：\(why)"
        case .incompatible(let requested, let supported, let message):
            return "协议版本不兼容：App 使用协议 v\(requested)，引擎支持 v\(supported)。"
                + "已停止查询（不强行接管引擎）。\(message)"
        case .refused(let code, let message):
            return "引擎拒绝请求（\(code)）：\(message)"
        case .invalidResponse(let why):
            return "引擎响应无法解析：\(why)"
        }
    }
}

/// The `error` object of a failed response. `supported` is an Int for
/// `unsupported_protocol` but a list of op names for `unknown_op`, so it
/// is decoded flexibly.
public struct EngineErrorPayload: Codable, Equatable {
    public let code: String
    public let message: String
    public let requestedVersion: Int?
    public let supportedVersion: Int?
    public let supportedOps: [String]

    public init(code: String, message: String, requestedVersion: Int? = nil,
                supportedVersion: Int? = nil, supportedOps: [String] = []) {
        self.code = code
        self.message = message
        self.requestedVersion = requestedVersion
        self.supportedVersion = supportedVersion
        self.supportedOps = supportedOps
    }

    enum CodingKeys: String, CodingKey {
        case code, message, requested, supported
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        message = try c.decode(String.self, forKey: .message)
        requestedVersion = try c.decodeIfPresent(Int.self, forKey: .requested)
        if let ops = try? c.decodeIfPresent([String].self, forKey: .supported) {
            supportedOps = ops ?? []
            supportedVersion = nil
        } else {
            supportedVersion = try c.decodeIfPresent(Int.self, forKey: .supported)
            supportedOps = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(requestedVersion, forKey: .requested)
        // one wire key, two shapes — exactly the engine's contract
        if let supportedVersion {
            try c.encode(supportedVersion, forKey: .supported)
        } else if !supportedOps.isEmpty {
            try c.encode(supportedOps, forKey: .supported)
        }
    }
}

/// Fields every engine response carries, regardless of op.
public struct EngineEnvelopeHeader: Codable, Equatable {
    public let op: String?
    public let ok: Bool
    public let protocolVersion: Int
    public let generatedAt: String?
    public let error: EngineErrorPayload?

    enum CodingKeys: String, CodingKey {
        case op, ok
        case protocolVersion = "protocol_version"
        case generatedAt = "generated_at"
        case error
    }
}

// MARK: - Overview payload (query_model.overview)

/// A display status from the Python layer: `{raw, known, display}`.
/// Unknown values keep their raw string and display "未知状态" — the app
/// must never guess a terminal meaning (design §4).
public struct DisplayStatus: Codable, Equatable {
    public let raw: String?
    public let known: Bool
    public let display: String
}

/// Token sums of one caliber. `nil` means the field is unknown — NOT zero
/// (metrics freeze contract: 完全未知显示 "—", only an explicitly recorded
/// zero renders "0").
public struct TokenSums: Codable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedTokens = "cached_tokens"
    }
}

/// Consumption of one run — ORX 已记录用量 caliber only. The native
/// session preview is a SEPARATE caliber shown beside, never added
/// (design §5).
public struct ConsumptionBlock: Codable, Equatable {
    public let caliber: String?
    public let tokens: TokenSums?
    public let observedTotal: Int?
    public let missingFields: Int?
    public let accuracy: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case caliber, tokens, accuracy
        case observedTotal = "observed_total"
        case missingFields = "missing_fields"
    }
}

/// "已完成任务数 / 当前计划任务数" — never a fake work-percentage.
public struct ProgressBlock: Codable, Equatable {
    public let completed: Int
    public let total: Int
    public let revisionID: String?
    public let revision: Int?

    enum CodingKeys: String, CodingKey {
        case completed, total, revision
        case revisionID = "revision_id"
    }
}

public struct GoalBlock: Codable, Equatable {
    public let id: String?
    public let objective: String?
    public let status: DisplayStatus?
}

/// One Run card in the quick panel (identity = project + run_id; short
/// ids are never cross-project keys, design §2).
public struct OverviewRunItem: Codable, Equatable, Identifiable {
    public let project: String
    public let runID: String
    public let goal: GoalBlock?
    public let status: DisplayStatus
    public let startedAt: String?
    public let progress: ProgressBlock?
    public let consumption: ConsumptionBlock?
    /// Snapshot taken_at — "数据更新时间", distinct from task progress.
    public let dataAsOf: String?

    public var id: String { "\(project)#\(runID)" }

    enum CodingKeys: String, CodingKey {
        case project, goal, status, progress, consumption
        case runID = "run_id"
        case startedAt = "started_at"
        case dataAsOf = "data_as_of"
    }
}

/// A "需要关注" item: current facts with evidence (a failed task that a
/// successor attempt already replaced is history, not attention).
public struct AttentionItem: Codable, Equatable, Identifiable {
    public let kind: String
    public let project: String
    public let runID: String
    public let taskID: String?
    public let revisionID: String?
    public let detail: String

    public var id: String { "\(project)#\(runID)#\(taskID ?? "-")#\(kind)" }

    enum CodingKeys: String, CodingKey {
        case kind, project, detail
        case runID = "run_id"
        case taskID = "task_id"
        case revisionID = "revision_id"
    }
}

public struct ProjectsCountBlock: Codable, Equatable {
    public let considered: Int
    public let queried: Int
}

public struct OverviewSummary: Codable, Equatable {
    /// The number the menu-bar badge shows — in-progress Run count only
    /// (design §3: 数字固定代表进行中的 Run 数量).
    public let activeRuns: Int
    public let attention: Int
    public let recentCompleted: Int
    public let projects: ProjectsCountBlock?

    enum CodingKeys: String, CodingKey {
        case attention, projects
        case activeRuns = "active_runs"
        case recentCompleted = "recent_completed"
    }
}

/// The full `overview` response: header + payload.
public struct OverviewEnvelope: Codable, Equatable {
    public let header: EngineEnvelopeHeader
    public let summary: OverviewSummary
    public let active: [OverviewRunItem]
    public let attention: [AttentionItem]
    public let recentCompleted: [OverviewRunItem]

    public init(header: EngineEnvelopeHeader, summary: OverviewSummary,
                active: [OverviewRunItem], attention: [AttentionItem],
                recentCompleted: [OverviewRunItem]) {
        self.header = header
        self.summary = summary
        self.active = active
        self.attention = attention
        self.recentCompleted = recentCompleted
    }

    enum CodingKeys: String, CodingKey {
        case summary, active, attention
        case recentCompleted = "recent_completed"
    }

    public init(from decoder: Decoder) throws {
        header = try EngineEnvelopeHeader(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decode(OverviewSummary.self, forKey: .summary)
        active = try c.decodeIfPresent([OverviewRunItem].self, forKey: .active) ?? []
        attention = try c.decodeIfPresent([AttentionItem].self, forKey: .attention) ?? []
        recentCompleted = try c.decodeIfPresent([OverviewRunItem].self,
                                                forKey: .recentCompleted) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        // The header fields (op/ok/protocol_version/...) are written by
        // the header's own conformance into this same object; a
        // synthesized encode would silently drop them and make the
        // cache roundtrip lossy.
        try header.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary)
        try c.encode(active, forKey: .active)
        try c.encode(attention, forKey: .attention)
        try c.encode(recentCompleted, forKey: .recentCompleted)
    }
}

/// Outcome of the initial protocol negotiation (`health` probe).
public enum NegotiationOutcome: Equatable {
    /// Engine answered with a compatible protocol version.
    case compatible(engineVersion: Int)
    /// Engine answered but speaks a different version — REPORT, then stop
    /// querying. Never take over, never downgrade silently.
    case incompatible(requested: Int, supported: Int)
    /// Nobody home at the socket — the engine is (probably) not running.
    case engineNotRunning
}
