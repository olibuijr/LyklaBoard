package `is`.solberg.lyklabord.engine.lexicon

import java.io.File

/**
 * Always-on supplementary vocabulary loaded from one surface form per line.
 *
 * Matching is case-folded while [forms] and [allWords] preserve the first
 * spelling seen for each key, just like the Swift implementation.
 */
private fun parseCuratedLines(lines: Sequence<String>): List<String> = lines
    .map { it.trim() }
    .filter { it.isNotEmpty() && !it.startsWith("#") }
    .toList()

class CuratedVocabulary(
    surfaceForms: Iterable<String>,
    count: UInt = DEFAULT_COUNT,
) {
    private val seedCount = count

    data class Word(val word: String, val count: UInt)

    private val entries: List<Word>
    private val keys: Set<String>

    /** The de-duplicated, case-preserving surface forms in input order. */
    val forms: Set<String>

    /** Number of curated entries after case-folded de-duplication. */
    val count: Int
        get() = entries.size

    init {
        val seen = LinkedHashSet<String>()
        val unique = ArrayList<Word>()
        for (form in surfaceForms) {
            val key = form.lowercase()
            if (seen.add(key)) unique += Word(form, seedCount)
        }
        keys = seen
        entries = unique
        forms = unique.mapTo(LinkedHashSet(unique.size)) { it.word }
    }

    constructor(surfaceForms: Array<String>, count: UInt = DEFAULT_COUNT) : this(surfaceForms.asIterable(), count)
    constructor(text: String, count: UInt = DEFAULT_COUNT) : this(parseCuratedLines(text.lineSequence()), count)


    /** All valid curated unigrams, preserving their display casing and seed count. */
    fun allWords(): List<Word> = entries

    /** Curated vocabulary has no personal bigram data. */
    fun continuations(first: String, limit: Int): List<Word> = emptyList()

    /** Curated vocabulary has no personal bigram data. */
    fun bigramCount(first: String, second: String): UInt? = null

    /** Curated entries cannot be tombstoned. */
    fun isTombstoned(word: String): Boolean = false

    /** Every curated entry is explicit. */
    fun isExplicit(word: String): Boolean = keys.contains(word.lowercase())

    /** Whether this vocabulary contains [word], matched case-insensitively. */
    fun contains(word: String): Boolean = keys.contains(word.lowercase())

    companion object {
        const val DEFAULT_COUNT: UInt = 8u

        /** Parse already split lines using the bundled-file rules. */
        fun fromLines(lines: Iterable<String>, count: UInt = DEFAULT_COUNT): CuratedVocabulary? {
            val forms = parseCuratedLines(lines.asSequence())
            return forms.takeIf { it.isNotEmpty() }?.let { CuratedVocabulary(it, count) }
        }

        /** Parse text using the bundled-file rules: trim, skip blanks/comments. */
        fun fromText(text: String, count: UInt = DEFAULT_COUNT): CuratedVocabulary? =
            fromLines(text.lineSequence().asIterable(), count)

        /** Load and parse a UTF-8 vocabulary file; null on missing/invalid/empty input. */
        fun fromFile(file: File, count: UInt = DEFAULT_COUNT): CuratedVocabulary? =
            runCatching { fromText(file.readText(Charsets.UTF_8), count) }.getOrNull()
    }
}
