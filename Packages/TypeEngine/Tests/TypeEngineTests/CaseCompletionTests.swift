import LemmaCore
import XCTest

@testable import TypeEngine

/// Wave 23 — case-aware long-word completions (the Kirkjubæjarklaustur
/// split-case class): the supported-case rule, the no-substitution
/// speculative completion channel, the governed prefix-repair pass and the
/// split-case companion offer.
final class CaseCompletionTests: XCTestCase {

    // MARK: - Fixtures

    /// hestur paradigm + a split-case governor "á" (þgf location / þf
    /// motion — the flagship government shape) and a decided governor
    /// "frá" (dative, runner-up below the split threshold).
    private func makeFixture(
        config: EngineConfig = EngineConfig()
    ) -> (corrector: Corrector, paradigms: FakeParadigms) {
        let icelandic = DictLexicon(
            unigrams: [
                "og": 2000, "að": 1800, "er": 1500, "á": 1200, "frá": 900,
                "hestur": 500, "hesturinn": 100, "hestum": 30,
                "ketill": 300, "ketils": 40,
                "veður": 200,
            ]
        )
        let english = DictLexicon(unigrams: ["the": 2000, "and": 1500])
        let paradigms = FakeParadigms()
        paradigms.addNoun(
            lemma: "hestur",
            forms: [
                ("hestur", 0, false, false),
                ("hest", 1, false, false),
                ("hesti", 2, false, false),
                ("hests", 3, false, false),
                ("hesturinn", 0, false, true),
                ("hestum", 2, true, false),
            ]
        )
        // ketill: the þgf sibling "katli" is 3+ edits from every typed
        // shape below — reachable ONLY through the paradigm (the
        // Kirkjubæjarklaustur shape in miniature).
        paradigms.addNoun(
            lemma: "ketill",
            forms: [
                ("ketill", 0, false, false),
                ("ketil", 1, false, false),
                ("katli", 2, false, false),
                ("ketils", 3, false, false),
            ]
        )
        let governors = GovernorsModel(table: [
            "á": .init(
                mass: 5000,
                caseProbabilities: [0.13, 0.26, 0.55, 0.06],
                caseEntropyRatio: 0.82
            ),
            "frá": .init(
                mass: 5000,
                caseProbabilities: [0.10, 0.15, 0.68, 0.07],
                caseEntropyRatio: 0.70
            ),
        ])
        let inflection = InflectionStore()
        inflection.setModel(InflectionModel(paradigms: paradigms, governors: governors))
        let morphology = FakeMorphology([
            "hestur", "hest", "hesti", "hests", "hesturinn", "hestum",
            "ketill", "ketil", "katli", "ketils",
        ])
        let model = BlendedLanguageModel(
            icelandic: icelandic,
            english: english,
            morphology: morphology,
            config: config,
            inflection: inflection
        )
        return (Corrector(model: model, config: config), paradigms)
    }

    private func governorFit(
        _ fixture: (corrector: Corrector, paradigms: FakeParadigms),
        previousWord: String
    ) -> GovernorFit {
        let fit = fixture.corrector.model.inflection.governorFit(
            previousWord: previousWord,
            pIcelandic: 0.9,
            morphology: fixture.corrector.model.morphology,
            config: EngineConfig()
        )
        return fit!
    }

    // MARK: - Supported cases (the split-case rule)

    func testSplitGovernorSupportsTopTwoCases() {
        let fit = governorFit(makeFixture(), previousWord: "á")
        XCTAssertEqual(
            fit.supportedCaseCodes(minSecondProbability: 0.2), [2, 1],
            "á (þgf 0.55 / þf 0.26) is genuinely split: both cases supported")
    }

    func testDecidedGovernorSupportsOnlyTheDominantCase() {
        let fit = governorFit(makeFixture(), previousWord: "frá")
        XCTAssertEqual(
            fit.supportedCaseCodes(minSecondProbability: 0.2), [2],
            "frá (þgf 0.68, runner-up 0.15) is decided: single-case offer")
    }

    // MARK: - Speculative completion channel (no substitutions)

    func testTrailingJunkPlusCompletionPricesOnTheCompletionChannel() {
        let (corrector, _) = makeFixture()
        let config = EngineConfig()
        let pricing = FoldPricing.neutral(config: config)
        // typed "hestus" = stem "hestu" + junk s; candidate extends the
        // stem: one extra typed char (insertion constant) + completion
        // chars at the completion rate — far below the ordinary DP's
        // multi-omission reading.
        let cost = corrector.speculativeCompletionCost(
            typedChars: Array("hestus"), candidate: "hesturinn", pricing: pricing)
        // shared "hestu" + extra "s" (4.0) + completion "rinn" (4 × 0.5).
        XCTAssertEqual(cost.total, 6.0, accuracy: 1e-9)
        XCTAssertEqual(cost.restorationOps, 0, "completions are error-class")
    }

    func testCompletionChannelNeverReadsSubstitutions() {
        let (corrector, _) = makeFixture()
        let config = EngineConfig()
        let pricing = FoldPricing.neutral(config: config)
        // "hveru" → "hverjum" is the dev-corpus poison shape: sub u→j +
        // complete "um" would price ~2 nats and walk speculative
        // completions over honest single-edit repairs. The speculative
        // channel must not price below the honest ordinary reading by
        // way of a substitution — its no-sub DP reads insert-j (4.0),
        // match u, complete m (0.5).
        let ordinary = corrector.channelCost(
            typedChars: Array("hveru"), candidate: "hverjum", pricing: pricing)
        let speculative = corrector.speculativeCompletionCost(
            typedChars: Array("hveru"), candidate: "hverjum", pricing: pricing)
        XCTAssertEqual(speculative.total, min(ordinary.total, 4.5), accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(
            speculative.total, 4.0,
            "no substitution+completion composite may undercut the indel constant")
    }

    // MARK: - Corrector behavior

    func testSplitGovernorLiftsTheParadigmOnlySibling() {
        // Typed "ketilu" (OOV junk tail) after the split governor "á":
        // the trimmed-prefix pass pools "ketill" (frequency-ranked
        // nominative), and the case-sibling expansion of its unambiguous
        // lemma lifts the þgf "katli" — 3+ edits from the typed token,
        // reachable ONLY through the paradigm.
        let (corrector, _) = makeFixture()
        let result = corrector.correct(
            typed: "ketilu", previousWord: "á", pIcelandic: 0.9, limit: 5)
        let texts = result.suggestions.map(\.text)
        XCTAssertTrue(texts.contains("katli"), "þgf sibling must be offered, got \(texts)")
        XCTAssertFalse(
            result.suggestions.contains(where: \.isAutocorrect),
            "speculative completions are offers, never auto-applied")
    }

    func testAmbiguousLemmaNeverLiftsSiblings() {
        // Surface-form doctrine: a completion whose lemma attribution is
        // ambiguous offers only the attested surface. Register a second
        // homograph lemma over "hestur" — the sibling expansion must shut
        // off entirely (no hesti/hest in the bar beyond what the ordinary
        // passes produce for a 5-char token: hest via 1-edit deletion is
        // still legal; hesti — two edits away, only reachable through the
        // paradigm — must NOT be).
        let config = EngineConfig()
        let fixture = makeFixture(config: config)
        // Every pooled entry point to the ketill paradigm becomes a
        // homograph (the completions "ketill"/"ketils" and the beam
        // repair "ketil" are all expansion sources).
        for form in ["ketill", "ketil", "ketils"] {
            fixture.paradigms.analysesByForm[form]?.append(
                ParadigmAnalysis(
                    lemma: "ketilla", pos: .noun, genderCode: 1,
                    bundle: .noun(caseCode: 0))
            )
        }
        let result = fixture.corrector.correct(
            typed: "ketilu", previousWord: "á", pIcelandic: 0.9, limit: 5)
        XCTAssertFalse(
            result.suggestions.map(\.text).contains("katli"),
            "ambiguous lemma must not lift paradigm siblings")
    }

    func testNoGovernorKeepsTheSpeculativePassesInert() {
        let (corrector, _) = makeFixture()
        let withGovernor = corrector.correct(
            typed: "ketilu", previousWord: "á", pIcelandic: 0.9, limit: 5)
        let without = corrector.correct(
            typed: "ketilu", previousWord: "veður", pIcelandic: 0.9, limit: 5)
        XCTAssertTrue(withGovernor.suggestions.map(\.text).contains("katli"))
        XCTAssertFalse(
            without.suggestions.map(\.text).contains("katli"),
            "no governor signal → today's behavior unchanged")
    }
}
