package `is`.solberg.lyklabord.engine.lexicon

/**
 * A half-open range `[lowerBound, upperBound)` of a lexicon's sorted unigram
 * table, covering exactly the words that share an (implicit) UTF-8 byte prefix
 * of length [byteDepth].
 *
 * 1:1 port of `LexiconPrefixCursor` from
 * `Packages/Lexicon/Sources/Lexicon/PrefixSearch.swift`. [byteDepth] counts
 * BYTES, not characters; callers append whole characters.
 */
data class LexiconPrefixCursor(
    val lowerBound: Int,
    val upperBound: Int,
    val byteDepth: Int,
) {
    /** True when no word carries this prefix. */
    val isEmpty: Boolean get() = lowerBound >= upperBound

    /** Number of words carrying this prefix. */
    val count: Int get() = maxOf(0, upperBound - lowerBound)
}

/** One distinct one-character extension of a cursor's prefix. */
data class PrefixChild(val character: Char, val cursor: LexiconPrefixCursor)

/**
 * Incremental prefix-range navigation over a sorted-pool lexicon — the substrate
 * for beam-search decoding. 1:1 port of the `PrefixSearchableLexicon` protocol.
 */
interface PrefixSearchableLexicon : Lexicon {
    fun prefixRootCursor(): LexiconPrefixCursor

    fun descend(cursor: LexiconPrefixCursor, bytes: ByteArray): LexiconPrefixCursor

    fun exactEntry(cursor: LexiconPrefixCursor): LexEntry?

    fun childCursors(cursor: LexiconPrefixCursor, scanLimit: Int): List<PrefixChild>?

    /** Convenience: narrow by one character. Hot callers precompute byte arrays. */
    fun descend(cursor: LexiconPrefixCursor, character: Char): LexiconPrefixCursor =
        descend(cursor, character.toString().toByteArray(Charsets.UTF_8))
}

/**
 * `FrequencyLexicon` conformance to [PrefixSearchableLexicon]. In Swift this is
 * an extension in the same file; in Kotlin it wraps the reader and delegates the
 * point-lookup surface, reaching the reader's internal prefix shims.
 */
class FrequencyLexiconPrefixSearch(private val lex: FrequencyLexicon) : PrefixSearchableLexicon {

    override val totalUnigramTokens: ULong get() = lex.totalUnigramTokens

    override fun frequency(of: String): UInt? = lex.frequency(of)

    override fun bigramFrequency(first: String, second: String): UInt? =
        lex.bigramFrequency(first, second)

    override fun completions(of: String, limit: Int): List<LexEntry> = lex.completions(of, limit)

    override fun continuations(of: String, limit: Int): List<LexEntry> = lex.continuations(of, limit)

    override fun prefixRootCursor(): LexiconPrefixCursor =
        LexiconPrefixCursor(lowerBound = 0, upperBound = lex.unigramCount, byteDepth = 0)

    override fun descend(cursor: LexiconPrefixCursor, bytes: ByteArray): LexiconPrefixCursor {
        val depth = cursor.byteDepth + bytes.size
        if (cursor.isEmpty || bytes.isEmpty()) {
            return LexiconPrefixCursor(cursor.lowerBound, cursor.lowerBound, depth)
        }
        val lo = lex.suffixBound(bytes, cursor.byteDepth, cursor, strict = false)
        val hi = lex.suffixBound(bytes, cursor.byteDepth, cursor, strict = true)
        return LexiconPrefixCursor(lowerBound = lo, upperBound = hi, byteDepth = depth)
    }

    override fun exactEntry(cursor: LexiconPrefixCursor): LexEntry? {
        if (cursor.isEmpty || cursor.byteDepth <= 0) return null
        val index = cursor.lowerBound
        if (lex.prefixWordLength(index) != cursor.byteDepth) return null
        return LexEntry(lex.prefixWordString(index), lex.prefixWordFrequency(index))
    }

    override fun childCursors(cursor: LexiconPrefixCursor, scanLimit: Int): List<PrefixChild>? {
        if (cursor.count > scanLimit) return null
        if (cursor.isEmpty) return emptyList()

        val children = ArrayList<PrefixChild>()
        var groupStart = -1
        var groupBytes = ByteArray(0)

        fun closeGroup(end: Int) {
            if (groupStart < 0) return
            val scalar = String(groupBytes, Charsets.UTF_8)
            val character = scalar.firstOrNull() ?: return
            children.add(
                PrefixChild(
                    character = character,
                    cursor = LexiconPrefixCursor(
                        lowerBound = groupStart,
                        upperBound = end,
                        byteDepth = cursor.byteDepth + groupBytes.size,
                    ),
                ),
            )
        }

        for (index in cursor.lowerBound until cursor.upperBound) {
            val length = lex.prefixWordLength(index)
            if (length <= cursor.byteDepth) continue
            val bytes = lex.prefixScalarBytes(index, cursor.byteDepth, length)
            if (!bytes.contentEquals(groupBytes)) {
                closeGroup(index)
                groupStart = index
                groupBytes = bytes
            }
        }
        closeGroup(cursor.upperBound)
        return children
    }
}
