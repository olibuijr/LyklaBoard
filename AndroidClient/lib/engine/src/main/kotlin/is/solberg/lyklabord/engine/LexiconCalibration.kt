package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.lexicon.Lexicon
import `is`.solberg.lyklabord.engine.lexicon.LexiconCalibrationProfile
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * Per-lexicon frequency-distribution statistics used to calibrate
 * cross-language comparisons. 1:1 port of the Swift `LexiconCalibration`
 * (`Packages/TypeEngine/Sources/TypeEngine/LanguageModel.swift`).
 *
 * Each lexicon's log-frequencies are z-scored against that lexicon's own
 * distribution before blending across languages. The distribution is estimated
 * by sampling the head of many two-letter prefix buckets via
 * `completions(of:limit:)`.
 */
class LexiconCalibration private constructor(
    /** Mean of log(f + addK) over the sample. */
    val meanLogFrequency: Double,
    /** Standard deviation of log(f + addK) over the sample (>= minSigma). */
    val stdLogFrequency: Double,
    /** A spread of sampled words, retained for page warm-up. */
    val sampleWords: List<String>,
) {
    constructor(profile: LexiconCalibrationProfile) : this(
        meanLogFrequency = profile.meanLogFrequency,
        stdLogFrequency = profile.stdLogFrequency,
        sampleWords = profile.warmupWords,
    )

    companion object {
        /** σ floor: degenerate distributions fall back to unit variance. */
        private const val MIN_SIGMA = 0.25

        /** First letters of the sampled two-letter buckets. */
        private val BUCKET_FIRST: List<Char> = "aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö".toList()

        /** Second letters — a spread of common vowels/consonants + Icelandic letters. */
        private val BUCKET_SECOND: List<Char> = "aáeéiíoóuúyýhnrstlðgkm".toList()

        private const val BUCKET_LIMIT = 12

        fun of(meanLogFrequency: Double, stdLogFrequency: Double, sampleWords: List<String>): LexiconCalibration =
            LexiconCalibration(meanLogFrequency, stdLogFrequency, sampleWords)

        fun measure(lexicon: Lexicon, addK: Double): LexiconCalibration {
            val logs = ArrayList<Double>(4096)
            val words = ArrayList<String>()
            for (first in BUCKET_FIRST) {
                for (second in BUCKET_SECOND) {
                    val prefix = "$first$second"
                    for (entry in lexicon.completions(prefix, BUCKET_LIMIT)) {
                        logs.add(ln(entry.frequency.toDouble() + addK))
                        if (words.size < 512) words.add(entry.word)
                    }
                }
            }
            if (logs.size < 4) {
                // Effectively empty lexicon: identity calibration keeps z = log(f + k).
                return LexiconCalibration(0.0, 1.0, words)
            }
            val mean = logs.sum() / logs.size
            val variance = logs.sumOf { (it - mean) * (it - mean) } / logs.size
            val sigma = maxOf(sqrt(variance), MIN_SIGMA)
            return LexiconCalibration(mean, sigma, words)
        }
    }
}
