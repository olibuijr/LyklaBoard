package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfig
import `is`.solberg.lyklabord.engine.lexicon.Lexicon
import `is`.solberg.lyklabord.engine.lexicon.LexiconCalibrationProfile
import `is`.solberg.lyklabord.engine.morph.BinaryLemmatizer
import `is`.solberg.lyklabord.engine.morph.MorphologyProviding
import `is`.solberg.lyklabord.engine.morph.ParadigmBundle
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/**
 * Facade over the corrector and predictor with a running bilingual language
 * posterior. Calls are synchronous and must be confined to one owner queue.
 */
class TypeEngine(
    icelandic: Lexicon,
    english: Lexicon,
    morphologyProvider: MorphologyProviding? = null,
    val config: EngineConfig = EngineConfig(),
    icelandicCalibration: LexiconCalibrationProfile? = null,
    englishCalibration: LexiconCalibrationProfile? = null,
) {
    private val model = BlendedLanguageModel(
        icelandic = icelandic,
        english = english,
        morphology = morphologyProvider,
        config = config,
        icelandicCalibrationProfile = icelandicCalibration,
        englishCalibrationProfile = englishCalibration,
        personal = PersonalStore(),
    )
    private val corrector = Corrector(model = model, config = config)
    private val predictor = Predictor(model = model, config = config)

    /** Lane posterior P(Icelandic), initialized to the neutral prior. */
    var probabilityIcelandic: Double = 0.5
        private set

    /** Production morphology overload; BinaryLemmatizer already implements the seam. */
    constructor(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: BinaryLemmatizer?,
        config: EngineConfig = EngineConfig(),
        icelandicCalibration: LexiconCalibrationProfile? = null,
        englishCalibration: LexiconCalibrationProfile? = null,
    ) : this(
        icelandic = icelandic,
        english = english,
        morphologyProvider = morphology,
        config = config,
        icelandicCalibration = icelandicCalibration,
        englishCalibration = englishCalibration,
    )

    data class CalibrationDiagnostics(
        val icelandicMean: Double,
        val icelandicSigma: Double,
        val icelandicWarmupWords: List<String>,
        val englishMean: Double,
        val englishSigma: Double,
        val englishWarmupWords: List<String>,
    )

    val calibrationDiagnostics: CalibrationDiagnostics
        get() = CalibrationDiagnostics(
            icelandicMean = model.icelandicCalibration.meanLogFrequency,
            icelandicSigma = model.icelandicCalibration.stdLogFrequency,
            icelandicWarmupWords = model.icelandicCalibration.sampleWords,
            englishMean = model.englishCalibration.meanLogFrequency,
            englishSigma = model.englishCalibration.stdLogFrequency,
            englishWarmupWords = model.englishCalibration.sampleWords,
        )

    fun setPersonalVocabulary(vocabulary: PersonalVocabulary?) {
        model.personal.setSnapshot(vocabulary)
        rebuildLemmaLift()
    }

    fun setPersonalTouch(snapshot: PersonalTouchSnapshot?) {
        model.touch.setSnapshot(snapshot)
    }

    val personalTouchSnapshot: PersonalTouchSnapshot?
        get() = model.touch.snapshot

    fun learnSessionWord(word: String) {
        model.personal.learnSession(word)
        rebuildLemmaLift()
    }

    fun clearSessionVocabulary() {
        model.personal.clearSession()
        rebuildLemmaLift()
    }

    fun forgetSessionWord(word: String) {
        model.personal.forgetSession(word)
        rebuildLemmaLift()
    }

    fun setInflection(inflection: InflectionModel?) {
        model.inflection.setModel(inflection)
        model.compounds.clearCache()
        rebuildLemmaLift()
    }

    private fun rebuildLemmaLift() {
        model.inflection.rebuildLift(
            words = model.personal.allValidKeys,
            morphology = model.morphology,
            liftNats = config.lemmaLiftBoost,
        )
    }

    data class GovernorDiagnostics(
        val mass: Double,
        val entropyRatio: Double,
        val cases: List<CaseProbability>,
    )

    data class CaseProbability(val name: String, val p: Double)

    fun governorDiagnostics(word: String): GovernorDiagnostics? {
        val governor = model.inflection.model?.governors?.governor(word.lowercase()) ?: return null
        val cases = ParadigmBundle.caseNames.mapIndexed { index, name ->
            CaseProbability(name, governor.caseProbabilities[index])
        }.filter { it.p > 0.0 }.sortedByDescending { it.p }
        return GovernorDiagnostics(governor.mass, governor.caseEntropyRatio, cases)
    }

    val personalSnapshotWords: List<String>
        get() = model.personal.snapshotWords

    val sessionLearnedWords: List<String>
        get() = model.personal.sessionWords

    fun isPersonalWord(word: String): Boolean = model.personal.isValidWord(word)

    fun isPersonalLearnedWord(word: String): Boolean =
        model.personal.isValidWord(word) &&
            !model.personal.isTombstoned(word) &&
            !model.isKnownAnywhere(word) &&
            model.compoundSplit(word) == null

    internal fun autocapArtifactLowercased(word: String): String? {
        if (word.length < 2) return null
        val first = word.firstOrNull() ?: return null
        if (!first.isUpperCase()) return null
        val lowered = word.lowercase()
        if (word != lowered.replaceRange(0, 1, lowered.first().uppercase())) return null
        if (!model.isCapArtifactBase(lowered)) return null
        return lowered
    }
    /** Direct correction entry point for embedders that do not need surface restoration. */
    fun correct(
        typed: String,
        previousWord: String? = null,
        limit: Int = 3,
        deliberateCharacters: List<Char> = emptyList(),
        taps: List<TapSample?> = emptyList(),
        capitalizedMidSentence: Boolean = false,
        trace: CorrectionTrace? = null,
    ): CorrectionResult = corrector.correct(
        typed = typed,
        previousWord = previousWord,
        pIcelandic = probabilityIcelandic,
        limit = limit,
        deliberateCharacters = deliberateCharacters,
        taps = taps,
        capitalizedMidSentence = capitalizedMidSentence,
        trace = trace,
    )

    /** Suggestion-bar entry point using the full facade behavior. */
    fun suggest(
        `context`: String,
        currentWord: String,
        limit: Int = 3,
        deliberateCharacters: List<Char> = emptyList(),
        taps: List<TapSample?> = emptyList(),
        trace: CorrectionTrace? = null,
    ): List<Suggestion> = suggestions(
        context = `context`,
        currentWord = currentWord,
        limit = limit,
        deliberateCharacters = deliberateCharacters,
        taps = taps,
        trace = trace,
    )

    /** Next-word prediction entry point. */
    fun predict(previousWord: String? = null, limit: Int = 3): List<Suggestion> =
        restorePersonalSurfaces(predictor.nextWords(previousWord, probabilityIcelandic, limit))

    /** Create a stateful editor session owned by this engine. */
    fun makeSession(): TypingSession = TypingSession(this)


    fun suggestions(
        `context`: String,
        currentWord: String,
        limit: Int = 3,
        deliberateCharacters: List<Char> = emptyList(),
        taps: List<TapSample?> = emptyList(),
        trace: CorrectionTrace? = null,
    ): List<Suggestion> {
        val previous = lastWord(`context`)
        val trimmed = currentWord.trim { it.isWhitespace() }
        if (trimmed.isEmpty()) {
            trace?.rule = "prediction (no word in progress)"
            return restorePersonalSurfaces(
                predictor.nextWords(
                    previousWord = previous,
                    pIcelandic = probabilityIcelandic,
                    limit = limit,
                ),
            )
        }
        val result = corrector.correct(
            typed = trimmed,
            previousWord = previous,
            pIcelandic = probabilityIcelandic,
            limit = limit,
            deliberateCharacters = deliberateCharacters,
            taps = if (taps.size == trimmed.length) taps else emptyList(),
            capitalizedMidSentence = trimmed.firstOrNull()?.isUpperCase() == true && isMidSentence(`context`),
            trace = trace,
        )
        var suggestions = restorePersonalSurfaces(result.suggestions)
        if (trimmed.firstOrNull()?.isUpperCase() == true) {
            suggestions = suggestions.map { suggestion ->
                val text = suggestion.text
                Suggestion(
                    text = if (text.isNotEmpty()) text.first().uppercase() + text.drop(1) else text,
                    isAutocorrect = suggestion.isAutocorrect,
                    confidence = suggestion.confidence,
                    isVerbatim = suggestion.isVerbatim,
                    isRestoration = suggestion.isRestoration,
                    isPersonalLearned = suggestion.isPersonalLearned,
                )
            }
        }
        return suggestions.map { suggestion ->
            if (suggestion.isAutocorrect && suggestion.text == trimmed) {
                suggestion.copy(isAutocorrect = false)
            } else suggestion
        }
    }

    fun dottedSpaceMiss(left: String, right: String, `context`: String): Suggestion? {
        val previous = lastWord(`context`)
        val suggestion = corrector.dotSplitSuggestion(
            left = left.lowercase(),
            right = right.lowercase(),
            previousWord = previous,
            pIcelandic = probabilityIcelandic,
        ) ?: return null
        if (left.firstOrNull()?.isUpperCase() == true) {
            val text = suggestion.text
            return suggestion.copy(
                text = if (text.isNotEmpty()) text.first().uppercase() + text.drop(1) else text,
            )
        }
        return suggestion
    }

    private fun restorePersonalSurfaces(suggestions: List<Suggestion>): List<Suggestion> = suggestions.map { suggestion ->
        val surface = model.personal.displaySurface(suggestion.text) ?: return@map suggestion
        val isAllCaps = surface.length > 1 && surface == surface.uppercase() && surface != surface.lowercase()
        if (isAllCaps) {
            val lowered = surface.lowercase()
            val baseAttested =
                model.icelandic.frequency(lowered) != null || model.english.frequency(lowered) != null
            if (baseAttested) return@map suggestion
        }
        val isLeadingCapOnly = !isAllCaps && surface == leadingCapital(suggestion.text)
        if (isLeadingCapOnly && model.isCapArtifactBase(suggestion.text)) return@map suggestion
        suggestion.copy(text = surface)
    }

    fun confirmWord(word: String) {
        val w = word.lowercase().trim { it.isWhitespace() }
        if (w.isEmpty()) return
        val switch = config.laneSwitchProbability
        val predicted = (1 - switch) * probabilityIcelandic + switch * (1 - probabilityIcelandic)
        val evidence = model.laneEvidence(w)
        val odds = (predicted / (1 - predicted)) * exp(evidence)
        val updated = odds / (1 + odds)
        probabilityIcelandic = min(max(updated, config.posteriorFloor), config.posteriorCeiling)
    }

    fun noteSentenceBoundary() {
        val decay = config.laneBoundaryDecay
        probabilityIcelandic = 0.5 + (probabilityIcelandic - 0.5) * (1 - decay)
    }

    data class LaneDiagnostics(
        val frequencyIS: UInt?,
        val frequencyEN: UInt?,
        val zIS: Double,
        val zEN: Double,
        val binKnown: Boolean,
        val binCases: List<String>,
        val binLemmas: List<String>,
        val evidence: Double,
    )

    fun laneDiagnostics(word: String): LaneDiagnostics {
        val w = word.lowercase()
        return LaneDiagnostics(
            frequencyIS = model.icelandic.frequency(w),
            frequencyEN = model.english.frequency(w),
            zIS = model.calibratedUnigramScore(w, Language.icelandic),
            zEN = model.calibratedUnigramScore(w, Language.english),
            binKnown = model.morphology?.isKnown(w) == true,
            binCases = model.morphology?.nounAdjectiveCases(w) ?: emptyList(),
            binLemmas = model.morphology?.lemmaCandidates(w) ?: emptyList(),
            evidence = model.laneEvidence(w),
        )
    }

    data class BigramDiagnostics(
        val bigramIS: UInt?,
        val bigramEN: UInt?,
        val previousIS: UInt?,
        val previousEN: UInt?,
        val zIS: Double,
        val zEN: Double,
    )

    fun bigramDiagnostics(previous: String, word: String): BigramDiagnostics {
        val p = previous.lowercase()
        val w = word.lowercase()
        return BigramDiagnostics(
            bigramIS = model.icelandic.bigramFrequency(p, w),
            bigramEN = model.english.bigramFrequency(p, w),
            previousIS = model.icelandic.frequency(p),
            previousEN = model.english.frequency(p),
            zIS = model.calibratedScore(w, p, Language.icelandic),
            zEN = model.calibratedScore(w, p, Language.english),
        )
    }

    data class CompoundDiagnostics(
        val typedValid: Boolean,
        val `protected`: Boolean,
        val parts: List<String>?,
        val deniedSplit: String?,
    )

    fun compoundDiagnostics(word: String): CompoundDiagnostics {
        val w = word.lowercase()
        return CompoundDiagnostics(
            typedValid = model.isValidTypedWord(w),
            `protected` = model.isProtectedTypedWord(w),
            parts = model.compoundSplit(w)?.let { it.modifiers + listOf(it.head) },
            deniedSplit = CompoundAnalyzer.neverCompounds[w],
        )
    }

    fun warmUp() {
        model.warmUp()
    }

    fun resetLanguagePosterior() {
        probabilityIcelandic = 0.5
    }

    companion object {
        fun isMidSentence(`context`: String): Boolean {
            val last = `context`.trim { it.isWhitespace() }.lastOrNull() ?: return false
            return last !in ".!?..."
        }

        fun lastWord(`context`: String): String? {
            val token = `context`.split(Regex("\\s+")).filter { it.isNotEmpty() }.lastOrNull() ?: return null
            val stripped = token.trim { it.isWhitespace() || it.category.isPunctuationOrSymbol() }
            return stripped.takeIf { it.isNotEmpty() }?.lowercase()
        }

        private fun leadingCapital(text: String): String =
            if (text.isEmpty()) text else text.first().uppercase() + text.drop(1)

        private fun CharCategory.isPunctuationOrSymbol(): Boolean =
            this == CharCategory.CONNECTOR_PUNCTUATION ||
                this == CharCategory.DASH_PUNCTUATION ||
                this == CharCategory.START_PUNCTUATION ||
                this == CharCategory.END_PUNCTUATION ||
                this == CharCategory.INITIAL_QUOTE_PUNCTUATION ||
                this == CharCategory.FINAL_QUOTE_PUNCTUATION ||
                this == CharCategory.OTHER_PUNCTUATION ||
                this == CharCategory.MATH_SYMBOL ||
                this == CharCategory.CURRENCY_SYMBOL ||
                this == CharCategory.MODIFIER_SYMBOL ||
                this == CharCategory.OTHER_SYMBOL
    }
}
