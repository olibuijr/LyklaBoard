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

    // MARK: Two-lane switching model (stickiness, flips, decay)

    /// Saturate the lane Icelandic with three strong IS words.
    private func icelandicLaneEngine() -> TypeEngine {
        let engine = Fixtures.engine()
        for word in ["og", "að", "er"] { engine.confirmWord(word) }
        XCTAssertEqual(engine.probabilityIcelandic, 0.9, accuracy: 1e-9)
        return engine
    }

    func testSingleOffLaneWordDoesNotFlipLane() {
        // One sletta from a saturated IS lane: a bounded nudge, never a
        // flip — the capped emission + low switch prior guarantee P(IS)
        // stays above 0.6.
        let engine = icelandicLaneEngine()
        engine.confirmWord("the")
        XCTAssertGreaterThan(engine.probabilityIcelandic, 0.6)
        XCTAssertLessThan(engine.probabilityIcelandic, 0.9)
    }

    func testThreeConsecutiveOffLaneWordsFlipLane() {
        // A sustained switch DOES flip the lane: three strongly-EN words
        // from a saturated IS lane push P(EN) past 0.7.
        let engine = icelandicLaneEngine()
        for word in ["the", "and", "with"] { engine.confirmWord(word) }
        XCTAssertLessThan(engine.probabilityIcelandic, 0.3)
    }

    func testLaneRecoversAfterSingleSletta() {
        // IS run, one EN word, then IS again: the lane snaps back.
        let engine = icelandicLaneEngine()
        engine.confirmWord("the")
        engine.confirmWord("og")
        XCTAssertGreaterThan(engine.probabilityIcelandic, 0.7)
    }

    func testNonEvidenceWordOnlyDecaysLaneTowardNeutral() {
        // OOV words have uniform emissions: only the transition step
        // applies — one step of decay toward 0.5, exactly
        // (1-s)·p + s·(1-p), never a pull toward either language.
        let engine = icelandicLaneEngine()
        engine.confirmWord("xyzzyq")
        let s = engine.config.laneSwitchProbability
        XCTAssertEqual(engine.probabilityIcelandic, (1 - s) * 0.9 + s * 0.1, accuracy: 1e-9)
    }

    func testSentenceBoundaryDecayRelaxesButDoesNotReset() {
        let engine = icelandicLaneEngine()
        engine.noteSentenceBoundary()
        let d = engine.config.laneBoundaryDecay
        XCTAssertEqual(engine.probabilityIcelandic, 0.5 + 0.4 * (1 - d), accuracy: 1e-9)
        XCTAssertGreaterThan(engine.probabilityIcelandic, 0.7, "boundary must relax, not reset")
    }

    func testSentenceBoundaryDecayIsNeutralAtPrior() {
        let engine = Fixtures.engine()
        engine.noteSentenceBoundary()
        XCTAssertEqual(engine.probabilityIcelandic, 0.5)
    }

    func testOffLaneCandidatesRemainReachableFromSaturatedLane() {
        // Candidate starvation guard: even at the IS ceiling, an
        // unambiguously English input still surfaces the English word
        // (discounted, not blocked).
        let engine = icelandicLaneEngine()
        let texts = engine.suggestions(context: "", currentWord: "gree", limit: 3).map(\.text)
        XCTAssertTrue(texts.contains("green"), "off-lane candidate must stay reachable: \(texts)")
    }

    // MARK: Posterior discipline (strong attribution only)

    func testNoiseTierSingleLexiconWordDoesNotMovePosterior() {
        // "dont" attested only as junk in the Icelandic table (web noise —
        // the harness "dont drags posterior toward IS" finding): far below
        // the lexicon's own distribution, so it is NOT Icelandic evidence.
        var unigrams = ["dont": UInt32(1)]
        for (word, freq) in ["og": UInt32(2000), "að": 1800, "er": 1500, "ekki": 900,
                             "hestur": 500, "hús": 400, "takk": 350, "borða": 300] {
            unigrams[word] = freq
        }
        let engine = TypeEngine(
            icelandic: DictLexicon(unigrams: unigrams),
            english: Fixtures.english,
            morphologyProvider: nil
        )
        engine.confirmWord("dont")
        XCTAssertEqual(engine.probabilityIcelandic, 0.5, "junk-tier word must not move the posterior")
    }

    func testAmbiguousBothKnownWordDoesNotMovePosterior() {
        // Known in both lexicons at comparable within-lexicon typicality:
        // no clear margin, no update.
        let engine = TypeEngine(
            icelandic: DictLexicon(unigrams: ["bar": 300, "og": 2000, "er": 1500, "hestur": 500]),
            english: DictLexicon(unigrams: ["bar": 300, "the": 2000, "and": 1500, "with": 900]),
            morphologyProvider: nil
        )
        engine.confirmWord("bar")
        XCTAssertEqual(engine.probabilityIcelandic, 0.5, "ambiguous word must not move the posterior")
    }

    func testBothKnownWordWithClearMarginMovesPosterior() {
        // Head word in EN, junk-tier in IS: strong EN attribution.
        let engine = TypeEngine(
            icelandic: DictLexicon(unigrams: ["the": 1, "og": 2000, "er": 1500, "hestur": 500]),
            english: Fixtures.english,
            morphologyProvider: nil
        )
        engine.confirmWord("the")
        XCTAssertLessThan(engine.probabilityIcelandic, 0.5)
    }

    func testBinOnlyValidWordDoesNotMovePosterior() {
        // Morphologically valid but unattested in the frequency tables:
        // BÍN's 3M surface forms collide with English-looking junk (BÍN
        // knows "dont"), so morphology alone is NOT posterior evidence —
        // only corpus attestation is.
        let engine = Fixtures.engine(morphology: FakeMorphology(["hestunum"]))
        engine.confirmWord("hestunum")
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
