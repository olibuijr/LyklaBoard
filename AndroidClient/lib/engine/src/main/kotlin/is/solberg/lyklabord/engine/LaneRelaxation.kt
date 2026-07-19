package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfig

/**
 * Lane-relaxation pricing (PLAN.md "Lane relaxation profiles").
 *
 * One value is computed per correction call from the current lane posterior
 * and priced into both candidate-cost paths: the beam decoder's search
 * currency and the exact spatial-DP re-score.
 */
class FoldPricing(
    config: EngineConfig,
    pIcelandic: Double,
    vetoRelaxation: Boolean = false,
) {
    /** Lane weight of the Icelandic profile, in [0, 1]. */
    val weightIS: Double
    /** Lane weight of the English profile, in [0, 1]. */
    val weightEN: Double
    /** Fold price of one acute-vowel fold under the IS profile. */
    val acuteFoldCost: Double
    /** Scale factor on the orthographic-confusion constant (IS profile). */
    val confusionScale: Double
    /** Scale factor on gemination-shaped indels (IS profile). */
    val geminationScale: Double
    /**
     * Deliberateness veto (a long-pressed character anywhere in the word):
     * all relaxation is off.
     */
    val vetoRelaxation: Boolean = vetoRelaxation

    private val foldEpsilon: Double
    private val apostropheBaseCost: Double

    init {
        val lo = config.laneWeightRampLo
        val hi = config.laneWeightRampHi
        val wIS = if (config.foldProfileISEnabled && !vetoRelaxation) {
            smoothstep(pIcelandic, lo = lo, hi = hi)
        } else {
            0.0
        }
        val wEN = if (config.foldProfileENEnabled && !vetoRelaxation) {
            smoothstep(1.0 - pIcelandic, lo = lo, hi = hi)
        } else {
            0.0
        }
        weightIS = wIS
        weightEN = wEN
        foldEpsilon = config.foldEpsilon
        acuteFoldCost = maxOf(config.foldEpsilon, config.foldBaseCost * (1.0 - wIS))
        confusionScale = 1.0 - wIS * config.confusionLaneDiscount
        geminationScale = 1.0 - wIS * config.geminationLaneDiscount
        apostropheBaseCost = config.spatialCosts.deletion
    }

    /** Neutral pricing (laneWeight 0 in both profiles). */
    companion object {
        fun neutral(config: EngineConfig): FoldPricing = FoldPricing(config, pIcelandic = 0.5)

        /** Hermite smoothstep of x between lo and hi (0 below, 1 above). */
        fun smoothstep(x: Double, lo: Double, hi: Double): Double {
            if (hi <= lo) return if (x >= hi) 1.0 else 0.0
            val t = ((x - lo) / (hi - lo)).coerceIn(0.0, 1.0)
            return t * t * (3.0 - 2.0 * t)
        }

        /** Acute-vowel fold: typed the base letter, intended its acute twin. */
        fun isAcuteFold(typed: Char, intended: Char): Boolean =
            SpatialModel.accentBase[intended] == typed

        /** Lane-discounted directional Icelandic orthographic confusion. */
        fun isLaneConfusion(typed: Char, intended: Char): Boolean = when {
            typed == 'd' && intended == 'ð' -> true
            typed == 't' && intended == 'þ' -> true
            typed == 'o' && intended == 'ö' -> true
            typed == 'ð' && intended == 'þ' -> true
            typed == 'þ' && intended == 'ð' -> true
            typed == 'v' && intended == 'ð' -> true
            else -> false
        }

        /** Word-internal apostrophes (straight and typographic). */
        fun isApostrophe(character: Char): Boolean = character == '\'' || character == '\u2019'
    }

    /**
     * Lane price of a typed-to-intended substitution, or null when the pair
     * is not a lane-relaxation pair.
     */
    fun substitutionPrice(typed: Char, intended: Char, confusionBase: Double): Double? {
        if (isAcuteFold(typed = typed, intended = intended)) return acuteFoldCost
        if (isLaneConfusion(typed = typed, intended = intended)) {
            return maxOf(foldEpsilon, confusionBase * confusionScale)
        }
        return null
    }

    /** Price of a character omitted from the typed input. */
    fun omissionPrice(character: Char, base: Double): Double {
        if (!isApostrophe(character)) return base
        return maxOf(foldEpsilon, minOf(base, apostropheBaseCost * (1.0 - weightEN)))
    }

    /** Price of a gemination-shaped indel. */
    fun geminationIndelPrice(base: Double): Double =
        maxOf(foldEpsilon, base * geminationScale)
}

/**
 * Decomposed channel cost of one candidate: lane-priced total plus the
 * restoration/error operation split.
 */
data class ChannelCost(
    var total: Double,
    var errorOps: Int,
    var restorationOps: Int,
) {
    /** The candidate differs from the typed token by restoration alone. */
    val isRestorationOnly: Boolean
        get() = errorOps == 0 && restorationOps > 0
}

private data class ChannelCostCell(
    val cost: Double,
    val errorOps: Int,
    val restorationOps: Int,
)

/** Static-provider convenience overload (no per-tap evidence). */
fun SpatialModel.channelCost(
    typed: List<Char>,
    intended: List<Char>,
    pricing: FoldPricing,
): ChannelCost = channelCost(
    typed = typed,
    intended = intended,
    pricing = pricing,
    positionCosts = StaticSpatialCostProvider(spatial = this),
    foldEvidenceCap = 0.0,
)

/**
 * Lane-priced spatial DP with restoration/error operation decomposition.
 * Among equal-cost alignments, the one with fewer error operations wins.
 */
fun <Provider : PositionCostProvider> SpatialModel.channelCost(
    typed: List<Char>,
    intended: List<Char>,
    pricing: FoldPricing,
    positionCosts: Provider,
    foldEvidenceCap: Double,
): ChannelCost {
    val n = typed.size
    val m = intended.size
    if (n == 0) {
        var cost = 0.0
        var restoration = 0
        var errors = 0
        for (character in intended) {
            val price = pricing.omissionPrice(character, base = costs.deletion)
            cost += price
            if (FoldPricing.isApostrophe(character)) restoration++ else errors++
        }
        return ChannelCost(total = cost, errorOps = errors, restorationOps = restoration)
    }
    if (m == 0) {
        return ChannelCost(
            total = n.toDouble() * costs.insertion,
            errorOps = n,
            restorationOps = 0,
        )
    }

    fun better(a: ChannelCostCell, b: ChannelCostCell): ChannelCostCell {
        if (a.cost < b.cost) return a
        if (b.cost < a.cost) return b
        return if (a.errorOps <= b.errorOps) a else b
    }

    val width = m + 1
    val dp = Array((n + 1) * width) {
        ChannelCostCell(cost = 0.0, errorOps = 0, restorationOps = 0)
    }
    for (i in 1..n) {
        dp[i * width] = ChannelCostCell(
            cost = i.toDouble() * costs.insertion,
            errorOps = i,
            restorationOps = 0,
        )
    }
    for (j in 1..m) {
        val character = intended[j - 1]
        val previous = dp[j - 1]
        val price = pricing.omissionPrice(character, base = costs.deletion)
        val apostrophe = FoldPricing.isApostrophe(character)
        dp[j] = ChannelCostCell(
            cost = previous.cost + price,
            errorOps = previous.errorOps + if (apostrophe) 0 else 1,
            restorationOps = previous.restorationOps + if (apostrophe) 1 else 0,
        )
    }

    for (i in 1..n) {
        val typedChar = typed[i - 1]
        for (j in 1..m) {
            val intendedChar = intended[j - 1]
            val diagonal = dp[(i - 1) * width + (j - 1)]
            var best: ChannelCostCell
            if (typedChar == intendedChar) {
                best = diagonal
            } else {
                val base = positionCosts.substitutionCost(
                    position = i - 1,
                    typed = typedChar,
                    intended = intendedChar,
                )
                val lane = pricing.substitutionPrice(
                    typed = typedChar,
                    intended = intendedChar,
                    confusionBase = base,
                )
                if (lane != null) {
                    val evidence = positionCosts.foldEvidencePenalty(
                        position = i - 1,
                        cap = foldEvidenceCap,
                    )
                    best = ChannelCostCell(
                        cost = diagonal.cost + minOf(lane + evidence, base),
                        errorOps = diagonal.errorOps,
                        restorationOps = diagonal.restorationOps + 1,
                    )
                } else {
                    best = ChannelCostCell(
                        cost = diagonal.cost + base,
                        errorOps = diagonal.errorOps + 1,
                        restorationOps = diagonal.restorationOps,
                    )
                }
            }

            // Extra typed character (deletion), discounted for gemination.
            val up = dp[(i - 1) * width + j]
            val deletionBase = if (i >= 2 && typed[i - 1] == typed[i - 2]) {
                pricing.geminationIndelPrice(base = costs.insertion)
            } else {
                costs.insertion
            }
            best = better(
                best,
                ChannelCostCell(
                    cost = up.cost + deletionBase,
                    errorOps = up.errorOps + 1,
                    restorationOps = up.restorationOps,
                ),
            )

            // Omitted intended character (insertion); apostrophes and
            // gemination-shaped doublings use their lane prices.
            val left = dp[i * width + (j - 1)]
            val insertionBase: Double
            val insertionRestoration: Boolean
            if (FoldPricing.isApostrophe(intendedChar)) {
                insertionBase = pricing.omissionPrice(intendedChar, base = costs.deletion)
                insertionRestoration = true
            } else if (j >= 2 && intended[j - 1] == intended[j - 2]) {
                insertionBase = pricing.geminationIndelPrice(base = costs.deletion)
                insertionRestoration = false
            } else {
                insertionBase = costs.deletion
                insertionRestoration = false
            }
            best = better(
                best,
                ChannelCostCell(
                    cost = left.cost + insertionBase,
                    errorOps = left.errorOps + if (insertionRestoration) 0 else 1,
                    restorationOps = left.restorationOps + if (insertionRestoration) 1 else 0,
                ),
            )

            // Transposition.
            if (
                i >= 2 && j >= 2 &&
                typed[i - 1] == intended[j - 2] &&
                typed[i - 2] == intended[j - 1] &&
                typed[i - 1] != typed[i - 2]
            ) {
                val corner = dp[(i - 2) * width + (j - 2)]
                best = better(
                    best,
                    ChannelCostCell(
                        cost = corner.cost + costs.transposition,
                        errorOps = corner.errorOps + 1,
                        restorationOps = corner.restorationOps,
                    ),
                )
            }
            dp[i * width + j] = best
        }
    }
    val final = dp[n * width + m]
    return ChannelCost(
        total = final.cost,
        errorOps = final.errorOps,
        restorationOps = final.restorationOps,
    )
}
