package `is`.solberg.lyklabord.engine

import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/**
 * Keyboard-adjacency likelihood model for the Icelandic layout.
 *
 * Key centers live on a unit grid (1.0 = one key width) with iOS-style row
 * stagger. Substitution likelihood is Gaussian in the distance between key
 * centers; edit operations use the tuned constants in [Costs]. All costs are
 * in nats.
 */
class SpatialModel(
    val costs: Costs = Costs(),
) {
    class Costs(
        /** User typed an extra character that was not intended. */
        var insertion: Double = 4.0,
        /** User omitted a character they intended. */
        var deletion: Double = 4.0,
        /** Two adjacent characters swapped. */
        var transposition: Double = 2.0,
        /** Floor for a substitution between distinct characters. */
        var minSubstitution: Double = 0.35,
        /** Cap for substitutions between far-apart keys. */
        var maxSubstitution: Double = 8.0,
        /** Substitution involving a character with no key position. */
        var unknownCharSubstitution: Double = 5.0,
        /** Flat cost for common Icelandic orthographic confusions. */
        var orthographicConfusion: Double = 1.5,
        /** Gaussian width in key widths. */
        var sigma: Double = 0.7,
    )

    /** Small JVM replacement for Swift's SIMD2<Double> key-center value. */
    internal data class KeyCenter(val x: Double, val y: Double)

    /** Letters on the bottom row whose centers sit above the spacebar span. */
    val spaceAdjacentLetters: Set<Char>

    private val positions: Map<Char, KeyCenter>

    init {
        val pos = mutableMapOf<Char, KeyCenter>()
        icelandicRows.forEachIndexed { rowIndex, row ->
            row.forEachIndexed { colIndex, char ->
                pos[char] = KeyCenter(rowOffsets[rowIndex] + colIndex.toDouble(), rowIndex.toDouble())
            }
        }
        for ((accented, base) in accentBase) {
            pos[accented] = pos[base]!!
        }
        positions = pos
        val bottomRowIndex = (icelandicRows.size - 1).toDouble()
        spaceAdjacentLetters = pos
            .filter { (_, center) -> center.y == bottomRowIndex && center.x in spacebarXSpan }
            .keys
            .toSet()
    }

    /** Key center of [char], or null when the character has no key position. */
    internal fun keyCenter(of: Char): KeyCenter? = positions[of]

    /** -log P(typed | intended) for one character substitution. */
    fun substitutionCost(typed: Char, intended: Char): Double {
        if (typed == intended) return 0.0
        if (confusionPairs.contains("$typed$intended")) {
            return costs.orthographicConfusion
        }
        val p = positions[typed] ?: return costs.unknownCharSubstitution
        val q = positions[intended] ?: return costs.unknownCharSubstitution
        val deltaX = p.x - q.x
        val deltaY = p.y - q.y
        val d2 = deltaX * deltaX + deltaY * deltaY
        val gaussian = d2 / (2.0 * costs.sigma * costs.sigma)
        return min(max(gaussian, costs.minSubstitution), costs.maxSubstitution)
    }

    /** P(typed | intended) as a likelihood in [0, 1]. */
    fun likelihood(typed: Char, intended: Char): Double =
        exp(-substitutionCost(typed, intended))

    /**
     * Restricted Damerau-Levenshtein typing cost. Substitutions use key-distance
     * costs; insertion, deletion and transposition use [Costs].
     */
    fun typingCost(typed: List<Char>, intended: List<Char>): Double {
        val n = typed.size
        val m = intended.size
        if (n == 0) return m.toDouble() * costs.deletion
        if (m == 0) return n.toDouble() * costs.insertion

        val width = m + 1
        val dp = DoubleArray((n + 1) * width)
        for (i in 1..n) dp[i * width] = i.toDouble() * costs.insertion
        for (j in 1..m) dp[j] = j.toDouble() * costs.deletion

        for (i in 1..n) {
            for (j in 1..m) {
                val sub = dp[(i - 1) * width + (j - 1)] +
                    substitutionCost(typed[i - 1], intended[j - 1])
                val ins = dp[(i - 1) * width + j] + costs.insertion
                val del = dp[i * width + (j - 1)] + costs.deletion
                var best = min(sub, min(ins, del))
                if (
                    i >= 2 && j >= 2 &&
                    typed[i - 1] == intended[j - 2] &&
                    typed[i - 2] == intended[j - 1] &&
                    typed[i - 1] != typed[i - 2]
                ) {
                    best = min(best, dp[(i - 2) * width + (j - 2)] + costs.transposition)
                }
                dp[i * width + j] = best
            }
        }
        return dp[n * width + m]
    }

    /** Convenience overload for lowercased strings. */
    fun typingCost(typed: String, intended: String): Double =
        typingCost(typed.toList(), intended.toList())

    companion object {
        /** Icelandic iOS layout rows. */
        val icelandicRows: List<String> = listOf(
            "qwertyuiopð",
            "asdfghjklæö",
            "zxcvbnmþ",
        )

        /** iOS-style row stagger: home row +0.5, bottom row +0.75. */
        private val rowOffsets: List<Double> = listOf(0.0, 0.5, 0.75)

        /** Horizontal span of the iPhone spacebar in key-width units. */
        private val spacebarXSpan: ClosedRange<Double> = 2.5..7.5

        /** Accented characters share their base key's physical center. */
        val accentBase: Map<Char, Char> = mapOf(
            'á' to 'a', 'é' to 'e', 'í' to 'i', 'ó' to 'o', 'ú' to 'u', 'ý' to 'y',
        )

        /** Inverse of [accentBase]: base vowel to acute twin. */
        val acuteOfBase: Map<Char, Char> = accentBase.entries.associate { (accented, base) ->
            base to accented
        }

        /** Common Icelandic orthographic confusions, directionally including v→ð. */
        internal val confusionPairs: Set<String> = buildSet {
            for ((a, b) in listOf('d' to 'ð', 'o' to 'ö', 'ð' to 'þ', 't' to 'þ')) {
                add("$a$b")
                add("$b$a")
            }
            add("vð")
        }

        /** Directional edge-key undershoot pairs. */
        internal val edgeUndershootPairs: Set<String> = setOf("pð", "læ", "æö", "mþ")

        /** Dedicated physical keys; accent twins are intentionally omitted. */
        internal val physicalKeys: List<Char> = icelandicRows.flatMap { it.toList() }
    }
}
