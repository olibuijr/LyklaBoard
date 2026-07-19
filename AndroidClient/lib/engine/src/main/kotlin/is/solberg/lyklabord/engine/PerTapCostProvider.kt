package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfig
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** One captured keystroke touch point in normalized key-pitch coordinates. */
data class TapSample(
    val char: Char,
    val dxNorm: Double,
    val dyNorm: Double,
)

private data class TapPoint(val x: Double, val y: Double) {
    operator fun plus(other: TapPoint): TapPoint = TapPoint(x + other.x, y + other.y)
    operator fun minus(other: TapPoint): TapPoint = TapPoint(x - other.x, y - other.y)
}

/** Coordinate-evidence position-cost provider used by the beam decoder. */
class PerTapCostProvider(
    taps: List<TapSample?>,
    private val spatial: SpatialModel,
    config: EngineConfig,
    personalTouch: PersonalTouchSnapshot? = null,
) : PositionCostProvider {
    private data class Evidence(
        val char: Char,
        val point: TapPoint,
        val center: TapPoint,
        val nllResolved: Double,
        val confidence: Double,
    )

    private data class KeyGaussian(
        val center: TapPoint,
        val qxx: Double,
        val qxy: Double,
        val qyy: Double,
        val logWeight: Double,
    )

    private val evidence: List<Evidence?>
    private val invTwoSigmaX2: Double
    private val invTwoSigmaY2: Double
    private val minSubstitution: Double
    private val maxSubstitution: Double
    private val orthographicConfusion: Double
    private val nearMissMinLean: Double
    private val nearMissCapEnabled: Boolean
    private val edgeUndershootEnabled: Boolean
    private val personalGaussians: Map<Char, KeyGaussian>?

    /** Mean confidence over positions carrying usable tap evidence. */
    val meanTapConfidence: Double?

    init {
        val costs = config.spatialCosts
        minSubstitution = costs.minSubstitution
        maxSubstitution = costs.maxSubstitution
        orthographicConfusion = costs.orthographicConfusion
        nearMissMinLean = config.tapNearMissMinLean
        nearMissCapEnabled = config.tapNearMissCapEnabled
        edgeUndershootEnabled = config.edgeUndershootEnabled
        invTwoSigmaX2 = 1.0 / (2.0 * config.tapSigmaX * config.tapSigmaX)
        invTwoSigmaY2 = 1.0 / (2.0 * config.tapSigmaY * config.tapSigmaY)

        personalGaussians = blendGaussians(personalTouch, spatial, config)

        fun nll(point: TapPoint, key: Char, center: TapPoint): Double {
            val gaussian = personalGaussians?.get(key)
            if (gaussian != null) {
                val delta = point - gaussian.center
                return delta.x * delta.x * gaussian.qxx +
                    delta.x * delta.y * gaussian.qxy +
                    delta.y * delta.y * gaussian.qyy + gaussian.logWeight
            }
            val delta = point - center
            return delta.x * delta.x * invTwoSigmaX2 + delta.y * delta.y * invTwoSigmaY2
        }

        val builtEvidence = ArrayList<Evidence?>(taps.size)
        var confidenceSum = 0.0
        var confidenceCount = 0
        for (tap in taps) {
            val centerRaw = tap?.let { spatial.keyCenter(it.char) }
            if (tap == null || centerRaw == null) {
                builtEvidence += null
                continue
            }
            val center = TapPoint(centerRaw.x, centerRaw.y)
            val point = center + TapPoint(tap.dxNorm, tap.dyNorm)
            val nllResolved = nll(point, tap.char, center)
            var total = 0.0
            for (key in SpatialModel.physicalKeys) {
                val keyCenterRaw = spatial.keyCenter(key) ?: continue
                val keyCenter = TapPoint(keyCenterRaw.x, keyCenterRaw.y)
                total += exp(-nll(point, key, keyCenter))
            }
            val confidence = if (total > 0.0) {
                min(max(exp(-nllResolved) / total, 0.0), 1.0)
            } else {
                1.0
            }
            builtEvidence += Evidence(tap.char, point, center, nllResolved, confidence)
            confidenceSum += confidence
            confidenceCount += 1
        }
        evidence = builtEvidence
        meanTapConfidence = if (confidenceCount > 0) {
            confidenceSum / confidenceCount.toDouble()
        } else {
            null
        }
    }

    private fun nllIntended(point: TapPoint, intended: Char, intendedCenter: TapPoint): Double {
        val gaussian = personalGaussians?.get(intended)
        if (gaussian != null) {
            val delta = point - gaussian.center
            return delta.x * delta.x * gaussian.qxx +
                delta.x * delta.y * gaussian.qxy +
                delta.y * delta.y * gaussian.qyy + gaussian.logWeight
        }
        val delta = point - intendedCenter
        return delta.x * delta.x * invTwoSigmaX2 + delta.y * delta.y * invTwoSigmaY2
    }

    override fun substitutionCost(position: Int, typed: Char, intended: Char): Double {
        if (typed == intended) return 0.0
        if (SpatialModel.confusionPairs.contains("$typed$intended")) {
            return orthographicConfusion
        }
        if (edgeUndershootEnabled &&
            SpatialModel.edgeUndershootPairs.contains("$typed$intended")
        ) {
            return spatial.substitutionCost(typed, intended)
        }
        if (position !in evidence.indices) {
            return spatial.substitutionCost(typed, intended)
        }
        val currentEvidence = evidence[position]
            ?: return spatial.substitutionCost(typed, intended)
        if (currentEvidence.char != typed) {
            return spatial.substitutionCost(typed, intended)
        }
        val intendedCenterRaw = spatial.keyCenter(intended)
            ?: return spatial.substitutionCost(typed, intended)
        val intendedCenter = TapPoint(intendedCenterRaw.x, intendedCenterRaw.y)
        val intendedNll = nllIntended(currentEvidence.point, intended, intendedCenter)
        val ratio = intendedNll - currentEvidence.nllResolved
        val clamped = min(max(ratio, minSubstitution), maxSubstitution)
        if (nearMissCapEnabled && clamped > minSubstitution &&
            tapLean(currentEvidence, intendedCenter) >= nearMissMinLean
        ) {
            return min(clamped, spatial.substitutionCost(typed, intended))
        }
        return clamped
    }

    private fun tapLean(evidence: Evidence, towards: TapPoint): Double {
        val direction = towards - evidence.center
        val length = sqrt(direction.x * direction.x + direction.y * direction.y)
        if (length <= 0.0) return 0.0
        val offset = evidence.point - evidence.center
        return (offset.x * direction.x + offset.y * direction.y) / length
    }

    /** Whether this tap supports reading [typed] as [intended]. */
    fun tapSupports(position: Int, typed: Char, intended: Char): Boolean {
        if (typed == intended) return false
        if (edgeUndershootEnabled &&
            SpatialModel.edgeUndershootPairs.contains("$typed$intended")
        ) {
            return true
        }
        if (!nearMissCapEnabled || position !in evidence.indices) return false
        val currentEvidence = evidence[position] ?: return false
        if (currentEvidence.char != typed) return false
        val intendedCenterRaw = spatial.keyCenter(intended) ?: return false
        return tapLean(currentEvidence, TapPoint(intendedCenterRaw.x, intendedCenterRaw.y)) >=
            nearMissMinLean
    }

    override fun confidence(position: Int): Double =
        if (position !in evidence.indices) 1.0 else evidence[position]?.confidence ?: 1.0

    /** Whether the position carries usable tap evidence rather than static fallback. */
    override fun hasTap(position: Int): Boolean =
        position in evidence.indices && evidence[position] != null

    private companion object {
        const val MAX_ABS_CORRELATION = 0.9

        fun blendGaussians(
            personalTouch: PersonalTouchSnapshot?,
            spatial: SpatialModel,
            config: EngineConfig,
        ): Map<Char, KeyGaussian>? {
            if (personalTouch == null || personalTouch.isEmpty) return null
            val priorVarX = config.tapSigmaX * config.tapSigmaX
            val priorVarY = config.tapSigmaY * config.tapSigmaY
            val floorVar = config.touchSigmaFloor * config.touchSigmaFloor
            val gaussians = HashMap<Char, KeyGaussian>()
            for (key in SpatialModel.physicalKeys) {
                val stats = personalTouch.stats(key) ?: continue
                val meanOffset = personalTouch.blendedMeanOffset(key, config) ?: continue
                val centerRaw = spatial.keyCenter(key) ?: continue
                if (!stats.varianceX.isFinite() || stats.varianceX < 0.0 ||
                    !stats.varianceY.isFinite() || stats.varianceY < 0.0 ||
                    !stats.covarianceXY.isFinite()
                ) continue
                val weight = stats.count / (stats.count + config.touchPriorStrength)
                var varX = weight * stats.varianceX + (1.0 - weight) * priorVarX
                var varY = weight * stats.varianceY + (1.0 - weight) * priorVarY
                var cov = weight * stats.covarianceXY
                if (!varX.isFinite() || !varY.isFinite() || !cov.isFinite() ||
                    varX <= 0.0 || varY <= 0.0
                ) continue
                varX = max(varX, floorVar)
                varY = max(varY, floorVar)
                val maxCov = MAX_ABS_CORRELATION * sqrt(varX * varY)
                cov = min(max(cov, -maxCov), maxCov)
                val determinant = varX * varY - cov * cov
                if (determinant <= 0.0 || !determinant.isFinite()) continue
                val gaussian = KeyGaussian(
                    center = TapPoint(
                        centerRaw.x + meanOffset.first,
                        centerRaw.y + meanOffset.second,
                    ),
                    qxx = varY / (2.0 * determinant),
                    qxy = -cov / determinant,
                    qyy = varX / (2.0 * determinant),
                    logWeight = 0.5 * ln(determinant / (priorVarX * priorVarY)),
                )
                gaussians[key] = gaussian
                for ((accented, base) in SpatialModel.accentBase) {
                    if (base == key) gaussians[accented] = gaussian
                }
            }
            return gaussians.ifEmpty { null }
        }
    }
}

/** Evidence penalty applied by fold pricing to a position's tap confidence. */
fun PositionCostProvider.foldEvidencePenalty(position: Int, cap: Double): Double {
    val confidence = confidence(position)
    if (confidence >= 1.0) return 0.0
    return min(-ln(max(confidence, 1e-9)), cap)
}
