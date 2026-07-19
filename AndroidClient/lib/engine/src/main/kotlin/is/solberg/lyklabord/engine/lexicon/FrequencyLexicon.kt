package `is`.solberg.lyklabord.engine.lexicon

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.Normalizer

/** Errors thrown while opening a `.lex` file. Mirrors `FrequencyLexiconError`. */
sealed class FrequencyLexiconException(message: String) : Exception(message) {
    class InvalidMagic(magic: UInt) :
        FrequencyLexiconException("Invalid binary format: expected magic 0x4c584331, got 0x${magic.toString(16)}")

    class UnsupportedVersion(version: UInt) :
        FrequencyLexiconException("Unsupported version: $version")

    class Truncated(expected: Int, actual: Int) :
        FrequencyLexiconException("Truncated binary: need $expected bytes, file has $actual")
}

/**
 * Binary-format unigram/bigram frequency table.
 *
 * 1:1 port of `Packages/Lexicon/Sources/Lexicon/FrequencyLexicon.swift`. Reads
 * the `LXC1` v1 `.lex` artifact (see `Packages/Lexicon/FORMAT.md`). The backing
 * [ByteBuffer] is never parsed into collections; every lookup does lazy,
 * offset-based reads via binary search.
 *
 * String comparison is byte-exact UTF-8 (code-point order), matching the Python
 * builder's `sorted()` — never [String] comparison, which would apply Unicode
 * canonical equivalence the builder's raw-byte sort does not.
 *
 * The buffer must be little-endian and cover the whole file. Callers on Android
 * pass a memory-mapped `AssetManager.openFd(...)` region; tests pass a mapped or
 * heap buffer of the file bytes.
 */
class FrequencyLexicon(buffer: ByteBuffer) : Lexicon {

    private val data: ByteBuffer = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)

    val version: Int
    val unigramCount: Int
    val bigramCount: Int
    override val totalUnigramTokens: ULong

    private val stringPoolOffset: Int
    private val stringPoolSize: Int
    private val wordOffsetsOffset: Int
    private val wordLengthsOffset: Int
    private val wordFreqsOffset: Int
    private val bigramFirstIdsOffset: Int
    private val bigramSecondIdsOffset: Int
    private val bigramFreqsOffset: Int

    init {
        val count = data.capacity()
        if (count < 32) throw FrequencyLexiconException.Truncated(32, count)

        val magicRaw = data.getInt(0).toUInt()
        if (magicRaw != MAGIC) throw FrequencyLexiconException.InvalidMagic(magicRaw)

        val versionRaw = data.getInt(4).toUInt()
        if (versionRaw != 1u) throw FrequencyLexiconException.UnsupportedVersion(versionRaw)
        version = versionRaw.toInt()

        unigramCount = data.getInt(8).toUInt().toInt()
        bigramCount = data.getInt(12).toUInt().toInt()
        stringPoolSize = data.getInt(16).toUInt().toInt()
        totalUnigramTokens = data.getLong(20).toULong()
        // u32 at 28 is reserved

        var offset = 32
        stringPoolOffset = offset
        offset += stringPoolSize // writer pads the pool itself to 4 bytes

        wordOffsetsOffset = offset
        offset += unigramCount * 4

        wordLengthsOffset = offset
        offset += unigramCount
        offset = (offset + 3) and 3.inv()

        wordFreqsOffset = offset
        offset += unigramCount * 4

        bigramFirstIdsOffset = offset
        offset += bigramCount * 4

        bigramSecondIdsOffset = offset
        offset += bigramCount * 4

        bigramFreqsOffset = offset
        offset += bigramCount * 4

        if (count < offset) throw FrequencyLexiconException.Truncated(offset, count)
    }

    // MARK: - Public API

    override fun frequency(of: String): UInt? {
        val key = normalizedKey(of)
        if (key.isEmpty()) return null
        val idx = findWord(key) ?: return null
        return readU32(wordFreqsOffset + idx * 4)
    }

    override fun bigramFrequency(first: String, second: String): UInt? {
        val k1 = normalizedKey(first)
        val k2 = normalizedKey(second)
        if (k1.isEmpty() || k2.isEmpty()) return null
        val id1 = findWord(k1) ?: return null
        val id2 = findWord(k2) ?: return null
        val idx = findBigram(id1.toUInt(), id2.toUInt()) ?: return null
        return readU32(bigramFreqsOffset + idx * 4)
    }

    override fun completions(of: String, limit: Int): List<LexEntry> {
        if (limit <= 0) return emptyList()
        val key = normalizedKey(of)
        if (key.isEmpty()) return emptyList()

        val lo = lowerBound(key)
        if (lo >= unigramCount) return emptyList()

        val succ = successor(key)
        val hi = if (succ != null) lowerBound(succ) else unigramCount
        if (hi <= lo) return emptyList()

        val scanEnd = minOf(hi, lo + MAX_COMPLETION_SCAN)
        val candidates = ArrayList<LexEntry>(scanEnd - lo)
        for (i in lo until scanEnd) {
            val freq = readU32(wordFreqsOffset + i * 4)
            candidates.add(LexEntry(wordString(i), freq))
        }
        candidates.sortWith(FREQ_DESC_THEN_WORD)
        return if (candidates.size > limit) candidates.subList(0, limit).toList() else candidates
    }

    override fun continuations(of: String, limit: Int): List<LexEntry> {
        if (limit <= 0) return emptyList()
        val key = normalizedKey(of)
        if (key.isEmpty()) return emptyList()

        val id = findWord(key) ?: return emptyList()
        val wid = id.toUInt()

        val lo = bigramLowerBound(wid)
        if (lo >= bigramCount) return emptyList()
        val hi = bigramUpperBound(wid)
        if (hi <= lo) return emptyList()

        val scanEnd = minOf(hi, lo + MAX_COMPLETION_SCAN)
        val candidates = ArrayList<LexEntry>(scanEnd - lo)
        for (i in lo until scanEnd) {
            val secondId = readU32(bigramSecondIdsOffset + i * 4).toInt()
            val freq = readU32(bigramFreqsOffset + i * 4)
            candidates.add(LexEntry(wordString(secondId), freq))
        }
        candidates.sortWith(FREQ_DESC_THEN_WORD)
        return if (candidates.size > limit) candidates.subList(0, limit).toList() else candidates
    }

    /** Raw buffer size in bytes. */
    val bufferSize: Int get() = data.capacity()

    // MARK: - Internals

    /**
     * Lowercase + NFC-normalize a query word/prefix into UTF-8 bytes, the same
     * normalization the builder applies. Folds U+2019 (curly apostrophe) to the
     * straight ASCII apostrophe, matching `build-lexicon.py`.
     */
    private fun normalizedKey(s: String): ByteArray {
        val folded = s.replace('\u2019', '\'').lowercase()
        val nfc = Normalizer.normalize(folded, Normalizer.Form.NFC)
        return nfc.toByteArray(Charsets.UTF_8)
    }

    private fun readU32(byteOffset: Int): UInt = data.getInt(byteOffset).toUInt()

    private fun readU8(byteOffset: Int): Int = data.get(byteOffset).toInt() and 0xFF

    private fun poolString(offset: Int, length: Int): String {
        val start = stringPoolOffset + offset
        val bytes = ByteArray(length)
        for (i in 0 until length) bytes[i] = data.get(start + i)
        return String(bytes, Charsets.UTF_8)
    }

    private fun wordString(index: Int): String {
        val offset = readU32(wordOffsetsOffset + index * 4).toInt()
        val length = readU8(wordLengthsOffset + index)
        return poolString(offset, length)
    }

    /**
     * Lexicographic comparison of [key] against a pool string, by raw UTF-8
     * bytes (unsigned, == Unicode code-point order). Returns -1/0/1.
     */
    private fun compareKey(key: ByteArray, poolOffset: Int, poolLength: Int): Int {
        val base = stringPoolOffset + poolOffset
        val n = minOf(key.size, poolLength)
        var i = 0
        while (i < n) {
            val a = key[i].toInt() and 0xFF
            val b = data.get(base + i).toInt() and 0xFF
            if (a != b) return if (a < b) -1 else 1
            i += 1
        }
        if (key.size == poolLength) return 0
        return if (key.size < poolLength) -1 else 1
    }

    private fun compareKeyAt(key: ByteArray, index: Int): Int {
        val offset = readU32(wordOffsetsOffset + index * 4).toInt()
        val length = readU8(wordLengthsOffset + index)
        return compareKey(key, offset, length)
    }

    /** Exact-match binary search over the alphabetically sorted word index. */
    private fun findWord(key: ByteArray): Int? {
        var left = 0
        var right = unigramCount - 1
        while (left <= right) {
            val mid = (left + right) ushr 1
            val c = compareKeyAt(key, mid)
            when {
                c == 0 -> return mid
                c > 0 -> left = mid + 1
                else -> right = mid - 1
            }
        }
        return null
    }

    /** Leftmost index i such that word[i] >= key (standard lower_bound). */
    private fun lowerBound(key: ByteArray): Int {
        var lo = 0
        var hi = unigramCount
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (compareKeyAt(key, mid) <= 0) hi = mid else lo = mid + 1
        }
        return lo
    }

    /**
     * Lexicographic successor of a byte string: smallest byte string strictly
     * greater than every string with [bytes] as a prefix. Null when all-0xFF.
     */
    private fun successor(bytes: ByteArray): ByteArray? {
        val result = bytes.copyOf()
        var end = result.size
        while (end > 0) {
            val last = result[end - 1].toInt() and 0xFF
            if (last == 0xFF) {
                end -= 1
            } else {
                val trimmed = result.copyOf(end)
                trimmed[end - 1] = (last + 1).toByte()
                return trimmed
            }
        }
        return null
    }

    private fun bigramLowerBound(firstId: UInt): Int {
        var lo = 0
        var hi = bigramCount
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            val f = readU32(bigramFirstIdsOffset + mid * 4)
            if (f >= firstId) hi = mid else lo = mid + 1
        }
        return lo
    }

    private fun bigramUpperBound(firstId: UInt): Int {
        var lo = 0
        var hi = bigramCount
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            val f = readU32(bigramFirstIdsOffset + mid * 4)
            if (f > firstId) hi = mid else lo = mid + 1
        }
        return lo
    }

    private fun findBigram(id1: UInt, id2: UInt): Int? {
        var left = 0
        var right = bigramCount - 1
        while (left <= right) {
            val mid = (left + right) ushr 1
            val f = readU32(bigramFirstIdsOffset + mid * 4)
            val s = readU32(bigramSecondIdsOffset + mid * 4)
            if (f == id1 && s == id2) return mid
            if (f < id1 || (f == id1 && s < id2)) left = mid + 1 else right = mid - 1
        }
        return null
    }

    // MARK: - Prefix-cursor support (see PrefixSearch.kt)

    internal fun prefixWordLength(index: Int): Int = readU8(wordLengthsOffset + index)

    internal fun prefixWordString(index: Int): String = wordString(index)

    internal fun prefixWordFrequency(index: Int): UInt = readU32(wordFreqsOffset + index * 4)

    /**
     * The UTF-8 bytes of the single Unicode scalar starting at byte [depth] of
     * word [index] (scalar length from the lead byte, clamped to the word end).
     * Callers guarantee `depth < length`.
     */
    internal fun prefixScalarBytes(index: Int, depth: Int, length: Int): ByteArray {
        val offset = readU32(wordOffsetsOffset + index * 4).toInt()
        val base = stringPoolOffset + offset
        val lead = data.get(base + depth).toInt() and 0xFF
        val scalarLength = when {
            lead < 0x80 -> 1
            lead < 0xE0 -> 2
            lead < 0xF0 -> 3
            else -> 4
        }
        val endByte = minOf(depth + scalarLength, length)
        val out = ByteArray(endByte - depth)
        for (i in depth until endByte) out[i - depth] = data.get(base + i)
        return out
    }

    /**
     * Compare word [index]'s bytes at `[depth, depth + bytes.size)` against
     * [bytes]. A word too short to cover the window sorts before it (-1).
     */
    private fun suffixCompare(index: Int, bytes: ByteArray, depth: Int): Int {
        val offset = readU32(wordOffsetsOffset + index * 4).toInt()
        val length = readU8(wordLengthsOffset + index)
        val base = stringPoolOffset + offset
        var i = 0
        while (i < bytes.size) {
            val wordIndex = depth + i
            if (wordIndex >= length) return -1
            val a = data.get(base + wordIndex).toInt() and 0xFF
            val b = bytes[i].toInt() and 0xFF
            if (a != b) return if (a < b) -1 else 1
            i += 1
        }
        return 0
    }

    /**
     * Binary search restricted to [cursor]'s range: leftmost index whose suffix
     * window compares `>= bytes` ([strict] false) or `> bytes` ([strict] true).
     */
    internal fun suffixBound(bytes: ByteArray, depth: Int, cursor: LexiconPrefixCursor, strict: Boolean): Int {
        var lo = cursor.lowerBound
        var hi = cursor.upperBound
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            val c = suffixCompare(mid, bytes, depth)
            if (if (strict) c > 0 else c >= 0) hi = mid else lo = mid + 1
        }
        return lo
    }

    companion object {
        private val MAGIC: UInt = 0x4C584331u // "LXC1" little-endian
        private const val MAX_COMPLETION_SCAN = 20_000

        private val FREQ_DESC_THEN_WORD = Comparator<LexEntry> { a, b ->
            if (a.frequency != b.frequency) {
                if (a.frequency > b.frequency) -1 else 1
            } else {
                a.word.compareTo(b.word)
            }
        }
    }
}
