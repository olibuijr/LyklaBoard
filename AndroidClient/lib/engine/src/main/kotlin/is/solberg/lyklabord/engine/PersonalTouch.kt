package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfig
import `is`.solberg.lyklabord.engine.learning.PersonalModel

/** Immutable engine-facing snapshot of per-key adaptive touch statistics. */
class PersonalTouchSnapshot(keys: Map<Char, KeyStats>) {
    /** Raw bivariate Welford aggregates for one physical key. */
    data class KeyStats(
        val meanDX: Double,
        val meanDY: Double,
        val varianceX: Double,
        val varianceY: Double,
        val covarianceXY: Double,
        val count: Double,
    )

    private val statsByKey: Map<Char, KeyStats> = keys.toMap()

    /** Extract touch statistics from an exclusively-owned personal model snapshot. */
    constructor(model: PersonalModel) : this(extractStats(model))

    val isEmpty: Boolean
        get() = statsByKey.isEmpty()

    /** Keys carrying statistics, sorted for deterministic diagnostics. */
    val keys: List<Char>
        get() = statsByKey.keys.sorted()

    /** Statistics for a physical key; acute accent twins resolve to their base key. */
    fun stats(char: Char): KeyStats? = statsByKey[char] ?: SpatialModel.accentBase[char]?.let(statsByKey::get)

    /** Total effective sample mass across all keys. */
    val totalEffectiveSamples: Double
        get() = statsByKey.values.fold(0.0) { total, stats -> total + stats.count }

    override fun equals(other: Any?): Boolean =
        other is PersonalTouchSnapshot && statsByKey == other.statsByKey

    override fun hashCode(): Int = statsByKey.hashCode()

    /**
     * Shrunk personal mean offset. Returns null below the personal sample gate or
     * when the aggregate is non-finite.
     */
    internal fun blendedMeanOffset(char: Char, config: EngineConfig): Pair<Double, Double>? {
        val stats = stats(char) ?: return null
        if (!stats.count.isFinite() || stats.count < config.touchPersonalMinSamples) return null
        val weight = stats.count / (stats.count + config.touchPriorStrength)
        val dx = weight * stats.meanDX
        val dy = weight * stats.meanDY
        if (!dx.isFinite() || !dy.isFinite()) return null
        return dx to dy
    }

    private companion object {
        fun extractStats(model: PersonalModel): Map<Char, KeyStats> {
            val keys = mutableMapOf<Char, KeyStats>()
            for (char in model.touchKeys) {
                val stats = model.touchStatistics(char) ?: continue
                val varianceX = stats.varianceDX ?: continue
                val varianceY = stats.varianceDY ?: continue
                val covariance = stats.covarianceDXDY ?: continue
                val entry = KeyStats(
                    meanDX = stats.meanDX,
                    meanDY = stats.meanDY,
                    varianceX = varianceX,
                    varianceY = varianceY,
                    covarianceXY = covariance,
                    count = stats.count,
                )
                if (
                    entry.count.isFinite() &&
                    entry.meanDX.isFinite() &&
                    entry.meanDY.isFinite() &&
                    entry.varianceX.isFinite() &&
                    entry.varianceY.isFinite() &&
                    entry.covarianceXY.isFinite()
                ) {
                    keys[char] = entry
                }
            }
            return keys
        }
    }
}

/** Mutable reference holder shared by engine/corrector copies. */
class TouchModelStore {
    var snapshot: PersonalTouchSnapshot? = null
        private set

    fun setSnapshot(snapshot: PersonalTouchSnapshot?) {
        this.snapshot = snapshot
    }
}
