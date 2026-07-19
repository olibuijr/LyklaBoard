package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfig
import `is`.solberg.lyklabord.engine.lexicon.Lexicon
import `is`.solberg.lyklabord.engine.lexicon.LexiconCalibrationProfile
import `is`.solberg.lyklabord.engine.morph.MorphologyProviding
import kotlin.math.exp

/** Next-word and mid-word prediction from both calibrated lexicons. */
class Predictor internal constructor(
    private val model: BlendedLanguageModel,
    private val config: EngineConfig,
) {
    constructor(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: MorphologyProviding? = null,
        config: EngineConfig = EngineConfig(),
        icelandicCalibrationProfile: LexiconCalibrationProfile? = null,
        englishCalibrationProfile: LexiconCalibrationProfile? = null,
    ) : this(
        BlendedLanguageModel(
            icelandic = icelandic,
            english = english,
            morphology = morphology,
            config = config,
            icelandicCalibrationProfile = icelandicCalibrationProfile,
            englishCalibrationProfile = englishCalibrationProfile,
        ),
        config,
    )


    fun isKnown(word: String): Boolean = model.isKnownAnywhere(word)

    fun nextWords(previousWord: String?, pIcelandic: Double = 0.5, limit: Int = 3): List<Suggestion> {
        if (limit <= 0) return emptyList()
        val pool = HashSet<String>()
        if (previousWord != null) {
            for (lexicon in listOf(model.icelandic, model.english)) {
                for (entry in lexicon.continuations(previousWord, config.continuationPoolLimit)) pool += entry.word
            }
            for (entry in model.personal.continuations(previousWord, config.personalContinuationPoolLimit)) pool += entry.word
        }
        if (pool.isEmpty()) {
            for (lexicon in listOf(model.icelandic, model.english)) {
                for (entry in lexicon.completions("", config.unigramPoolLimit)) pool += entry.word
            }
            for (entry in model.personal.completions("", config.personalContinuationPoolLimit)) pool += entry.word
        }
        return rank(pool, previousWord, pIcelandic, limit)
    }

    fun completions(
        of: String,
        previousWord: String?,
        pIcelandic: Double = 0.5,
        limit: Int = 3,
    ): List<Suggestion> {
        if (limit <= 0 || of.isEmpty()) return nextWords(previousWord, pIcelandic, limit)
        val lowered = of.lowercase()
        val pool = HashSet<String>()
        for (lexicon in listOf(model.icelandic, model.english)) {
            for (entry in lexicon.completions(lowered, config.unigramPoolLimit)) pool += entry.word
        }
        for (entry in model.personal.completions(lowered, config.personalCompletionPoolLimit)) pool += entry.word
        return rank(pool, previousWord, pIcelandic, limit)
    }

    private fun rank(
        pool: Set<String>,
        previousWord: String?,
        pIcelandic: Double,
        limit: Int,
    ): List<Suggestion> {
        val filtered = pool.filter { !model.isPersonalTombstoned(it) }
        val governorFit = model.inflection.governorFit(previousWord, pIcelandic, model.morphology, config)
        val scored = filtered.map { word ->
            var score = model.blendedScore(word, previousWord, pIcelandic)
            if (governorFit != null && model.icelandic.bigramFrequency(governorFit.previousWord, word) == null) {
                score += governorFit.fitNats(word)
            }
            word to score
        }.sortedWith(compareByDescending<Pair<String, Double>> { it.second }.thenBy { it.first })

        val confidencePool = scored.take(8)
        val maxScore = confidencePool.firstOrNull()?.second ?: 0.0
        val z = confidencePool.sumOf { exp(it.second - maxScore) }
        return scored.take(limit).map { (word, score) ->
            Suggestion(
                text = word,
                isAutocorrect = false,
                confidence = if (z > 0.0) exp(score - maxScore) / z else 0.0,
            )
        }
    }
}
