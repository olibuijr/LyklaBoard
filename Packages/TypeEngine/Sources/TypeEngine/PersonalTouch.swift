import Foundation
import Learning

/// Engine-facing snapshot of the user's per-key adaptive touch statistics
/// (PLAN.md "Touch decoding", stage 2) — the touch twin of
/// `PersonalSnapshot`/`PersonalVocabulary`.
///
/// One immutable value per personal-model load: per physical key, the mean
/// tap offset from the key center, the tap variances, the cross-covariance
/// and the effective (decayed) sample count, all in the shared normalized
/// key-pitch convention (1.0 = one key pitch, x right / y down — the same
/// units as `TapSample` and `Learning.TouchKeyStats`).
///
/// Consumed by `PerTapCostProvider`: keys whose effective count clears
/// `EngineConfig.touchPersonalMinSamples` are priced against a PERSONAL 2D
/// Gaussian — the TSI-seeded static prior shrunk toward the user's own
/// distribution by n/(n + touchPriorStrength) — instead of the shared
/// axis-aligned prior. Keys below the gate (and every key when no snapshot
/// is injected) keep the static prior byte-identically.
///
/// Threading: a plain `Sendable` value. Swaps happen via
/// `TypeEngine.setPersonalTouch` on the engine's owning queue — the exact
/// confinement contract of `setPersonalVocabulary`.
public struct PersonalTouchSnapshot: Equatable, Sendable {

    /// Raw per-key statistics, as accumulated by `Learning.TouchKeyStats`
    /// (bivariate Welford + exponential forgetting). Values are consumed
    /// through the stage-2 shrinkage blend, never verbatim — see
    /// `PerTapCostProvider`. Construction sanitizes nothing beyond types;
    /// the provider guards degenerate values (non-finite, negative
    /// variance, near-singular covariance) per key and falls back to the
    /// static prior, so a corrupt model file can never poison pricing.
    public struct KeyStats: Equatable, Sendable {
        /// Mean tap offset from the key center, key-pitch units.
        public let meanDX: Double
        public let meanDY: Double
        /// Unbiased sample variances of the offsets (key-pitch² units).
        public let varianceX: Double
        public let varianceY: Double
        /// Sample cross-covariance of (dx, dy).
        public let covarianceXY: Double
        /// Effective (decay-scaled) sample count.
        public let count: Double

        public init(
            meanDX: Double,
            meanDY: Double,
            varianceX: Double,
            varianceY: Double,
            covarianceXY: Double,
            count: Double
        ) {
            self.meanDX = meanDX
            self.meanDY = meanDY
            self.varianceX = varianceX
            self.varianceY = varianceY
            self.covarianceXY = covarianceXY
            self.count = count
        }
    }

    private let statsByKey: [Character: KeyStats]

    public init(keys: [Character: KeyStats]) {
        self.statsByKey = keys
    }

    /// Extract the touch statistics from a loaded `Learning.PersonalModel`
    /// (the same exclusively-owned, read-only copy `PersonalSnapshot`
    /// wraps — one file load feeds both snapshots, no extra I/O).
    ///
    /// Keys with fewer than 2 effective samples are dropped here (no
    /// defined variance; they could never clear the min-samples gate), and
    /// non-finite aggregates are dropped defensively.
    public init(model: PersonalModel) {
        var keys: [Character: KeyStats] = [:]
        for char in model.touchKeys {
            guard
                let stats = model.touchStatistics(for: char),
                let varianceX = stats.varianceDX,
                let varianceY = stats.varianceDY,
                let covariance = stats.covarianceDXDY
            else { continue }
            let entry = KeyStats(
                meanDX: stats.meanDX,
                meanDY: stats.meanDY,
                varianceX: varianceX,
                varianceY: varianceY,
                covarianceXY: covariance,
                count: stats.count
            )
            guard
                entry.count.isFinite, entry.meanDX.isFinite, entry.meanDY.isFinite,
                entry.varianceX.isFinite, entry.varianceY.isFinite,
                entry.covarianceXY.isFinite
            else { continue }
            keys[char] = entry
        }
        self.statsByKey = keys
    }

    public var isEmpty: Bool { statsByKey.isEmpty }

    /// Keys carrying statistics, sorted (deterministic diagnostics order).
    public var keys: [Character] {
        statsByKey.keys.sorted()
    }

    /// Statistics for `char`'s PHYSICAL key: accent twins (á, é, …) share
    /// their base key's touch target, so they resolve to the base key's
    /// statistics — the same sharing rule as `SpatialModel.keyCenter`.
    public func stats(for char: Character) -> KeyStats? {
        statsByKey[char] ?? SpatialModel.accentBase[char].flatMap { statsByKey[$0] }
    }

    /// Total effective sample mass across keys (diagnostics/QA logging).
    public var totalEffectiveSamples: Double {
        statsByKey.values.reduce(0) { $0 + $1.count }
    }
}

extension PersonalTouchSnapshot {
    /// The shrunk (blended) mean tap offset for `char`'s physical key under
    /// the stage-2 gate: nil below `touchPersonalMinSamples` or for
    /// non-finite stats; otherwise n/(n+k) of the personal mean (the prior
    /// mean is the key center, i.e. zero offset). Shared by the provider's
    /// Gaussian centers and the space-substitution split's habitual-dy
    /// reference so both read the SAME personal center.
    func blendedMeanOffset(for char: Character, config: EngineConfig) -> SIMD2<Double>? {
        guard
            let stats = stats(for: char),
            stats.count.isFinite,
            stats.count >= config.touchPersonalMinSamples
        else { return nil }
        let weight = stats.count / (stats.count + config.touchPriorStrength)
        let dx = weight * stats.meanDX
        let dy = weight * stats.meanDY
        guard dx.isFinite, dy.isFinite else { return nil }
        return SIMD2(dx, dy)
    }
}

/// Engine-internal mutable holder for the personal touch snapshot — the
/// touch twin of `PersonalStore`/`InflectionStore`: shared BY REFERENCE
/// across the engine's corrector copies, so a snapshot swap on the engine
/// queue is a single assignment (no rebuild, no recalibration). All access
/// is confined to the engine's owning queue (see `TypeEngine` docs).
final class TouchModelStore {
    private(set) var snapshot: PersonalTouchSnapshot?

    func setSnapshot(_ snapshot: PersonalTouchSnapshot?) {
        self.snapshot = snapshot
    }
}
