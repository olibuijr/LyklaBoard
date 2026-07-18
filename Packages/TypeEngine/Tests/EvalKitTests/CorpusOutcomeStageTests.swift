import XCTest

@testable import EvalKit
import TypeEngine

final class CorpusOutcomeStageTests: XCTestCase {
    private func pair(
        typo: String = "teh", intended: String = "the",
        expectation: CorpusExpectation = .repair
    ) -> CorpusPair {
        CorpusPair(
            typo: typo, intended: intended, context: [], lang: "en",
            category: "test", expectation: expectation)
    }

    private func suggestion(_ text: String, autocorrect: Bool = false) -> Suggestion {
        Suggestion(text: text, isAutocorrect: autocorrect, confidence: 1)
    }

    func testDiscoveryMiss() {
        let stage = CorpusEval.classifyOutcome(
            pair: pair(), suggestions: [suggestion("ten")], discoveredCandidates: ["ten"])
        XCTAssertEqual(stage, .discoveryMiss)
    }

    func testRankingLossWhenGoldWasDiscoveredOutsideVisibleBar() {
        let stage = CorpusEval.classifyOutcome(
            pair: pair(), suggestions: [suggestion("ten")],
            discoveredCandidates: ["ten", "the"])
        XCTAssertEqual(stage, .rankingLoss)
    }

    func testActionPolicyAbstention() {
        let stage = CorpusEval.classifyOutcome(
            pair: pair(), suggestions: [suggestion("the")], discoveredCandidates: ["the"])
        XCTAssertEqual(stage, .actionPolicyAbstention)
    }

    func testActionPolicyErrorTakesPrecedenceOverDiscovery() {
        let stage = CorpusEval.classifyOutcome(
            pair: pair(), suggestions: [suggestion("ten", autocorrect: true)],
            discoveredCandidates: ["ten"])
        XCTAssertEqual(stage, .actionPolicyError)
    }

    func testSuccessfulRepair() {
        let stage = CorpusEval.classifyOutcome(
            pair: pair(), suggestions: [suggestion("the", autocorrect: true)],
            discoveredCandidates: ["the"])
        XCTAssertEqual(stage, .success)
    }

    func testPreserveRowsOnlyFailWhenPolicyAutoReplacesTypedWord() {
        let hardNegative = pair(typo: "form", intended: "from", expectation: .preserve)
        XCTAssertEqual(
            CorpusEval.classifyOutcome(
                pair: hardNegative, suggestions: [suggestion("from")],
                discoveredCandidates: ["from"]),
            .success)
        XCTAssertEqual(
            CorpusEval.classifyOutcome(
                pair: hardNegative, suggestions: [suggestion("from", autocorrect: true)],
                discoveredCandidates: ["from"]),
            .actionPolicyError)
    }
}
