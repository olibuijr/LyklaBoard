package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.lexicon.LexEntry
import `is`.solberg.lyklabord.engine.lexicon.Lexicon
import `is`.solberg.lyklabord.engine.lexicon.LexiconPrefixCursor
import `is`.solberg.lyklabord.engine.lexicon.PrefixChild
import `is`.solberg.lyklabord.engine.lexicon.PrefixSearchableLexicon

/**
 * Dictionary-backed [Lexicon] for tests and the micro-eval harness.
 *
 * This is an in-memory test double, not a production lexicon reader. Its
 * completion and continuation queries intentionally use linear scans.
 *
 * 1:1 port of `Packages/TypeEngine/Sources/TypeEngine/DictLexicon.swift`.
 */
class DictLexicon(
    unigrams: Map<String, UInt>,
    bigrams: Map<String, UInt> = emptyMap(),
) : PrefixSearchableLexicon {
    private val unigrams: Map<String, UInt> = unigrams
    private val bigrams: Map<String, UInt> = bigrams

    override val totalUnigramTokens: ULong =
        unigrams.values.fold(0UL) { total, frequency -> total + frequency.toULong() }

    /** Words sorted by raw UTF-8 bytes, matching the production `.lex` pool. */
    private val sortedEntries: List<SortedEntry> = unigrams.entries
        .map { entry ->
            SortedEntry(
                bytes = entry.key.toByteArray(Charsets.UTF_8),
                word = entry.key,
                frequency = entry.value,
            )
        }
        .sortedWith { lhs, rhs -> compareUnsignedBytes(lhs.bytes, rhs.bytes) }

    private data class SortedEntry(
        val bytes: ByteArray,
        val word: String,
        val frequency: UInt,
    )

    override fun frequency(of: String): UInt? = unigrams[of]

    override fun bigramFrequency(first: String, second: String): UInt? =
        bigrams["$first $second"]

    override fun completions(of: String, limit: Int): List<LexEntry> {
        if (limit <= 0) return emptyList()
        return unigrams.asSequence()
            .filter { (word, _) -> word.startsWith(of) }
            .map { (word, frequency) -> LexEntry(word, frequency) }
            .sortedWith(FREQUENCY_DESC_THEN_WORD)
            .take(limit)
            .toList()
    }

    /**
     * Bigram followers of [of], descending bigram frequency. This is a linear
     * scan over the bigram table, mirroring `FrequencyLexicon` semantics.
     */
    override fun continuations(of: String, limit: Int): List<LexEntry> {
        if (limit <= 0) return emptyList()
        val prefix = "$of "
        return bigrams.asSequence()
            .mapNotNull { (key, frequency) ->
                if (!key.startsWith(prefix)) return@mapNotNull null
                LexEntry(key.removePrefix(prefix), frequency)
            }
            .sortedWith(FREQUENCY_DESC_THEN_WORD)
            .take(limit)
            .toList()
    }

    override fun prefixRootCursor(): LexiconPrefixCursor =
        LexiconPrefixCursor(
            lowerBound = 0,
            upperBound = sortedEntries.size,
            byteDepth = 0,
        )

    override fun descend(
        cursor: LexiconPrefixCursor,
        bytes: ByteArray,
    ): LexiconPrefixCursor {
        val depth = cursor.byteDepth + bytes.size
        if (cursor.isEmpty || bytes.isEmpty()) {
            return LexiconPrefixCursor(
                lowerBound = cursor.lowerBound,
                upperBound = cursor.lowerBound,
                byteDepth = depth,
            )
        }

        fun compare(index: Int): Int {
            val word = sortedEntries[index].bytes
            var i = 0
            while (i < bytes.size) {
                val j = cursor.byteDepth + i
                if (j >= word.size) return -1
                val wordByte = word[j].toInt() and 0xFF
                val queryByte = bytes[i].toInt() and 0xFF
                if (wordByte != queryByte) return if (wordByte < queryByte) -1 else 1
                i += 1
            }
            return 0
        }

        fun bound(strict: Boolean): Int {
            var lo = cursor.lowerBound
            var hi = cursor.upperBound
            while (lo < hi) {
                val mid = (lo + hi) shr 1
                val comparison = compare(mid)
                if (if (strict) comparison > 0 else comparison >= 0) {
                    hi = mid
                } else {
                    lo = mid + 1
                }
            }
            return lo
        }

        return LexiconPrefixCursor(
            lowerBound = bound(strict = false),
            upperBound = bound(strict = true),
            byteDepth = depth,
        )
    }

    override fun exactEntry(cursor: LexiconPrefixCursor): LexEntry? {
        if (cursor.isEmpty || cursor.byteDepth <= 0) return null
        val entry = sortedEntries[cursor.lowerBound]
        if (entry.bytes.size != cursor.byteDepth) return null
        return LexEntry(entry.word, entry.frequency)
    }

    override fun childCursors(
        cursor: LexiconPrefixCursor,
        scanLimit: Int,
    ): List<PrefixChild>? {
        if (cursor.count > scanLimit) return null
        if (cursor.isEmpty) return emptyList()

        val children = ArrayList<PrefixChild>()
        var groupStart = -1
        var groupBytes = ByteArray(0)

        fun closeGroup(endingAt: Int) {
            if (groupStart < 0) return
            val character = String(groupBytes, Charsets.UTF_8).firstOrNull() ?: return
            children += PrefixChild(
                character = character,
                cursor = LexiconPrefixCursor(
                    lowerBound = groupStart,
                    upperBound = endingAt,
                    byteDepth = cursor.byteDepth + groupBytes.size,
                ),
            )
        }

        for (index in cursor.lowerBound until cursor.upperBound) {
            val word = sortedEntries[index].bytes
            if (word.size <= cursor.byteDepth) continue

            val lead = word[cursor.byteDepth].toInt() and 0xFF
            val scalarLength = when {
                lead < 0x80 -> 1
                lead < 0xE0 -> 2
                lead < 0xF0 -> 3
                else -> 4
            }
            val end = minOf(cursor.byteDepth + scalarLength, word.size)
            val bytes = word.copyOfRange(cursor.byteDepth, end)
            if (!bytes.contentEquals(groupBytes)) {
                closeGroup(endingAt = index)
                groupStart = index
                groupBytes = bytes
            }
        }
        closeGroup(endingAt = cursor.upperBound)
        return children
    }

    private companion object {
        val FREQUENCY_DESC_THEN_WORD: Comparator<LexEntry> =
            Comparator { lhs, rhs ->
                when {
                    lhs.frequency != rhs.frequency -> rhs.frequency.compareTo(lhs.frequency)
                    else -> lhs.word.compareTo(rhs.word)
                }
            }
    }
}

private fun compareUnsignedBytes(lhs: ByteArray, rhs: ByteArray): Int {
    val n = minOf(lhs.size, rhs.size)
    var i = 0
    while (i < n) {
        val left = lhs[i].toInt() and 0xFF
        val right = rhs[i].toInt() and 0xFF
        if (left != right) return if (left < right) -1 else 1
        i += 1
    }
    return lhs.size.compareTo(rhs.size)
}
