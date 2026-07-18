import XCTest

@testable import EvalKit

final class CorpusBaselineTests: XCTestCase {
    private func suite(
        n: Int = 10, top1: Int = 8, top3: Int = 9, falseAc: Int = 1,
        category: String = "substitution"
    ) -> CorpusSuiteSnapshot {
        let metrics = CorpusMetricSnapshot(
            n: n, top1: top1, top3: top3, falseAc: falseAc)
        return CorpusSuiteSnapshot(
            overall: metrics,
            categories: [category: metrics],
            byLang: ["is": metrics])
    }

    func testEqualAndImprovedMetricsPass() {
        let baseline = CorpusBaselineDocument(suites: ["dev": suite()])
        XCTAssertTrue(
            CorpusBaselineGate.failures(
                current: ["dev": suite(top1: 9, top3: 10, falseAc: 0)],
                baseline: baseline
            ).isEmpty)
    }

    func testEveryMetricDirectionIsGated() {
        let baseline = CorpusBaselineDocument(suites: ["dev": suite()])
        let failures = CorpusBaselineGate.failures(
            current: ["dev": suite(n: 11, top1: 7, top3: 8, falseAc: 2)],
            baseline: baseline)
        XCTAssertTrue(failures.contains { $0.contains(".n changed") })
        XCTAssertTrue(failures.contains { $0.contains(".top1 regressed") })
        XCTAssertTrue(failures.contains { $0.contains(".top3 regressed") })
        XCTAssertTrue(failures.contains { $0.contains(".falseAc regressed") })
    }

    func testCategoryLanguageAndSuiteCohortsCannotDriftSilently() {
        let baseline = CorpusBaselineDocument(suites: ["dev": suite()])
        let changed = CorpusSuiteSnapshot(
            overall: CorpusMetricSnapshot(n: 10, top1: 8, top3: 9, falseAc: 1),
            categories: ["deletion": CorpusMetricSnapshot(n: 10, top1: 8, top3: 9, falseAc: 1)],
            byLang: ["en": CorpusMetricSnapshot(n: 10, top1: 8, top3: 9, falseAc: 1)])
        let failures = CorpusBaselineGate.failures(
            current: ["safety": changed], baseline: baseline)
        XCTAssertTrue(failures.contains { $0.contains("suite cohort changed") })
    }

    func testUnknownSchemaFailsClosed() {
        let baseline = CorpusBaselineDocument(schema: "future", suites: ["dev": suite()])
        XCTAssertEqual(
            CorpusBaselineGate.failures(current: ["dev": suite()], baseline: baseline),
            ["unsupported corpus baseline schema future"])
    }
}
