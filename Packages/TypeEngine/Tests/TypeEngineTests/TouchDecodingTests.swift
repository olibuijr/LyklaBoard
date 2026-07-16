import XCTest

@testable import TypeEngine

/// Coordinate-level decoding (PLAN.md "Touch decoding", stage 1): the
/// per-tap cost provider's Gaussian math, the bidirectional evidence
/// behaviors through the corrector, the margin veto curve, the tap-scaled
/// space-substitution split penalty, and the TypingSession alignment +
/// touchSample emission pipeline.
final class TouchDecodingTests: XCTestCase {

    let config = EngineConfig()
    var spatial: SpatialModel { SpatialModel(costs: config.spatialCosts) }

    /// Aligned tap record for `word` with the given per-character offsets
    /// (default dead center).
    func taps(_ word: String, offsets: [Int: (Double, Double)] = [:]) -> [TapSample?] {
        Array(word).enumerated().map { index, char in
            let offset = offsets[index] ?? (0, 0)
            return TapSample(char: char, dxNorm: offset.0, dyNorm: offset.1)
        }
    }

    func provider(_ word: String, offsets: [Int: (Double, Double)] = [:]) -> PerTapCostProvider {
        PerTapCostProvider(taps: taps(word, offsets: offsets), spatial: spatial, config: config)
    }

    // MARK: - Provider math

    func testDeadCenterTapMakesNeighborSubstitutionExpensive() {
        // Static o→p (adjacent keys) is ~1 nat; a dead-center o tap prices
        // it near the Gaussian exponent of a full key pitch — the veto.
        let staticCost = spatial.substitutionCost(typed: "o", intended: "p")
        let perTap = provider("o")
        let cost = perTap.substitutionCost(position: 0, typed: "o", intended: "p")
        XCTAssertLessThan(staticCost, 1.5)
        XCTAssertGreaterThan(cost, 6.0, "dead-center tap must make the neighbor expensive")
        XCTAssertLessThanOrEqual(cost, config.spatialCosts.maxSubstitution)
    }

    func testBoundaryTapMakesStaticallyExpensiveSubstitutionCheap() {
        // k→m is a 1.25-key diagonal (static ~1.6 nats). A tap in k's
        // bottom-left corner (toward m) flips it BELOW the static price —
        // the enabling half of the bidirectional principle.
        let staticCost = spatial.substitutionCost(typed: "k", intended: "m")
        XCTAssertGreaterThan(staticCost, 1.5)
        let perTap = provider("k", offsets: [0: (-0.4, 0.45)])
        let cost = perTap.substitutionCost(position: 0, typed: "k", intended: "m")
        XCTAssertLessThan(cost, staticCost, "boundary tap toward m must undercut the static price")
        XCTAssertGreaterThanOrEqual(cost, config.spatialCosts.minSubstitution)
    }

    func testMissingTapFallsBackToStaticCostAndNeutralConfidence() {
        let perTap = PerTapCostProvider(
            taps: [nil, TapSample(char: "o", dxNorm: 0, dyNorm: 0)],
            spatial: spatial,
            config: config
        )
        XCTAssertEqual(
            perTap.substitutionCost(position: 0, typed: "o", intended: "p"),
            spatial.substitutionCost(typed: "o", intended: "p")
        )
        XCTAssertEqual(perTap.confidence(position: 0), 1.0)
        XCTAssertFalse(perTap.hasTap(at: 0))
        XCTAssertTrue(perTap.hasTap(at: 1))
    }

    func testTapCharMismatchFallsBackToStatic() {
        // Alignment drift paranoia: evidence recorded for a different
        // resolved character prices statically.
        let perTap = PerTapCostProvider(
            taps: [TapSample(char: "x", dxNorm: 0, dyNorm: 0)],
            spatial: spatial,
            config: config
        )
        XCTAssertEqual(
            perTap.substitutionCost(position: 0, typed: "o", intended: "p"),
            spatial.substitutionCost(typed: "o", intended: "p")
        )
    }

    func testOrthographicConfusionKeepsStaticCostRegardlessOfTap() {
        // d→ð is a cognitive slip; a dead-center d tap says nothing.
        let perTap = provider("d")
        XCTAssertEqual(
            perTap.substitutionCost(position: 0, typed: "d", intended: "ð"),
            config.spatialCosts.orthographicConfusion
        )
    }

    func testAccentTwinStaysAtFloor() {
        // a and á share the key: the likelihood ratio is 0, clamped to the
        // minSubstitution floor — identical to the static model.
        let perTap = provider("a")
        XCTAssertEqual(
            perTap.substitutionCost(position: 0, typed: "a", intended: "á"),
            config.spatialCosts.minSubstitution
        )
    }

    func testEqualCharactersCostZero() {
        XCTAssertEqual(provider("o").substitutionCost(position: 0, typed: "o", intended: "o"), 0)
    }

    func testConfidenceIsHighAtCenterAndSplitAtBoundary() {
        let center = provider("o").confidence(position: 0)
        XCTAssertGreaterThan(center, 0.95, "dead-center tap must be near-certain")
        // Mid-boundary between o and p: the two keys split the likelihood.
        let boundary = provider("o", offsets: [0: (0.5, 0)]).confidence(position: 0)
        XCTAssertEqual(boundary, 0.5, accuracy: 0.1)
        XCTAssertGreaterThan(provider("o").meanTapConfidence ?? 0, 0.95)
    }

    func testFoldEvidencePenaltyIsZeroWithoutTapsAndCapped() {
        let staticProvider = StaticSpatialCostProvider(spatial: spatial)
        XCTAssertEqual(staticProvider.foldEvidencePenalty(position: 0, cap: 2.5), 0)
        let sloppy = provider("a", offsets: [0: (0.5, 0.5)])
        let penalty = sloppy.foldEvidencePenalty(position: 0, cap: 2.5)
        XCTAssertGreaterThan(penalty, 0)
        XCTAssertLessThanOrEqual(penalty, 2.5)
        XCTAssertEqual(provider("a").foldEvidencePenalty(position: 0, cap: 2.5), 0, accuracy: 0.05)
    }

    // MARK: - Corrector: bidirectional behaviors

    /// Lexicon crafted so "hoke" has two 1-substitution candidates at the
    /// same position in different directions (hole: k→l right; home: k→m
    /// down-left) with equal frequency — statically margin-tied, so no
    /// auto-apply; the tap direction is the only disambiguator.
    func holeHomeCorrector() -> Corrector {
        let english = DictLexicon(
            unigrams: [
                "the": 2000, "and": 1500, "with": 900, "of": 800, "to": 700,
                "hole": 500, "home": 500,
            ],
            bigrams: [:]
        )
        return Corrector(icelandic: Fixtures.icelandic, english: english, morphology: nil)
    }

    func testStaticallyTiedCandidatesDoNotAutocorrect() {
        let result = holeHomeCorrector().correct(typed: "hoke")
        XCTAssertFalse(result.typedWordIsValid)
        XCTAssertFalse(
            result.suggestions.contains { $0.isAutocorrect },
            "hole/home must be margin-tied statically, got \(result.suggestions)"
        )
    }

    func testBoundaryTapEnablesAutocorrectTowardTheTappedNeighbor() {
        // Tap on k leaning right (toward l): "hole" becomes a floor-cost
        // substitution while "home" prices toward the cap — the correction
        // the static engine could not commit to now fires.
        let result = holeHomeCorrector().correct(
            typed: "hoke",
            taps: taps("hoke", offsets: [2: (0.45, 0)])
        )
        XCTAssertEqual(result.suggestions.first?.text, "hole")
        XCTAssertEqual(
            result.suggestions.first?.isAutocorrect, true,
            "boundary tap toward l must enable the hole auto-apply, got \(result.suggestions)"
        )
    }

    func testBoundaryTapDirectionPicksTheOtherNeighbor() {
        // Same word, tap leaning down-left (toward m): "home" leads instead.
        let result = holeHomeCorrector().correct(
            typed: "hoke",
            taps: taps("hoke", offsets: [2: (-0.4, 0.45)])
        )
        XCTAssertEqual(result.suggestions.first?.text, "home")
    }

    func testDeadCenterTapsVetoAutocorrectThatFiresStatically() {
        // Indel repair whose margin fires statically but sits below the
        // vetoed requirement: "hoes" → "holes" (omitted l, 4.0 nats — the
        // cost gate can't block indels, so the MARGIN veto is the active
        // guard). "hoses" is the runner-up that keeps the margin finite.
        let english = DictLexicon(
            unigrams: [
                "the": 2000, "and": 1500, "with": 900, "of": 800, "to": 700,
                "holes": 1200, "hoses": 80,
            ],
            bigrams: [:]
        )
        let corrector = Corrector(
            icelandic: Fixtures.icelandic, english: english, morphology: nil)
        let staticResult = corrector.correct(typed: "hoes")
        XCTAssertEqual(staticResult.suggestions.first?.text, "holes")
        XCTAssertEqual(
            staticResult.suggestions.first?.isAutocorrect, true,
            "static margin must fire, got \(staticResult.suggestions)"
        )
        // All-dead-center taps: the user hit h-o-e-s exactly — believe them.
        let tapped = corrector.correct(typed: "hoes", taps: taps("hoes"))
        XCTAssertFalse(
            tapped.suggestions.contains { $0.isAutocorrect },
            "dead-center taps must veto the auto-apply, got \(tapped.suggestions)"
        )
        // NOTE the deliberate bound of the veto (PLAN: "needs OVERWHELMING
        // evidence"): a margin past tapVetoMaxFactor × the base margin
        // (e.g. "teh" → "the", ~9 nats) still fires — the veto raises the
        // bar, it does not disable autocorrect.
    }

    // MARK: - Margin veto curve

    func testVetoFactorAggregatesOnlyContradictedPositions() {
        let corrector = holeHomeCorrector()
        let typed = Array("hoke")
        // Dead-center everywhere EXCEPT the edited position (boundary k):
        // only position 2 is rewritten by "hole", and its low confidence
        // keeps the margin at today's floor.
        let boundary = PerTapCostProvider(
            taps: taps("hoke", offsets: [2: (0.5, 0)]), spatial: spatial, config: config)
        let factor = corrector.tapVetoFactor(typedChars: typed, candidate: "hole", perTap: boundary)
        XCTAssertEqual(factor, 1.0, accuracy: 0.35)
        // Dead-center at the edited position: strong veto, near the clamp.
        let center = PerTapCostProvider(taps: taps("hoke"), spatial: spatial, config: config)
        let vetoed = corrector.tapVetoFactor(typedChars: typed, candidate: "hole", perTap: center)
        XCTAssertGreaterThan(vetoed, 3.5)
        XCTAssertLessThanOrEqual(vetoed, config.tapVetoMaxFactor)
        // No provider → exactly today's margins.
        XCTAssertEqual(corrector.tapVetoFactor(typedChars: typed, candidate: "hole", perTap: nil), 1)
    }

    func testVetoFactorIgnoresRestorationPairsAndSplitSpaces() {
        let corrector = holeHomeCorrector()
        // a→á is the lazy-input fold: dead-center taps must not veto it.
        let accent = PerTapCostProvider(taps: taps("giskar"), spatial: spatial, config: config)
        XCTAssertEqual(
            corrector.tapVetoFactor(
                typedChars: Array("giskar"), candidate: "gískar", perTap: accent),
            1.0
        )
        // A substitution-split's consumed letter (space in the candidate)
        // stays out of the veto — its evidence lives in the penalty.
        let split = PerTapCostProvider(taps: taps("erbgott"), spatial: spatial, config: config)
        XCTAssertEqual(
            corrector.tapVetoFactor(
                typedChars: Array("erbgott"), candidate: "er gott", perTap: split),
            1.0
        )
    }

    func testVetoFactorUsesWholeWordAggregateForLengthChangingRewrites() {
        let corrector = holeHomeCorrector()
        // Indel repair (candidate longer): an all-dead-center word vetoes
        // ANY rewrite via the whole-word aggregate.
        let center = PerTapCostProvider(taps: taps("hoes"), spatial: spatial, config: config)
        let factor = corrector.tapVetoFactor(
            typedChars: Array("hoes"), candidate: "holes", perTap: center)
        XCTAssertGreaterThan(factor, 3.5)
        XCTAssertLessThanOrEqual(factor, config.tapVetoMaxFactor)
    }

    // MARK: - Space-substitution split evidence

    func testSplitPenaltyScalesWithTapToSpacebarDistance() {
        let corrector = Corrector(
            icelandic: Fixtures.icelandic, english: Fixtures.english, morphology: nil)
        // "erbgott" = "er" + (b consumed as space) + "gott"; both halves in
        // the IS fixture. Compare the split channel cost across b-tap dy.
        func splitCost(dy: Double?) -> Double? {
            let tapRecord: [TapSample?] =
                dy.map { taps("erbgott", offsets: [2: (0, $0)]) } ?? []
            return corrector.splitCandidates(
                typedChars: Array("erbgott"),
                previousWord: nil,
                pIcelandic: 0.5,
                taps: tapRecord
            ).first(where: { $0.word == "er gott" })?.spatialCost
        }
        guard
            let untapped = splitCost(dy: nil),
            let bottomEdge = splitCost(dy: 0.5),
            let center = splitCost(dy: 0),
            let topEdge = splitCost(dy: -0.5)
        else {
            return XCTFail("er gott split hypothesis missing")
        }
        XCTAssertEqual(untapped, config.splitSubstitutionPenalty, accuracy: 1e-9)
        XCTAssertLessThan(bottomEdge, untapped, "tap at the spacebar edge strengthens the split")
        XCTAssertGreaterThan(center, untapped, "dead-center letter tap weakens the split")
        XCTAssertGreaterThan(topEdge, center)
        XCTAssertLessThanOrEqual(topEdge, config.splitInsertionPenalty)
        XCTAssertGreaterThanOrEqual(bottomEdge, config.tapSpaceSplitMinPenalty)
    }

    // MARK: - Session alignment + emission

    func sessionFixture() -> (session: TypingSession, engine: TypeEngine) {
        let engine = TypeEngine(
            icelandic: Fixtures.icelandic,
            english: DictLexicon(
                unigrams: [
                    "the": 2000, "and": 1500, "with": 900, "of": 800, "to": 700,
                    "hole": 500, "home": 500,
                ],
                bigrams: [:]
            ),
            morphologyProvider: nil
        )
        return (TypingSession(engine: engine), engine)
    }

    /// Drive one word through the session, tap-per-character, exactly like
    /// the extension: noteTap BEFORE the keystroke's suggestions pass.
    @discardableResult
    func typeWord(
        _ session: TypingSession,
        _ word: String,
        offsets: [Int: (Double, Double)],
        prefix: String = ""
    ) -> [Suggestion] {
        var window = prefix
        var bar: [Suggestion] = []
        for (index, char) in word.enumerated() {
            let offset = offsets[index] ?? (0, 0)
            session.noteTap(char: char, dx: offset.0, dy: offset.1)
            window.append(char)
            bar = session.suggestions(for: window)
        }
        return bar
    }

    func testSessionAlignsTapsAndEnablesCorrection() {
        let (session, _) = sessionFixture()
        let bar = typeWord(session, "hoke", offsets: [2: (0.45, 0)])
        let top = bar.first(where: { !$0.isVerbatim })
        XCTAssertEqual(top?.text, "hole")
        XCTAssertEqual(top?.isAutocorrect, true, "session-aligned boundary tap must enable hole")
    }

    func testSessionDeadCenterTapsSuppressAutocorrect() {
        let (session, _) = sessionFixture()
        let bar = typeWord(session, "hoke", offsets: [:])
        XCTAssertFalse(bar.contains { $0.isAutocorrect })
    }

    func testBackspaceRetiresItsTap() {
        let (session, _) = sessionFixture()
        typeWord(session, "hoke", offsets: [2: (0.45, 0)])
        // Backspace the e and the boundary-tapped k…
        session.suggestions(for: "hok")
        session.suggestions(for: "ho")
        // …then retype them WITHOUT taps: positions 2..3 must be static
        // again (no auto-apply from a stale boundary tap).
        session.suggestions(for: "hok")
        let bar = session.suggestions(for: "hoke")
        XCTAssertFalse(
            bar.contains { $0.isAutocorrect },
            "retyped characters must not inherit the backspaced tap, got \(bar)"
        )
    }

    func testExternalChangeClearsTapRecord() {
        let (session, _) = sessionFixture()
        typeWord(session, "hok", offsets: [2: (0.45, 0)])
        session.noteExternalTextChange()
        let bar = session.suggestions(for: "hoke")
        XCTAssertFalse(bar.contains { $0.isAutocorrect })
    }

    func testFirstKeystrokeOfFreshSessionKeepsItsTap() {
        // The first keystroke classifies `.external` (no trusted window);
        // its queued tap must still attach.
        let (session, _) = sessionFixture()
        session.noteTap(char: "h", dx: 0.3, dy: -0.2)
        session.suggestions(for: "h")
        let bar = typeWord(session, "oke", offsets: [1: (0.45, 0)], prefix: "h")
        // Position 2 of "hoke" is the boundary-tapped k (offsets index 1 of
        // "oke"): correction still enabled end to end.
        XCTAssertEqual(bar.first(where: { !$0.isVerbatim })?.text, "hole")
    }

    func testTouchSamplesEmittedForAsTypedCommit() {
        let (session, _) = sessionFixture()
        typeWord(session, "hoke", offsets: [0: (0.1, -0.1)])
        session.suggestions(for: "hoke ")  // commit as typed (no autocorrect armed)
        let events = session.drainLearningEvents()
        let touch = events.filter {
            if case .touchSample = $0 { return true } else { return false }
        }
        XCTAssertEqual(touch.count, 4, "one touchSample per tapped character, got \(events)")
        guard case .touchSample(let keyChar, let dx, let dy) = touch[0] else {
            return XCTFail("expected touchSample, got \(touch)")
        }
        XCTAssertEqual(keyChar, "h")
        XCTAssertEqual(dx, 0.1, accuracy: 1e-9)
        XCTAssertEqual(dy, -0.1, accuracy: 1e-9)
        XCTAssertTrue(
            events.contains {
                if case .wordCommitted(let word, _, _) = $0 { return word == "hoke" }
                return false
            },
            "touchSamples ride alongside the wordCommitted, got \(events)"
        )
    }

    func testNoTouchSamplesWhenSuggestionAccepted() {
        // An applied correction means the typed keys were errors: the
        // commit maps to suggestionAccepted and must carry NO touchSamples.
        let (session, _) = sessionFixture()
        typeWord(session, "hoke", offsets: [2: (0.45, 0)])
        session.suggestions(for: "hole ")  // the armed autocorrect applied
        let events = session.drainLearningEvents()
        XCTAssertTrue(
            events.contains {
                if case .suggestionAccepted = $0 { return true } else { return false }
            },
            "expected suggestionAccepted, got \(events)"
        )
        XCTAssertFalse(
            events.contains {
                if case .touchSample = $0 { return true } else { return false }
            },
            "corrected words must not train the touch model, got \(events)"
        )
    }

    func testNoTouchSamplesInSensitiveFields() {
        let (session, _) = sessionFixture()
        session.fieldKind = .url
        typeWord(session, "hoke", offsets: [0: (0.1, 0.1)])
        session.suggestions(for: "hoke ")
        XCTAssertFalse(session.hasPendingLearningEvents, "URL fields emit nothing")
    }

    // MARK: - Static parity

    func testNoTapsMatchesStaticEngineExactly() {
        // The absent-provider path must be EXACT: same suggestions, same
        // flags, same confidences (the eval byte-parity invariant).
        let corrector = Corrector(
            icelandic: Fixtures.icelandic, english: Fixtures.english, morphology: nil)
        for word in ["teh", "hestr", "islenska", "hoke", "godan", "veturr"] {
            let a = corrector.correct(typed: word)
            let b = corrector.correct(typed: word, taps: [])
            let c = corrector.correct(typed: word, taps: Array(repeating: nil, count: word.count))
            XCTAssertEqual(a.suggestions, b.suggestions, "empty taps must be exact for \(word)")
            XCTAssertEqual(a.suggestions, c.suggestions, "all-nil taps must be exact for \(word)")
        }
    }
}
