import Learning
import XCTest

@testable import TypeEngine

/// Per-user adaptive touch model (PLAN.md "Touch decoding", stage 2):
/// the shrinkage-blended per-key Gaussians in `PerTapCostProvider`, the
/// safety invariants (no-personal-data byte-parity, degenerate-stats
/// fallback, clamp bounds), the personal habitual-dy reference in the
/// space-substitution split penalty, the engine injection seam, and the
/// `Learning.PersonalModel` extraction path.
final class PersonalTouchTests: XCTestCase {

    let config = EngineConfig()
    var spatial: SpatialModel { SpatialModel(costs: config.spatialCosts) }

    /// Aligned tap record for `word` (dead center unless overridden).
    func taps(_ word: String, offsets: [Int: (Double, Double)] = [:]) -> [TapSample?] {
        Array(word).enumerated().map { index, char in
            let offset = offsets[index] ?? (0, 0)
            return TapSample(char: char, dxNorm: offset.0, dyNorm: offset.1)
        }
    }

    /// Prior-matching per-key stats: personal variances equal to the TSI
    /// prior, no covariance — only the MEAN carries personal signal.
    func priorShapedStats(
        meanDX: Double, meanDY: Double, count: Double
    ) -> PersonalTouchSnapshot.KeyStats {
        PersonalTouchSnapshot.KeyStats(
            meanDX: meanDX,
            meanDY: meanDY,
            varianceX: config.tapSigmaX * config.tapSigmaX,
            varianceY: config.tapSigmaY * config.tapSigmaY,
            covarianceXY: 0,
            count: count
        )
    }

    func provider(
        _ word: String,
        offsets: [Int: (Double, Double)] = [:],
        personal: PersonalTouchSnapshot? = nil
    ) -> PerTapCostProvider {
        PerTapCostProvider(
            taps: taps(word, offsets: offsets),
            spatial: spatial,
            config: config,
            personalTouch: personal
        )
    }

    /// The shared prior's Gaussian exponent at a point relative to a key
    /// center — the stage-1 closed form the shrinkage math must reproduce
    /// for prior-priced keys.
    func priorExponent(dx: Double, dy: Double) -> Double {
        dx * dx / (2 * config.tapSigmaX * config.tapSigmaX)
            + dy * dy / (2 * config.tapSigmaY * config.tapSigmaY)
    }

    // MARK: - Invariant: no personal data → byte-identical

    func testNilEmptyAndBelowGateSnapshotsAreByteIdenticalToStageOne() {
        let offsets = [0: (0.2, -0.1), 2: (0.45, 0.0)]
        let baseline = provider("hoke", offsets: offsets)
        let candidates: [PersonalTouchSnapshot?] = [
            nil,
            PersonalTouchSnapshot(keys: [:]),
            // Real stats, but below the 30-sample gate everywhere.
            PersonalTouchSnapshot(keys: [
                "k": priorShapedStats(meanDX: 0.4, meanDY: 0.4, count: 29),
                "o": priorShapedStats(meanDX: -0.4, meanDY: 0, count: 2),
            ]),
        ]
        for personal in candidates {
            let candidate = provider("hoke", offsets: offsets, personal: personal)
            for position in 0..<4 {
                XCTAssertEqual(
                    candidate.confidence(position: position),
                    baseline.confidence(position: position),
                    "confidence must be BYTE-identical without eligible personal keys"
                )
                for intended in SpatialModel.physicalKeys {
                    XCTAssertEqual(
                        candidate.substitutionCost(
                            position: position, typed: Array("hoke")[position],
                            intended: intended),
                        baseline.substitutionCost(
                            position: position, typed: Array("hoke")[position],
                            intended: intended),
                        "cost must be BYTE-identical without eligible personal keys"
                    )
                }
            }
            XCTAssertEqual(candidate.meanTapConfidence, baseline.meanTapConfidence)
        }
    }

    func testSnapshotPresenceWithoutTapsChangesNothingAtEngineLevel() {
        // The stage-2 snapshot only ever acts through tap evidence: with no
        // taps (every eval fixture, every scenario without TAP) the engine
        // must be EXACTLY the stage-1 engine, snapshot injected or not.
        let engine = Fixtures.engine()
        let before = engine.suggestions(context: "", currentWord: "hestr")
        engine.setPersonalTouch(
            PersonalTouchSnapshot(keys: [
                "e": priorShapedStats(meanDX: 0.3, meanDY: 0.3, count: 500)
            ])
        )
        let after = engine.suggestions(context: "", currentWord: "hestr")
        XCTAssertEqual(before, after, "no taps → the snapshot must be inert")
    }

    // MARK: - Invariant: degenerate/corrupt stats → static fallback

    func testDegenerateStatsFallBackToStaticPerKey() {
        let offsets = [1: (0.3, 0.1)]
        let baseline = provider("hoke", offsets: offsets)
        // Every corrupt shape the disk model could produce; 'z' is a valid
        // personal key far from this word's taps, so the personal table is
        // NON-empty and the per-key (not whole-provider) fallback is what
        // keeps o/k/e on the prior.
        let corrupt = PersonalTouchSnapshot(keys: [
            "o": PersonalTouchSnapshot.KeyStats(
                meanDX: 0, meanDY: 0, varianceX: -1, varianceY: 0.02,
                covarianceXY: 0, count: 500),
            "k": PersonalTouchSnapshot.KeyStats(
                meanDX: .nan, meanDY: 0, varianceX: 0.02, varianceY: 0.02,
                covarianceXY: 0, count: 500),
            "e": PersonalTouchSnapshot.KeyStats(
                meanDX: 0, meanDY: 0, varianceX: 0.02, varianceY: .infinity,
                covarianceXY: 0, count: 500),
            "h": PersonalTouchSnapshot.KeyStats(
                meanDX: 0, meanDY: 0, varianceX: 0.02, varianceY: 0.02,
                covarianceXY: .nan, count: 500),
            "z": priorShapedStats(meanDX: 0.1, meanDY: 0.1, count: 500),
        ])
        let candidate = provider("hoke", offsets: offsets, personal: corrupt)
        for (position, typed) in Array("hoke").enumerated() {
            for intended in ["p", "l", "j", "u", "r", "w"].map(Character.init) {
                XCTAssertEqual(
                    candidate.substitutionCost(position: position, typed: typed, intended: intended),
                    baseline.substitutionCost(position: position, typed: typed, intended: intended),
                    "corrupt \(typed) stats must price statically"
                )
            }
            // Confidence normalizes over the whole key set (which includes
            // the honest personal 'z'); 'z' is >5 key pitches from every
            // tap here so its reweighting is beyond double-precision noise.
            XCTAssertEqual(
                candidate.confidence(position: position),
                baseline.confidence(position: position),
                accuracy: 1e-12
            )
        }
    }

    // MARK: - Shrinkage math (the documented closed form)

    func testShrinkageBlendMatchesClosedForm() {
        // 'n' taps center 0.2 key pitches LOW (toward the spacebar), prior-
        // shaped variance, n=150 → w = 150/200 = 0.75 → blended center
        // +0.15 below the key center; blended variance = the prior, so the
        // log-determinant weight vanishes and costs are pure exponents.
        let personal = PersonalTouchSnapshot(keys: [
            "n": priorShapedStats(meanDX: 0, meanDY: 0.2, count: 150)
        ])

        // Tap AT the blended personal center: the resolved key fits
        // perfectly, so a prior-priced neighbor costs its full exponent.
        let atCenter = provider("n", offsets: [0: (0, 0.15)], personal: personal)
        // b is one key pitch left of n on the bottom row (both static).
        let expectedNllB = priorExponent(dx: 1.0, dy: 0.15)
        XCTAssertEqual(
            atCenter.substitutionCost(position: 0, typed: "n", intended: "b"),
            min(expectedNllB - 0, config.spatialCosts.maxSubstitution),
            accuracy: 1e-9,
            "cost must equal the closed-form likelihood ratio"
        )

        // Tap at the GEOMETRIC key center — 0.15 above this user's habitual
        // spot: the resolved key now pays that residual, so every
        // alternative cheapens by exactly the same nats.
        let atKeyCenter = provider("n", offsets: [0: (0, 0)], personal: personal)
        let residual = priorExponent(dx: 0, dy: -0.15)
        XCTAssertEqual(
            atKeyCenter.substitutionCost(position: 0, typed: "n", intended: "b"),
            priorExponent(dx: 1.0, dy: 0) - residual,
            accuracy: 1e-9
        )
        // And the static engine would NOT discount b here (its resolved
        // exponent is 0 at the key center) — the personal mean shift is
        // exactly the difference.
        let staticProvider = provider("n", offsets: [0: (0, 0)])
        XCTAssertEqual(
            staticProvider.substitutionCost(position: 0, typed: "n", intended: "b")
                - atKeyCenter.substitutionCost(position: 0, typed: "n", intended: "b"),
            residual,
            accuracy: 1e-9
        )
    }

    func testConfidenceUsesTheBlendedDistribution() {
        // A habitual low-tapper's low tap: unremarkable for THEM, boundary-
        // flavored for the static prior — personal confidence must be
        // strictly higher (the veto keeps protecting their habits).
        let personal = PersonalTouchSnapshot(keys: [
            "n": priorShapedStats(meanDX: 0, meanDY: 0.2, count: 500)
        ])
        let tapped = [0: (0.0, 0.35)]
        let personalConfidence = provider("n", offsets: tapped, personal: personal)
            .confidence(position: 0)
        let staticConfidence = provider("n", offsets: tapped).confidence(position: 0)
        XCTAssertGreaterThan(personalConfidence, staticConfidence)
    }

    // MARK: - Tight personal sigma

    func testTightSigmaRaisesNeighborCostsWithinClamps() {
        // σ = 0.02 key pitches (unrealistically tight, floored to 0.08):
        // a dead-center tap makes every neighbor maximally expensive — but
        // NEVER past maxSubstitution, and the accent twin still rides the
        // shared-key floor.
        let tight = PersonalTouchSnapshot(keys: [
            "o": PersonalTouchSnapshot.KeyStats(
                meanDX: 0, meanDY: 0, varianceX: 0.0004, varianceY: 0.0004,
                covarianceXY: 0, count: 1000)
        ])
        let perTap = provider("o", personal: tight)
        let neighbor = perTap.substitutionCost(position: 0, typed: "o", intended: "p")
        XCTAssertEqual(
            neighbor, config.spatialCosts.maxSubstitution,
            "tight-σ veto must saturate AT the existing clamp, not beyond")
        // ó shares o's key AND its personal Gaussian: ratio 0 → floor.
        XCTAssertEqual(
            perTap.substitutionCost(position: 0, typed: "o", intended: "ó"),
            config.spatialCosts.minSubstitution
        )
        XCTAssertGreaterThan(perTap.confidence(position: 0), 0.99)
        // Confidence stays a probability; the fold-evidence penalty stays
        // inside its cap (composition shape unchanged).
        XCTAssertLessThanOrEqual(perTap.confidence(position: 0), 1)
        XCTAssertLessThanOrEqual(
            perTap.foldEvidencePenalty(
                position: 0, cap: config.tapFoldConfidenceMaxPenalty),
            config.tapFoldConfidenceMaxPenalty
        )
    }

    func testVetoFactorStaysWithinExistingClampUnderPersonalStats() {
        let corrector = Corrector(
            icelandic: Fixtures.icelandic, english: Fixtures.english, morphology: nil)
        let tight = PersonalTouchSnapshot(keys: [
            "o": PersonalTouchSnapshot.KeyStats(
                meanDX: 0, meanDY: 0, varianceX: 0.0004, varianceY: 0.0004,
                covarianceXY: 0, count: 1000)
        ])
        let perTap = provider("hoke", personal: tight)
        let factor = corrector.tapVetoFactor(
            typedChars: Array("hoke"), candidate: "hike", perTap: perTap)
        XCTAssertGreaterThanOrEqual(factor, 1)
        XCTAssertLessThanOrEqual(factor, config.tapVetoMaxFactor)
    }

    // MARK: - Cross-covariance safety

    func testCorrelationIsClampedNotTrusted() {
        // A (corrupt or freak) |ρ| = 1 covariance would make Σ singular;
        // the clamp keeps the Gaussian proper and every cost finite and
        // inside the band.
        let varX = 0.04
        let varY = 0.03
        let singular = PersonalTouchSnapshot(keys: [
            "o": PersonalTouchSnapshot.KeyStats(
                meanDX: 0, meanDY: 0, varianceX: varX, varianceY: varY,
                covarianceXY: (varX * varY).squareRoot(),  // ρ = 1 exactly
                count: 1000)
        ])
        let perTap = provider("o", offsets: [0: (0.3, -0.2)], personal: singular)
        for intended in SpatialModel.physicalKeys {
            let cost = perTap.substitutionCost(position: 0, typed: "o", intended: intended)
            XCTAssertTrue(cost.isFinite)
            if intended != "o" {
                XCTAssertGreaterThanOrEqual(cost, config.spatialCosts.minSubstitution)
                XCTAssertLessThanOrEqual(cost, config.spatialCosts.maxSubstitution)
            }
        }
        let confidence = perTap.confidence(position: 0)
        XCTAssertTrue(confidence.isFinite)
        XCTAssertGreaterThanOrEqual(confidence, 0)
        XCTAssertLessThanOrEqual(confidence, 1)
    }

    // MARK: - Space-substitution split: habitual-dy reference

    func testSplitPenaltyReadsTapRelativeToHabitualDy() {
        func corrector(habitualMeanDy: Double?) -> Corrector {
            let touch = TouchModelStore()
            if let habitualMeanDy {
                touch.setSnapshot(
                    PersonalTouchSnapshot(keys: [
                        "b": priorShapedStats(meanDX: 0, meanDY: habitualMeanDy, count: 150)
                    ])
                )
            }
            let model = BlendedLanguageModel(
                icelandic: Fixtures.icelandic,
                english: Fixtures.english,
                morphology: nil,
                config: config,
                touch: touch
            )
            return Corrector(model: model, config: config)
        }

        // "erbgott" = "er" + (b consumed as space) + "gott"; the b tap sits
        // 0.2 below center.
        func splitCost(habitualMeanDy: Double?) -> Double? {
            corrector(habitualMeanDy: habitualMeanDy).splitCandidates(
                typedChars: Array("erbgott"),
                previousWord: nil,
                pIcelandic: 0.5,
                taps: taps("erbgott", offsets: [2: (0, 0.2)])
            ).first(where: { $0.word == "er gott" })?.spatialCost
        }

        guard
            let untrained = splitCost(habitualMeanDy: nil),
            let lowTapper = splitCost(habitualMeanDy: 0.2),  // blended +0.15
            let highTapper = splitCost(habitualMeanDy: -0.2)  // blended −0.15
        else { return XCTFail("er gott split hypothesis missing") }

        let slope = config.tapSpaceSplitSlope
        // No personal stats: stage-1 formula, byte-identical.
        XCTAssertEqual(
            untrained,
            config.splitSubstitutionPenalty
                + slope * (config.tapSpaceSplitNeutralDy - 0.2)
        )
        // Habitual low-tapper (blended habitual dy +0.15): this tap is only
        // 0.05 below THEIR center — weak space evidence, split pricier.
        XCTAssertEqual(untrained + slope * 0.15, lowTapper, accuracy: 1e-9)
        // Habitual high-tapper: the same tap is 0.35 below their center —
        // the split cheapens by exactly slope × 0.15 nats.
        XCTAssertEqual(untrained - slope * 0.15, highTapper, accuracy: 1e-9)
    }

    // MARK: - Ranking flip (the personal Gaussian does what the prior can't)

    /// hole/home lexicon from TouchDecodingTests. With dead-center taps the
    /// static prior prices "hoke"→"hole" (k→l, one key pitch, ~7.2 nats)
    /// below →"home" (k→m, a row apart, clamped at 8): hole leads and
    /// nothing auto-applies. A user whose m taps habitually land up-and-
    /// right (bottom-row under-reach) moves m's PERSONAL Gaussian toward
    /// the k key — the same dead-center k tap now reads as a plausible m,
    /// and "home" overtakes "hole" purely through the personal Gaussian
    /// (the ratio between two candidates moves ONLY when the intended
    /// keys' distributions differ — a mean shift on the resolved key alone
    /// discounts all rewrites equally and can never flip a ranking).
    func holeHomeEngine() -> TypeEngine {
        TypeEngine(
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
    }

    func testPersonalMeanShiftFlipsRankingTheStaticPriorCannot() {
        let engine = holeHomeEngine()
        let tapped = taps("hoke")  // all dead center

        let staticBar = engine.suggestions(context: "", currentWord: "hoke", taps: tapped)
        XCTAssertEqual(
            staticBar.first?.text, "hole",
            "static prior must lead with the same-row neighbor")
        XCTAssertFalse(staticBar.contains { $0.isAutocorrect })

        engine.setPersonalTouch(
            PersonalTouchSnapshot(keys: [
                "m": priorShapedStats(meanDX: 0.35, meanDY: -0.45, count: 500)
            ])
        )
        let personalBar = engine.suggestions(context: "", currentWord: "hoke", taps: tapped)
        XCTAssertEqual(
            personalBar.first?.text, "home",
            "personal k Gaussian must flip the lead to home, got \(personalBar)")

        // And clearing the snapshot restores the static ranking exactly.
        engine.setPersonalTouch(nil)
        XCTAssertEqual(
            engine.suggestions(context: "", currentWord: "hoke", taps: tapped),
            staticBar
        )
    }

    // MARK: - Engine injection seam

    func testInjectionRoundTripMirrorsPersonalVocabularyContract() {
        let engine = Fixtures.engine()
        XCTAssertNil(engine.personalTouchSnapshot)
        let snapshot = PersonalTouchSnapshot(keys: [
            "a": priorShapedStats(meanDX: 0.1, meanDY: 0.1, count: 40)
        ])
        engine.setPersonalTouch(snapshot)
        XCTAssertEqual(engine.personalTouchSnapshot, snapshot)
        engine.setPersonalTouch(nil)
        XCTAssertNil(engine.personalTouchSnapshot)
    }

    // MARK: - Learning extraction (synthetic personal model via the real API)

    func testSnapshotExtractionFromWelfordFedPersonalModel() throws {
        // Feed touchSample events through the REAL Learning pipeline
        // (EventLog append → PersonalModel.compact) and extract the
        // snapshot the extension would load — no hand-built aggregates.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("personal-touch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = EventLog(url: dir.appendingPathComponent("events.log"))
        var events: [LearningEvent] = []
        for i in 0..<40 {
            // dy alternates 0.15/0.25 around the 0.2 habitual offset.
            events.append(
                .touchSample(keyChar: "n", dx: 0, dy: i.isMultiple(of: 2) ? 0.15 : 0.25))
        }
        try log.append(contentsOf: events)
        let model = PersonalModel()
        try model.compact(applying: log)

        let snapshot = PersonalTouchSnapshot(model: model)
        guard let stats = snapshot.stats(for: "n") else {
            return XCTFail("n statistics missing from the extracted snapshot")
        }
        XCTAssertEqual(stats.count, 40, accuracy: 1e-9)
        XCTAssertEqual(stats.meanDY, 0.2, accuracy: 1e-9)
        XCTAssertEqual(stats.meanDX, 0, accuracy: 1e-9)
        // Unbiased sample variance of the alternating ±0.05 cloud.
        XCTAssertEqual(stats.varianceY, 0.05 * 0.05 * 40.0 / 39.0, accuracy: 1e-9)

        // Round-trip through the model FILE (the extension's load path):
        // identical snapshot.
        let modelURL = dir.appendingPathComponent("personal-model.json")
        try model.save(to: modelURL)
        let reloaded = try PersonalModel(contentsOf: modelURL)
        XCTAssertEqual(PersonalTouchSnapshot(model: reloaded), snapshot)

        // The extracted stats drive pricing end to end: count 40 clears the
        // gate, and a tap at the user's habitual low spot prices b higher
        // than the static prior would (nllResolved shrinks toward 0).
        let personalCost = provider("n", offsets: [0: (0, 0.15)], personal: snapshot)
            .substitutionCost(position: 0, typed: "n", intended: "b")
        let staticCost = provider("n", offsets: [0: (0, 0.15)])
            .substitutionCost(position: 0, typed: "n", intended: "b")
        XCTAssertGreaterThan(personalCost, staticCost)
    }
}
