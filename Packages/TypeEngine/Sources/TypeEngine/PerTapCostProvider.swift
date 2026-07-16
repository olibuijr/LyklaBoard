import Foundation

/// One captured keystroke touch point (PLAN.md "Touch decoding", stage 1).
///
/// `dxNorm`/`dyNorm` are within-key normalized offsets from the RESOLVED
/// key's center: −0.5…+0.5 at the key's touch-cell edges (the cell spans
/// the full key pitch, visual insets included), x growing rightward and y
/// growing DOWNWARD (toward the spacebar) — the same convention as the
/// ReplayRig TSI traces (`tsi-distributions.json`) and
/// `Learning.LearningEvent.touchSample`.
///
/// `char` is the resolved character, lowercased by the producer
/// (`TypingSession.noteTap`).
public struct TapSample: Equatable, Sendable {
    public let char: Character
    public let dxNorm: Double
    public let dyNorm: Double

    public init(char: Character, dxNorm: Double, dyNorm: Double) {
        self.char = char
        self.dxNorm = dxNorm
        self.dyNorm = dyNorm
    }
}

/// The coordinate-evidence `PositionCostProvider` (PLAN.md "Touch
/// decoding", stage 1 — the provider the `BeamDecoder` seam was built for).
///
/// Substitution pricing: a 2D axis-aligned Gaussian at the ACTUAL tap
/// point, σ seeded from the Google TSI within-key distributions
/// (`EngineConfig.tapSigmaX`/`tapSigmaY`; tunable). Costs are LOG-LIKELIHOOD
/// RATIOS against the resolved key, so the protocol's "0 when equal"
/// convention holds and the price works BOTH ways (the bidirectional
/// evidence principle):
///
///  * a tap near the boundary toward a neighbor makes that neighbor's
///    substitution cheap — down to the `minSubstitution` floor, well below
///    the ~1-nat static key-distance price (corrections get ENABLED),
///  * a dead-center tap prices every neighbor substitution near the
///    Gaussian exponent of a full key pitch (≈ 7 nats at the TSI σx),
///    capped at `maxSubstitution` — the correction VETO: believe the user.
///
/// Deliberate carve-outs:
///  * positions with no usable tap (nil sample, char/alignment drift, or a
///    character with no key position) fall back to the static
///    `SpatialModel` cost — absent evidence must not change behavior,
///  * orthographic-confusion pairs (d→ð, t→þ, o→ö, ð↔þ) keep the static
///    confusion constant regardless of the tap: those are COGNITIVE slips —
///    the user deliberately hit the key they (wrongly) believed right, so
///    the tap point carries no information about the confusion,
///  * accent twins share their base key's center, so their likelihood
///    ratio is 0 and the `minSubstitution` floor applies — identical to the
///    static model by construction.
///
/// `confidence(position:)` is the tap's NORMALIZED likelihood of the
/// resolved key over all physical keys (dead-center → ≈1, mid-boundary
/// between two keys → ≈0.5); positions without a tap report 1.0 exactly
/// (the static provider's constant), so no-tap words aggregate to a
/// neutral margin factor. The corrector aggregates these into the
/// autocorrect-margin veto and the fold-pricing evidence penalty.
///
/// NEXT STEP (M2 stage 2, deliberately NOT here yet): per-user Gaussians.
/// `TypingSession` already emits touchSample events and `PersonalModel
/// .TouchKeyStats` accumulates per-key (mean offset, covariance) from
/// them — once enough mass exists, this provider should score against the
/// PERSONAL per-key distribution (mean-shifted center, per-key σ, the
/// covariance term) instead of the shared TSI-seeded axis-aligned σ, with
/// the TSI values as the prior/fallback for cold keys. That swap needs:
/// a snapshot of TouchKeyStats plumbed alongside `PersonalVocabulary`
/// (engine injection point exists: `TypeEngine.setPersonalVocabulary`),
/// a minimum-effective-count gate per key, and eval coverage via the
/// ReplayRig synthetic tap clouds. The provider seam means none of that
/// touches the beam or the DP.
struct PerTapCostProvider: PositionCostProvider {

    /// Precomputed per-position evidence; nil where no usable tap exists.
    private struct Evidence {
        /// The resolved character the tap was recorded for (alignment guard).
        let char: Character
        /// Tap point in key-grid units (key center + normalized offsets).
        let point: SIMD2<Double>
        /// Gaussian exponent (−log likelihood, up to the shared constant)
        /// of the tap at the RESOLVED key's center.
        let nllResolved: Double
        /// Normalized likelihood of the resolved key at this tap.
        let confidence: Double
    }

    private let spatial: SpatialModel
    private let evidence: [Evidence?]
    private let invTwoSigmaX2: Double
    private let invTwoSigmaY2: Double
    private let minSubstitution: Double
    private let maxSubstitution: Double
    private let orthographicConfusion: Double

    /// Mean confidence over the positions that HAVE taps; nil when none
    /// do. The corrector's margin-veto aggregate.
    let meanTapConfidence: Double?

    /// - Parameter taps: per typed-position samples, aligned with the
    ///   (lowercased) typed word; nil entries fall back to static pricing.
    init(taps: [TapSample?], spatial: SpatialModel, config: EngineConfig) {
        self.spatial = spatial
        let costs = config.spatialCosts
        self.minSubstitution = costs.minSubstitution
        self.maxSubstitution = costs.maxSubstitution
        self.orthographicConfusion = costs.orthographicConfusion
        let ix = 1.0 / (2.0 * config.tapSigmaX * config.tapSigmaX)
        let iy = 1.0 / (2.0 * config.tapSigmaY * config.tapSigmaY)
        self.invTwoSigmaX2 = ix
        self.invTwoSigmaY2 = iy

        func exponent(from point: SIMD2<Double>, to center: SIMD2<Double>) -> Double {
            let d = point - center
            return d.x * d.x * ix + d.y * d.y * iy
        }

        var evidence: [Evidence?] = []
        evidence.reserveCapacity(taps.count)
        var confidenceSum = 0.0
        var confidenceCount = 0
        for tap in taps {
            guard let tap, let center = spatial.keyCenter(of: tap.char) else {
                evidence.append(nil)
                continue
            }
            let point = center + SIMD2(tap.dxNorm, tap.dyNorm)
            let nllResolved = exponent(from: point, to: center)
            // Normalized likelihood of the resolved key over the physical
            // key set (accent twins share centers and are not separate
            // targets — summing them would double-count their base key).
            var total = 0.0
            for key in SpatialModel.physicalKeys {
                guard let keyCenter = spatial.keyCenter(of: key) else { continue }
                total += exp(-exponent(from: point, to: keyCenter))
            }
            let confidence =
                total > 0 ? min(max(exp(-nllResolved) / total, 0), 1) : 1.0
            evidence.append(
                Evidence(
                    char: tap.char,
                    point: point,
                    nllResolved: nllResolved,
                    confidence: confidence
                )
            )
            confidenceSum += confidence
            confidenceCount += 1
        }
        self.evidence = evidence
        self.meanTapConfidence =
            confidenceCount > 0 ? confidenceSum / Double(confidenceCount) : nil
    }

    func substitutionCost(position: Int, typed: Character, intended: Character) -> Double {
        if typed == intended { return 0 }
        // Cognitive, not spatial (see type doc): the static constant.
        if SpatialModel.confusionPairs.contains(String(typed) + String(intended)) {
            return orthographicConfusion
        }
        guard
            position >= 0, position < evidence.count,
            let evidence = evidence[position],
            evidence.char == typed,
            let intendedCenter = spatial.keyCenter(of: intended)
        else {
            return spatial.substitutionCost(typed: typed, intended: intended)
        }
        let d = evidence.point - intendedCenter
        let nllIntended = d.x * d.x * invTwoSigmaX2 + d.y * d.y * invTwoSigmaY2
        // Log-likelihood ratio vs the resolved key ("0 when equal" holds by
        // construction), clamped into the static cost band so the beam's
        // caps/gates keep their calibrated meaning.
        let ratio = nllIntended - evidence.nllResolved
        return min(max(ratio, minSubstitution), maxSubstitution)
    }

    func confidence(position: Int) -> Double {
        guard position >= 0, position < evidence.count, let evidence = evidence[position] else {
            return 1.0
        }
        return evidence.confidence
    }

    /// Whether the position carries usable tap evidence (vs the static
    /// fallback). The margin veto only aggregates over these.
    func hasTap(at position: Int) -> Bool {
        position >= 0 && position < evidence.count && evidence[position] != nil
    }
}

extension PositionCostProvider {
    /// Evidence penalty a tap's confidence MULTIPLIES into the fold-pricing
    /// likelihood (−ln confidence in nats, capped): 0 for tapless positions
    /// and dead-center taps, up to `cap` for sloppy ones. See
    /// `FoldPricing`'s composition doc and `EngineConfig
    /// .tapFoldConfidenceMaxPenalty`.
    func foldEvidencePenalty(position: Int, cap: Double) -> Double {
        let confidence = self.confidence(position: position)
        guard confidence < 1 else { return 0 }
        return min(-log(max(confidence, 1e-9)), cap)
    }
}
