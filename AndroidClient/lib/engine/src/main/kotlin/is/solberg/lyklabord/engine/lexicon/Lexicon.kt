package `is`.solberg.lyklabord.engine.lexicon

/**
 * Frequency lexicon for ranking and prediction.
 *
 * Distinct from `BinaryLemmatizer` (which answers "is this a valid Icelandic
 * form, and what's its lemma/morphology") — a `Lexicon` answers "how common is
 * this word / this word pair", which is what autocorrect ranking and next-word
 * prediction need.
 *
 * 1:1 port of `Packages/Lexicon/Sources/Lexicon/Lexicon.swift`.
 */
interface Lexicon {
    /** Unigram frequency of a (lowercased) word; null if unknown. */
    fun frequency(of: String): UInt?

    /** Frequency of the bigram "first second"; null if unseen. */
    fun bigramFrequency(first: String, second: String): UInt?

    /** Up to [limit] known words starting with [prefix], descending frequency. */
    fun completions(of: String, limit: Int): List<LexEntry>

    /** Up to [limit] words that follow [word] in the bigram table, descending bigram frequency. */
    fun continuations(of: String, limit: Int): List<LexEntry> = emptyList()

    /** Sum of all unigram frequencies (for probability normalization). */
    val totalUnigramTokens: ULong
}

/** A `(word, frequency)` pair, mirroring the Swift tuple `(word:frequency:)`. */
data class LexEntry(val word: String, val frequency: UInt)
