import XCTest
@testable import ORXAnalyticsCore

/// Protocol client tests against a synthetic in-process engine
/// (no live engine, no real projects — CONTRIBUTING: 测试用合成来源).
final class EngineClientTests: XCTestCase {
    private var simulator: EngineSimulator?

    override func tearDown() {
        simulator?.stop()
        simulator = nil
        super.tearDown()
    }

    private func makeClient(handler: @escaping EngineSimulator.Handler) throws -> EngineSocketClient {
        let sim = EngineSimulator(handler: handler)
        try sim.start()
        simulator = sim
        return EngineSocketClient(socketPath: sim.socketPath, timeout: 3.0)
    }

    private static func decodeJSON(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: negotiation

    func testNegotiationCompatibleReportsEngineVersion() throws {
        let client = try makeClient { line in
            let obj = Self.decodeJSON(line)
            if obj?["op"] as? String == "health" {
                return EngineSimulator.encode(EngineSimulator.healthResponse(version: 1))
            }
            return EngineSimulator.encode(["op": obj?["op"] ?? NSNull(), "ok": true,
                                           "protocol_version": 1])
        }
        guard case let .compatible(version) = client.negotiate() else {
            return XCTFail("expected .compatible")
        }
        XCTAssertEqual(version, 1)
    }

    func testEveryRequestCarriesProtocolVersionAndOp() throws {
        let client = try makeClient { line in
            if Self.decodeJSON(line)?["op"] as? String == "overview" {
                return EngineSimulator.encode(
                    EngineSimulator.overviewResponse(activeRuns: 1, attention: 0))
            }
            return EngineSimulator.encode(EngineSimulator.healthResponse(version: 1))
        }
        _ = client.negotiate()
        _ = try client.fetchOverview()
        let requests = simulator!.receivedRequests
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        for request in requests {
            guard let obj = Self.decodeJSON(request) else {
                return XCTFail("request is not a JSON object: \(request)")
            }
            XCTAssertEqual(obj["protocol_version"] as? Int, 1,
                           "engine checks protocol_version on EVERY request")
            XCTAssertNotNil(obj["op"] as? String)
        }
        XCTAssertEqual(Self.decodeJSON(requests[1])?["op"] as? String, "overview")
    }

    func testNegotiationIncompatibleIsExplicitAndStopsQuerying() throws {
        let client = try makeClient { _ in
            EngineSimulator.encode(
                EngineSimulator.unsupportedProtocolResponse(requested: 1, supported: 99))
        }
        guard case let .incompatible(requested, supported) = client.negotiate() else {
            return XCTFail("expected .incompatible")
        }
        XCTAssertEqual(requested, 1)
        XCTAssertEqual(supported, 99)

        // fail-fast: no further socket traffic after the verdict
        let count = simulator!.receivedRequests.count
        XCTAssertThrowsError(try client.fetchOverview()) { error in
            guard case let .incompatible(req, sup, _) = error as? EngineFailure else {
                return XCTFail("expected .incompatible, got \(error)")
            }
            XCTAssertEqual(req, 1)
            XCTAssertEqual(sup, 99)
        }
        XCTAssertEqual(simulator!.receivedRequests.count, count,
                       "client must not keep querying an incompatible engine")

        // the user-facing report names BOTH versions (不兼容明确报告)
        let text = EngineFailure.incompatible(requested: 1, supported: 99,
                                              message: "").localizedDescription
        XCTAssertTrue(text.contains("v1"), "report should name the app version: \(text)")
        XCTAssertTrue(text.contains("v99"), "report should name the engine version: \(text)")
        XCTAssertTrue(text.contains("不强行接管"), "report should state no takeover")
    }

    func testSuccessfulResponseWithForeignVersionIsAlsoIncompatible() throws {
        let client = try makeClient { _ in
            EngineSimulator.encode(EngineSimulator.healthResponse(version: 7))
        }
        guard case let .incompatible(requested, supported) = client.negotiate() else {
            return XCTFail("expected .incompatible for ok-response with foreign version")
        }
        XCTAssertEqual(requested, 1)
        XCTAssertEqual(supported, 7)
    }

    // MARK: queries

    func testFetchOverviewDecodesPayload() throws {
        let client = try makeClient { line in
            switch Self.decodeJSON(line)?["op"] as? String {
            case "overview":
                return EngineSimulator.encode(
                    EngineSimulator.overviewResponse(activeRuns: 3, attention: 2))
            default:
                return EngineSimulator.encode(EngineSimulator.healthResponse())
            }
        }
        let envelope = try client.fetchOverview()
        XCTAssertEqual(envelope.summary.activeRuns, 3)
        XCTAssertEqual(envelope.summary.attention, 2)
        XCTAssertEqual(envelope.active.count, 3)
        XCTAssertEqual(envelope.attention.count, 2)
        XCTAssertEqual(envelope.header.protocolVersion, 1)
        XCTAssertEqual(envelope.active.first?.status.display, "执行中")
        XCTAssertEqual(envelope.active.first?.status.known, true)
        XCTAssertFalse(envelope.active.isEmpty ? false : envelope.active[0].id.isEmpty)
    }

    func testRunItemCarriesProgressAndConsumption() throws {
        let client = try makeClient { line in
            switch Self.decodeJSON(line)?["op"] as? String {
            case "overview":
                return EngineSimulator.encode(
                    EngineSimulator.overviewResponse(activeRuns: 1, attention: 0))
            default:
                return EngineSimulator.encode(EngineSimulator.healthResponse())
            }
        }
        let run = try client.fetchOverview().active[0]
        XCTAssertEqual(run.progress?.completed, 1)
        XCTAssertEqual(run.progress?.total, 3)
        XCTAssertEqual(run.consumption?.observedTotal, 1200)
        XCTAssertEqual(run.consumption?.tokens?.inputTokens, 1000)
        XCTAssertNil(run.consumption?.tokens?.cachedTokens)
    }

    func testRequestRefreshDecodesAcceptedJob() throws {
        let client = try makeClient { line in
            switch Self.decodeJSON(line)?["op"] as? String {
            case "refresh.request":
                return EngineSimulator.encode([
                    "op": "refresh.accepted", "ok": true, "protocol_version": 1,
                    "job_id": "job-7", "merged_with": "job-6",
                    "projects": ["/tmp/a"],
                    "rejected": [["project": "/tmp/b",
                                  "reason": "unsupported schema"]],
                ])
            default:
                return EngineSimulator.encode(EngineSimulator.healthResponse())
            }
        }
        let accepted = try client.requestRefresh(reason: "panel-open")
        XCTAssertEqual(accepted.jobID, "job-7")
        XCTAssertEqual(accepted.mergedWith, "job-6")
        XCTAssertEqual(accepted.rejected.first?.reason, "unsupported schema")
        // the reason traveled on the wire
        let sent = Self.decodeJSON(simulator!.receivedRequests[0])
        XCTAssertEqual(sent?["reason"] as? String, "panel-open")
    }

    func testUnknownOpSurfacesAsRefused() throws {
        let client = try makeClient { _ in
            EngineSimulator.encode([
                "op": NSNull(), "ok": false, "protocol_version": 1,
                "error": ["code": "unknown_op", "message": "op 'overview' is not served",
                          "supported": ["overview", "health"]],
            ])
        }
        XCTAssertThrowsError(try client.fetchOverview()) { error in
            guard case let .refused(code, message) = error as? EngineFailure else {
                return XCTFail("expected .refused, got \(error)")
            }
            XCTAssertEqual(code, "unknown_op")
            XCTAssertTrue(message.contains("not served"))
        }
    }

    func testInvalidJSONResponseSurfacesAsInvalidResponse() throws {
        let client = try makeClient { _ in Data("this is not json".utf8) }
        XCTAssertThrowsError(try client.fetchOverview()) { error in
            guard case .invalidResponse = error as? EngineFailure else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        }
    }

    // MARK: transport

    func testMissingSocketIsUnreachableNotRunning() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-\(UUID().uuidString).sock").path
        let client = EngineSocketClient(socketPath: path, timeout: 1.0)
        XCTAssertEqual(client.negotiate(), .engineNotRunning)
        XCTAssertThrowsError(try client.fetchOverview()) { error in
            guard case .unreachable = error as? EngineFailure else {
                return XCTFail("expected .unreachable, got \(error)")
            }
        }
    }

    func testDefaultSocketPathFollowsDataDirConvention() {
        XCTAssertEqual(
            EngineSocketClient.defaultSocketPath(environment: [:]),
            NSHomeDirectory() + "/.orx-analytics/engine.sock")
        XCTAssertEqual(
            EngineSocketClient.defaultSocketPath(environment: ["ORX_ANALYTICS_HOME": "/tmp/x"]),
            "/tmp/x/engine.sock")
        XCTAssertEqual(
            EngineSocketClient.defaultSocketPath(environment: ["ORX_ANALYTICS_HOME": ""]),
            NSHomeDirectory() + "/.orx-analytics/engine.sock")
    }
}
