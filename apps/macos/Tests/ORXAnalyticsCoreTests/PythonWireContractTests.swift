import XCTest
@testable import ORXAnalyticsCore

/// Cross-language wire contract: decode payloads serialized by the REAL
/// Python query layer (`apps/macos/scripts/gen_wire_fixtures.py`, run
/// inside the repo venv) — not hand-written fixtures. This catches any
/// drift between the Swift payload models and
/// `src/orxanalytics/query_model.py` + `usage_readmodel.py`.
///
/// The check runs only when `ORX_WIRE_FIXTURES` points at the generated
/// directory (regenerate with:
/// `.venv/bin/python apps/macos/scripts/gen_wire_fixtures.py <dir>`);
/// without it the tests skip — `swift test` stays usable without the
/// Python environment.
final class PythonWireContractTests: XCTestCase {

    private static var fixtureDir: String? {
        ProcessInfo.processInfo.environment["ORX_WIRE_FIXTURES"]
    }

    private func load(_ name: String) throws -> Data {
        let dir = try XCTUnwrap(Self.fixtureDir,
                                "ORX_WIRE_FIXTURES not set; regenerate fixtures to run this contract test")
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    func testOverviewFromPythonLayerDecodes() throws {
        guard Self.fixtureDir != nil else {
            throw XCTSkip("ORX_WIRE_FIXTURES not set")
        }
        let envelope = try JSONDecoder().decode(OverviewEnvelope.self,
                                                from: load("overview.json"))
        XCTAssertEqual(envelope.header.op, "overview")
        XCTAssertTrue(envelope.header.ok)
        XCTAssertEqual(envelope.summary.activeRuns, envelope.active.count)
        // every active run decodes its progress and consumption,
        // including runs WITHOUT revisions (revision_id nil)
        for run in envelope.active {
            XCTAssertFalse(run.id.isEmpty)
            _ = MetricsFormat.progressText(run.progress)
            _ = MetricsFormat.tokenText(run.consumption?.observedTotal)
        }
        // the attention items decode (task-less blocked runs included)
        XCTAssertGreaterThanOrEqual(envelope.attention.count, 0)
        // data health rows carry the engine's own classification
        for row in envelope.projectHealth {
            XCTAssertNotNil(row.dataHealth?.health)
        }
    }

    func testRunsGetFromPythonLayerDecodesWithBothCalibers() throws {
        guard Self.fixtureDir != nil else {
            throw XCTSkip("ORX_WIRE_FIXTURES not set")
        }
        let envelope = try JSONDecoder().decode(RunDetailEnvelope.self,
                                                from: load("runs_get.json"))
        XCTAssertTrue(envelope.found)
        let usage = try XCTUnwrap(envelope.usage)
        XCTAssertGreaterThan(usage.books?.tasks?.attempts ?? 0, 0,
                             "task-linked attempts must decode from the real payload")
        XCTAssertNotNil(usage.books?.planner)
        XCTAssertNotNil(usage.books?.controller)
        XCTAssertNotNil(usage.books?.unattributedWithinRun)
        XCTAssertFalse(envelope.revisions.isEmpty)
        XCTAssertGreaterThanOrEqual(envelope.tasks.count, 5)
        let preview = try XCTUnwrap(envelope.nativePreview)
        XCTAssertEqual(preview.neverSumWith, "orx_recorded")
        // the two calibers decode into two separate row groups
        let calibers = DetailCalibers(usage: usage, preview: preview)
        XCTAssertEqual(calibers.orxRows.count, 3)
        XCTAssertEqual(calibers.nativeRows.count, 6)
    }

    func testRunsGetOtherProjectDecodes() throws {
        guard Self.fixtureDir != nil else {
            throw XCTSkip("ORX_WIRE_FIXTURES not set")
        }
        let envelope = try JSONDecoder().decode(RunDetailEnvelope.self,
                                                from: load("runs_get_b.json"))
        XCTAssertTrue(envelope.found, "same run_id in another project is a DIFFERENT run")
    }

    func testTasksGetFromPythonLayerDecodesEvidence() throws {
        guard Self.fixtureDir != nil else {
            throw XCTSkip("ORX_WIRE_FIXTURES not set")
        }
        let envelope = try JSONDecoder().decode(TaskDetailEnvelope.self,
                                                from: load("tasks_get.json"))
        XCTAssertTrue(envelope.found)
        let usage = try XCTUnwrap(envelope.usage)
        XCTAssertNotNil(usage.books?.worker)
        XCTAssertNotNil(usage.books?.verifier)
        XCTAssertFalse(usage.attempts.isEmpty)
        for attempt in usage.attempts {
            XCTAssertGreaterThan(attempt.attemptID, 0)
        }
        // verifications decode with SQLite 0/1 booleans
        for verification in envelope.verifications {
            _ = verification.passed
        }
        _ = RetryDisplay.text(envelope.retry)
        _ = ModelDistribution(attempts: usage.attempts)
    }
}
