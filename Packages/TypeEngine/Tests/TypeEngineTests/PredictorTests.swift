import XCTest

@testable import TypeEngine

final class PredictorTests: XCTestCase {

    func makePredictor() -> Predictor {
        Predictor(icelandic: Fixtures.icelandic, english: Fixtures.english)
    }

    func testBigramContextBeatsUnigramOrder() {
        let predictor = makePredictor()
        // Without context: "dag" (freq 100) is nowhere near the top.
        let cold = predictor.nextWords(previousWord: nil, pIcelandic: 0.9, limit: 3)
        XCTAssertFalse(cold.map(\.text).contains("dag"))
        // After "góðan", the bigram "góðan dag" (50) lifts "dag" to #1 even
        // though "og"/"að" dominate on raw unigram frequency.
        let contextual = predictor.nextWords(previousWord: "góðan", pIcelandic: 0.9, limit: 3)
        XCTAssertEqual(contextual.first?.text, "dag")
    }

    func testUnigramFallbackWhenContextUnknown() {
        let predictor = makePredictor()
        // Unknown previous word: degrade to top unigrams (IS-heavy posterior).
        let result = predictor.nextWords(previousWord: "xyzzy", pIcelandic: 0.9, limit: 2)
        XCTAssertEqual(result.first?.text, "og", "highest-frequency unigram should lead")
    }

    func testPosteriorBlendsLanguages() {
        let predictor = makePredictor()
        // English-leaning posterior surfaces English unigrams first.
        let english = predictor.nextWords(previousWord: nil, pIcelandic: 0.1, limit: 1)
        XCTAssertEqual(english.first?.text, "the")
        let icelandic = predictor.nextWords(previousWord: nil, pIcelandic: 0.9, limit: 1)
        XCTAssertEqual(icelandic.first?.text, "og")
    }

    func testMidWordCompletionsRerankedByContext() {
        let predictor = makePredictor()
        // Prefix "da" matches dag (100) and daginn (90). After "góðan",
        // the bigram pushes "dag" first.
        let result = predictor.completions(of: "da", previousWord: "góðan", pIcelandic: 0.9, limit: 2)
        XCTAssertEqual(result.first?.text, "dag")
        XCTAssertTrue(result.map(\.text).contains("daginn"))
    }

    func testContinuationsPoolSurfacesRareFollowers() {
        // "veður" (freq 5) is a rare unigram that would never make a
        // top-unigram pool, but it is a bigram follower of "gott" — the
        // continuations(of:limit:) pooling must surface it.
        let icelandic = DictLexicon(
            unigrams: ["og": 2000, "að": 1800, "er": 1500, "gott": 150, "veður": 5],
            bigrams: ["gott veður": 30]
        )
        let predictor = Predictor(icelandic: icelandic, english: Fixtures.english)
        let result = predictor.nextWords(previousWord: "gott", pIcelandic: 0.9, limit: 3)
        XCTAssertEqual(result.first?.text, "veður")
    }

    func testEmptyContinuationsDegradeToUnigramFallback() {
        // A lexicon that never implements continuations (the protocol's
        // default returns []) must degrade to the old top-unigram behavior,
        // not crash or go empty.
        let predictor = makePredictor()
        let result = predictor.nextWords(previousWord: "hestur", pIcelandic: 0.9, limit: 2)
        XCTAssertEqual(result.first?.text, "og", "no followers of hestur -> unigram fallback")
    }

    func testPredictionsNeverAutocorrect() {
        let predictor = makePredictor()
        let result = predictor.nextWords(previousWord: "góðan", pIcelandic: 0.5, limit: 3)
        XCTAssertFalse(result.contains { $0.isAutocorrect })
    }
}
