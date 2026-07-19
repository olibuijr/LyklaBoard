package `is`.solberg.lyklabord.engine.learning

import java.time.Instant
import kotlin.math.floor

/** Per-word language attribution for learned counts. */
enum class LanguageHint(val rawValue: String) {
    ICELANDIC("is"), ENGLISH("en"), UNKNOWN("un");
    companion object {
        val icelandic: LanguageHint get() = ICELANDIC
        val english: LanguageHint get() = ENGLISH
        val unknown: LanguageHint get() = UNKNOWN
    }
}

/** A single privacy-bounded learning event. */
sealed interface LearningEvent {
    companion object {
        fun wordCommitted(word: String, previousWord: String? = null, languageHint: LanguageHint = LanguageHint.UNKNOWN) =
            WordCommitted(word, previousWord, languageHint)
        fun suggestionAccepted(typed: String, accepted: String) = SuggestionAccepted(typed, accepted)
        fun correctionReverted(original: String, applied: String) = CorrectionReverted(original, applied)
        fun wordTapped(word: String) = WordTapped(word)
        fun touchSample(keyChar: Char, dx: Double, dy: Double) = TouchSample(keyChar, dx, dy)
    }
    data class WordCommitted(
        val word: String,
        val previousWord: String? = null,
        val languageHint: LanguageHint = LanguageHint.UNKNOWN,
    ) : LearningEvent

    data class SuggestionAccepted(val typed: String, val accepted: String) : LearningEvent
    data class CorrectionReverted(val original: String, val applied: String) : LearningEvent
    data class WordTapped(val word: String) : LearningEvent
    data class TouchSample(val keyChar: Char, val dx: Double, val dy: Double) : LearningEvent
}

data class LoggedEvent(val day: Int, val event: LearningEvent)

object DayBucket {
    fun bucket(forDate: Instant): Int = floor(forDate.epochSecond / 86_400.0).toInt()
    fun bucket(forDate: java.util.Date): Int = floor(forDate.time / 86_400_000.0).toInt()
    fun current(): Int = bucket(Instant.now())
}
