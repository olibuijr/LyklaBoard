package `is`.solberg.lyklabord.engine

/**
 * One ranked suggestion. 1:1 port of the Swift `Suggestion` struct
 * (`Packages/TypeEngine/Sources/TypeEngine/Corrector.swift`).
 */
data class Suggestion(
    val text: String,
    val isAutocorrect: Boolean,
    val confidence: Double,
    val isVerbatim: Boolean = false,
    val isRestoration: Boolean = false,
    val isPersonalLearned: Boolean = false,
) {
    /** A copy flagged as own-learned personal vocabulary. All other fields preserved. */
    fun markingPersonalLearned(): Suggestion = copy(isPersonalLearned = true)
}

/** The two language lanes of the bilingual model. Port of Swift `enum Language`. */
enum class Language { icelandic, english }
