import XCTest

@testable import TypeEngine

final class ArchitectureBoundaryTests: XCTestCase {

    func testConfigurationDomainsSnapshotFlatShippingValues() {
        var config = EngineConfig()
        config.beamMaxExpansions = 321
        config.languageWeight = 1.25
        config.autocorrectMargin = 1.75
        config.tapSigmaX = 0.31
        config.laneSwitchProbability = 0.12
        config.morphBackoffWeight = 0.8

        let domains = config.domains

        XCTAssertEqual(domains.search.beamMaxExpansions, 321)
        XCTAssertEqual(domains.ranking.languageWeight, 1.25)
        XCTAssertEqual(domains.action.autocorrectMargin, 1.75)
        XCTAssertEqual(domains.touch.sigmaX, 0.31)
        XCTAssertEqual(domains.lane.switchProbability, 0.12)
        XCTAssertEqual(domains.morphology.backoffWeight, 0.8)
    }

    func testConfigurationDomainIsASnapshotNotASecondStore() {
        var config = EngineConfig()
        let original = config.domains
        config.autocorrectMargin = original.action.autocorrectMargin + 1

        XCTAssertNotEqual(config.domains.action.autocorrectMargin, original.action.autocorrectMargin)
        XCTAssertEqual(
            original.action.autocorrectMargin,
            EngineConfig().autocorrectMargin)
    }

    func testTraceClassifiesPostRankingActionBranches() {
        let corrector = Corrector(
            icelandic: Fixtures.icelandic,
            english: Fixtures.english)

        let repairTrace = CorrectionTrace()
        _ = corrector.correct(typed: "teh", trace: repairTrace)
        XCTAssertEqual(repairTrace.rule, "ordinary-unknown")

        let splitTrace = CorrectionTrace()
        _ = corrector.correct(typed: "gottnveður", limit: 8, trace: splitTrace)
        XCTAssertEqual(splitTrace.rule, "split")

        let validTrace = CorrectionTrace()
        _ = corrector.correct(typed: "hestur", trace: validTrace)
        XCTAssertEqual(validTrace.rule, "valid-word (no auto-apply path)")
    }
}
