import XCTest
@testable import ORXAnalyticsCore

/// The frozen token-number contracts (design §5 / docs/metrics.md):
/// 完全未知显示 "—"; 只有来源明确记录为零才显示 0; 两个口径独立展示、
/// 不相加、不制造混合总数.
final class MetricsFormatTests: XCTestCase {
    func testUnknownIsDashNotZero() {
        XCTAssertEqual(MetricsFormat.tokenText(nil), "—")
        XCTAssertEqual(MetricsFormat.countText(nil), "—")
    }

    func testExplicitZeroIsZero() {
        XCTAssertEqual(MetricsFormat.tokenText(0), "0")
    }

    func testValuesRenderWithoutGroupingArtifacts() {
        XCTAssertEqual(MetricsFormat.tokenText(1200), "1200")
        XCTAssertEqual(MetricsFormat.tokenText(1_234_567), "1234567")
    }

    func testProgressIsFractionOfCurrentPlanNotPercentage() {
        let progress = ProgressBlock(completed: 2, total: 7, revisionID: 103, revision: 3)
        XCTAssertEqual(MetricsFormat.progressText(progress), "2/7")
        XCTAssertEqual(MetricsFormat.progressText(nil), "—")
    }

    func testConsumptionTextCarriesCaliberLabel() {
        let consumption = ConsumptionBlock(
            caliber: "orx_recorded",
            tokens: TokenSums(inputTokens: 100, outputTokens: 40, cachedTokens: nil),
            observedTotal: 140,
            missingFields: ["input_tokens": 0, "output_tokens": 0, "cached_input": 0],
            accuracy: nil)
        XCTAssertEqual(MetricsFormat.consumptionText(consumption),
                       "已观测 token 140（ORX 已记录）")
        XCTAssertEqual(MetricsFormat.consumptionText(nil), "已观测 token —")
    }

    func testCoverageAndMissingTextsAreHonest() {
        XCTAssertEqual(MetricsFormat.coverageText(
            CoverageBlock(observed: 3, attempts: 5, missingRecorded: 1, unassessed: 1)),
                       "已观测 3/5 次尝试")
        XCTAssertEqual(MetricsFormat.coverageText(nil), "已观测 —/— 次尝试")
        XCTAssertEqual(MetricsFormat.missingText(["input_tokens": 0, "output_tokens": 2,
                                                  "cached_input": 3]),
                       "cached_input 缺 3 行，output_tokens 缺 2 行")
        XCTAssertEqual(MetricsFormat.missingText(["input_tokens": 0]), "无缺失记录")
        XCTAssertEqual(MetricsFormat.missingText(nil), "字段缺失 —")
    }

    func testTwoCalibersRenderAsSeparateRowsNeverAMergedTotal() {
        let calibers = UsageCalibers(recordedTotal: 100, nativePreviewTotal: 40)
        XCTAssertEqual(calibers.rows.count, 2)
        XCTAssertEqual(calibers.rows.map { $0.label }, ["ORX 已记录", "原生会话预览"])
        XCTAssertEqual(calibers.rows.map { $0.text }, ["100", "40"])
        // The two numbers may describe the same tokens — no row combines them.
        XCTAssertFalse(calibers.rows.map { $0.text }.contains("140"))
    }

    func testUnknownCaliberFieldStaysDash() {
        let calibers = UsageCalibers(recordedTotal: nil, nativePreviewTotal: nil)
        XCTAssertEqual(calibers.rows.map { $0.text }, ["—", "—"])
    }
}
