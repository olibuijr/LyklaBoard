import XCTest

@testable import TypeEngine

final class EngineTests: XCTestCase {

    // MARK: Bilingual posterior

    func testPosteriorStartsNeutral() {
        XCTAssertEqual(Fixtures.engine().probabilityIcelandic, 0.5)
    }

    func testConfirmingEnglishWordsFavorsEnglishCandidates() {
        let engine = Fixtures.engine()
        // "gree" is ambiguous: completions "green" (EN) and "greeþ" (IS) are
        // spatially identical with equal in-language frequency.
        for word in ["the", "and", "with"] { engine.confirmWord(word) }
        XCTAssertLessThan(engine.probabilityIcelandic, 0.25)

        let suggestions = engine.suggestions(context: "", currentWord: "gree", limit: 2)
        let texts = suggestions.map(\.text)
        XCTAssertTrue(texts.contains("green") && texts.contains("greeþ"))
        XCTAssertEqual(texts.first, "green", "EN-leaning posterior must rank the English twin first")
    }

    func testConfirmingIcelandicWordsFavorsIcelandicCandidates() {
        let engine = Fixtures.engine()
        for word in ["og", "að", "ekki"] { engine.confirmWord(word) }
        XCTAssertGreaterThan(engine.probabilityIcelandic, 0.75)

        let suggestions = engine.suggestions(context: "", currentWord: "gree", limit: 2)
        XCTAssertEqual(suggestions.first?.text, "greeþ")
    }

    func testPosteriorNeverSaturatesPast90_10() {
        let engine = Fixtures.engine()
        for _ in 0..<50 { engine.confirmWord("the") }
        XCTAssertEqual(engine.probabilityIcelandic, 0.1, accuracy: 1e-9)
        for _ in 0..<50 { engine.confirmWord("og") }
        XCTAssertEqual(engine.probabilityIcelandic, 0.9, accuracy: 1e-9)
    }

    func testUnknownWordsDoNotMoveThePosterior() {
        let engine = Fixtures.engine()
        engine.confirmWord("xyzzyq")
        XCTAssertEqual(engine.probabilityIcelandic, 0.5)
    }

    func testResetLanguagePosterior() {
        let engine = Fixtures.engine()
        engine.confirmWord("the")
        engine.resetLanguagePosterior()
        XCTAssertEqual(engine.probabilityIcelandic, 0.5)
    }

    // MARK: Conservatism through the facade

    func testValidWordsInEitherLanguageNeverAutocorrect() {
        let engine = Fixtures.engine(morphology: FakeMorphology(["hestunum"]))
        for word in ["borða", "the", "with", "hestur", "hestunum"] {
            let suggestions = engine.suggestions(context: "", currentWord: word, limit: 3)
            XCTAssertFalse(
                suggestions.contains { $0.isAutocorrect },
                "\(word) is valid and must never be auto-replaced"
            )
        }
    }

    func testUnknownTypoWithHighMarginAutocorrects() {
        let engine = Fixtures.engine()
        let suggestions = engine.suggestions(context: "", currentWord: "teh", limit: 3)
        XCTAssertEqual(suggestions.first?.text, "the")
        XCTAssertEqual(suggestions.first?.isAutocorrect, true)
    }

    // MARK: Facade plumbing

    func testEmptyCurrentWordPredictsNextWord() {
        let engine = Fixtures.engine()
        let suggestions = engine.suggestions(context: "góðan", currentWord: "", limit: 3)
        XCTAssertEqual(suggestions.first?.text, "dag")
        XCTAssertFalse(suggestions.contains { $0.isAutocorrect })
    }

    func testContextPunctuationIsStripped() {
        let engine = Fixtures.engine()
        let suggestions = engine.suggestions(context: "Halló! Góðan,", currentWord: "", limit: 3)
        XCTAssertEqual(suggestions.first?.text, "dag")
    }

    func testLeadingCapitalizationIsPreserved() {
        let engine = Fixtures.engine()
        let suggestions = engine.suggestions(context: "", currentWord: "Teh", limit: 1)
        XCTAssertEqual(suggestions.first?.text, "The")
    }

    func testLimitIsRespected() {
        let engine = Fixtures.engine()
        XCTAssertLessThanOrEqual(engine.suggestions(context: "", currentWord: "hest", limit: 2).count, 2)
        XCTAssertLessThanOrEqual(engine.suggestions(context: "", currentWord: "", limit: 3).count, 3)
    }
}
