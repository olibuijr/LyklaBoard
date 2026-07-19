package `is`.solberg.lyklabord.engine.learning

import kotlinx.serialization.Serializable

/** Online bivariate Welford aggregates with exponential forgetting. */
@Serializable
data class TouchKeyStats(
    var count: Double = 0.0,
    var meanDX: Double = 0.0,
    var meanDY: Double = 0.0,
    var m2DX: Double = 0.0,
    var m2DY: Double = 0.0,
    var cDXDY: Double = 0.0,
) {
    fun update(dx: Double, dy: Double) {
        count += 1.0
        val deltaXOld = dx - meanDX
        meanDX += deltaXOld / count
        val deltaXNew = dx - meanDX
        m2DX += deltaXOld * deltaXNew
        val deltaYOld = dy - meanDY
        meanDY += deltaYOld / count
        val deltaYNew = dy - meanDY
        m2DY += deltaYOld * deltaYNew
        cDXDY += deltaXOld * deltaYNew
    }

    fun decay(by: Double) {
        require(by > 0.0 && by < 1.0) { "decay factor must be in (0, 1)" }
        count *= by
        m2DX *= by
        m2DY *= by
        cDXDY *= by
    }

    val varianceDX: Double?
        get() = if (count > 1.0) m2DX / (count - 1.0) else null
    val varianceDY: Double?
        get() = if (count > 1.0) m2DY / (count - 1.0) else null
    val covarianceDXDY: Double?
        get() = if (count > 1.0) cDXDY / (count - 1.0) else null
}
