package `is`.solberg.lyklabord.engine.morph

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.Normalizer

/** Icelandic word class (part-of-speech) tags used by BÍN / lemma-is. */
enum class WordClass(val rawValue: String) {
    noun("no"),
    verb("so"),
    adjective("lo"),
    adverb("ao"),
    preposition("fs"),
    pronoun("fn"),
    conjunction("st"),
    numeral("to"),
    article("gr"),
    interjection("uh"),
}

/** A lemma together with its word class. */
data class LemmaWithPOS(
    val lemma: String,
    val pos: String,
)

/** Grammatical morph features (only populated by version 2 binaries). */
data class MorphFeatures(
    val grammaticalCase: String?,
    val gender: String?,
    val number: String?,
) {
    val isEmpty: Boolean
        get() = grammaticalCase == null && gender == null && number == null
}

/** A lemma with word class and optional morph features. */
data class LemmaWithMorph(
    val lemma: String,
    val pos: String,
    val morph: MorphFeatures?,
)

/** The morphology seam consumed by the type engine. */
interface MorphologyProviding {
    fun isKnown(word: String): Boolean
    fun nounAdjectiveCases(of: String): List<String> = emptyList()
    fun lemmaCandidates(of: String): List<String> = emptyList()
    fun hasOpenClassAnalysis(word: String): Boolean = isKnown(word)
}

/** Errors thrown while opening a `.bin` morphology artifact. */
sealed class BinaryLemmatizerException(message: String) : Exception(message) {
    class InvalidMagic(magic: UInt) :
        BinaryLemmatizerException(
            "Invalid binary format: expected magic 0x4c454d41, got 0x${magic.toString(16)}",
        )

    class UnsupportedVersion(version: UInt) :
        BinaryLemmatizerException("Unsupported version: $version")

    class Truncated(expected: Int, actual: Int) :
        BinaryLemmatizerException("Truncated binary: need $expected bytes, file has $actual")
}

/**
 * Binary-format Icelandic lemmatizer, a direct port of
 * `Packages/LemmaCore/Sources/LemmaCore/BinaryLemmatizer.swift`.
 *
 * The backing buffer is retained and all sections are read lazily. Strings are
 * compared by unsigned UTF-8 bytes, never by Kotlin collation or String order.
 */
class BinaryLemmatizer(buffer: ByteBuffer) : MorphologyProviding {
    private val data: ByteBuffer = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
    private val dataSize: Int = data.limit()

    val version: Int
    val lemmaCount: Int
    val wordFormCount: Int
    val entryCount: Int
    val bigramCount: Int

    private val stringPoolOffset: Int
    private val stringPoolSize: Int
    private val lemmaOffsetsOffset: Int
    private val lemmaLengthsOffset: Int
    private val wordOffsetsOffset: Int
    private val wordLengthsOffset: Int
    private val entryOffsetsOffset: Int
    private val entriesOffset: Int
    private val bigramW1OffsetsOffset: Int
    private val bigramW1LengthsOffset: Int
    private val bigramW2OffsetsOffset: Int
    private val bigramW2LengthsOffset: Int
    private val bigramFreqsOffset: Int

    init {
        if (dataSize < HEADER_SIZE) throw BinaryLemmatizerException.Truncated(HEADER_SIZE, dataSize)

        val magic = readU32(0)
        if (magic != MAGIC) throw BinaryLemmatizerException.InvalidMagic(magic)

        val versionRaw = readU32(4)
        if (versionRaw != 1u && versionRaw != 2u) {
            throw BinaryLemmatizerException.UnsupportedVersion(versionRaw)
        }
        version = versionRaw.toInt()

        stringPoolSize = checkedHeaderCount(readU32(8))
        lemmaCount = checkedHeaderCount(readU32(12))
        wordFormCount = checkedHeaderCount(readU32(16))
        entryCount = checkedHeaderCount(readU32(20))
        bigramCount = checkedHeaderCount(readU32(24))

        var offset = HEADER_SIZE
        stringPoolOffset = offset
        offset = advance(offset, stringPoolSize.toLong())

        lemmaOffsetsOffset = offset
        offset = advance(offset, lemmaCount.toLong() * 4L)

        lemmaLengthsOffset = offset
        offset = advance(offset, lemmaCount.toLong())
        offset = align4(offset)

        wordOffsetsOffset = offset
        offset = advance(offset, wordFormCount.toLong() * 4L)

        wordLengthsOffset = offset
        offset = advance(offset, wordFormCount.toLong())
        offset = align4(offset)

        entryOffsetsOffset = offset
        offset = advance(offset, (wordFormCount.toLong() + 1L) * 4L)

        entriesOffset = offset
        offset = advance(offset, entryCount.toLong() * 4L)

        bigramW1OffsetsOffset = offset
        offset = advance(offset, bigramCount.toLong() * 4L)

        bigramW1LengthsOffset = offset
        offset = advance(offset, bigramCount.toLong())
        offset = align4(offset)

        bigramW2OffsetsOffset = offset
        offset = advance(offset, bigramCount.toLong() * 4L)

        bigramW2LengthsOffset = offset
        offset = advance(offset, bigramCount.toLong())
        offset = align4(offset)

        bigramFreqsOffset = offset
        offset = advance(offset, bigramCount.toLong() * 4L)

        if (dataSize < offset) throw BinaryLemmatizerException.Truncated(offset, dataSize)
    }

    /** Look up possible lemmas for a word form. Unknown words echo the normalized word. */
    fun lemmatize(word: String, wordClass: WordClass? = null): List<String> {
        val normalized = normalize(word)
        val key = normalized.toByteArray(Charsets.UTF_8)
        val idx = findWord(key) ?: return listOf(normalized)
        val start = readU32(entryOffsetsOffset + idx * 4).toInt()
        val end = readU32(entryOffsetsOffset + (idx + 1) * 4).toInt()
        val seen = HashSet<String>()
        val result = ArrayList<String>(minOf(end - start, 4))

        for (i in start until end) {
            val entry = readU32(entriesOffset + i * 4)
            val posCode = entry and 0xFu
            if (wordClass != null && posCode >= POS_CODES.size.toUInt()) continue
            if (wordClass != null && POS_CODES[posCode.toInt()] != wordClass.rawValue) continue
            val lemma = lemmaString((if (version == 1) entry shr 4 else entry shr 10).toInt())
            if (seen.add(lemma)) result.add(lemma)
        }
        return if (result.isEmpty()) listOf(normalized) else result
    }

    /** Look up lemmas with their word class (POS) tags. Unknown words return an empty list. */
    fun lemmatizeWithPOS(word: String): List<LemmaWithPOS> {
        val key = normalize(word).toByteArray(Charsets.UTF_8)
        val idx = findWord(key) ?: return emptyList()
        val start = readU32(entryOffsetsOffset + idx * 4).toInt()
        val end = readU32(entryOffsetsOffset + (idx + 1) * 4).toInt()
        val seen = HashSet<String>()
        val result = ArrayList<LemmaWithPOS>()

        for (i in start until end) {
            val entry = readU32(entriesOffset + i * 4)
            val lemma = lemmaString((if (version == 1) entry shr 4 else entry shr 10).toInt())
            val posCode = entry and 0xFu
            val pos = if (posCode < POS_CODES.size.toUInt()) POS_CODES[posCode.toInt()] else ""
            if (seen.add("$lemma:$pos")) result.add(LemmaWithPOS(lemma, pos))
        }
        return result
    }

    /** Look up lemmas with word class and optional morphological features. */
    fun lemmatizeWithMorph(word: String): List<LemmaWithMorph> {
        val key = normalize(word).toByteArray(Charsets.UTF_8)
        val idx = findWord(key) ?: return emptyList()
        val start = readU32(entryOffsetsOffset + idx * 4).toInt()
        val end = readU32(entryOffsetsOffset + (idx + 1) * 4).toInt()
        val result = ArrayList<LemmaWithMorph>()

        for (i in start until end) {
            val entry = readU32(entriesOffset + i * 4)
            val lemmaIndex: Int
            val posCode: UInt
            val caseCode: UInt
            val genderCode: UInt
            val numberCode: UInt
            if (version == 1) {
                lemmaIndex = (entry shr 4).toInt()
                posCode = entry and 0xFu
                caseCode = 0u
                genderCode = 0u
                numberCode = 0u
            } else {
                lemmaIndex = (entry shr 10).toInt()
                posCode = entry and 0xFu
                caseCode = (entry shr 4) and 0x7u
                genderCode = (entry shr 7) and 0x3u
                numberCode = (entry shr 9) and 0x1u
            }
            val morph = MorphFeatures(
                grammaticalCase = CASE_CODES.getOrNull(caseCode.toInt()),
                gender = GENDER_CODES.getOrNull(genderCode.toInt()),
                number = NUMBER_CODES.getOrNull(numberCode.toInt()),
            )
            val pos = if (posCode < POS_CODES.size.toUInt()) POS_CODES[posCode.toInt()] else ""
            result.add(LemmaWithMorph(lemmaString(lemmaIndex), pos, if (morph.isEmpty) null else morph))
        }
        return result
    }

    override fun isKnown(word: String): Boolean = findWord(normalize(word).toByteArray(Charsets.UTF_8)) != null

    /** Whether the form has an open-class (noun, verb, adjective) entry. */
    fun hasOpenClassEntry(word: String): Boolean {
        val idx = findWord(normalize(word).toByteArray(Charsets.UTF_8)) ?: return false
        val start = readU32(entryOffsetsOffset + idx * 4).toInt()
        val end = readU32(entryOffsetsOffset + (idx + 1) * 4).toInt()
        for (i in start until end) if ((readU32(entriesOffset + i * 4) and 0xFu) <= 2u) return true
        return false
    }

    /** Bigram frequency, or zero if not found. */
    fun bigramFreq(word1: String, word2: String): UInt {
        val k1 = normalize(word1).toByteArray(Charsets.UTF_8)
        val k2 = normalize(word2).toByteArray(Charsets.UTF_8)
        val idx = findBigram(k1, k2) ?: return 0u
        return readU32(bigramFreqsOffset + idx * 4)
    }

    val hasMorphFeatures: Boolean
        get() = version >= 2

    val bufferSize: Int
        get() = dataSize

    /** Materializes every lemma string; avoid this on the keyboard hot path. */
    fun allLemmas(): List<String> = List(lemmaCount) { lemmaString(it) }

    override fun nounAdjectiveCases(of: String): List<String> = lemmatizeWithMorph(of)
        .asSequence()
        .filter { it.pos == "no" || it.pos == "lo" }
        .mapNotNull { it.morph?.grammaticalCase }
        .toList()

    override fun lemmaCandidates(of: String): List<String> {
        val seen = HashSet<String>()
        return lemmatizeWithPOS(of).mapNotNull { if (seen.add(it.lemma)) it.lemma else null }
    }

    override fun hasOpenClassAnalysis(word: String): Boolean = hasOpenClassEntry(word)

    private fun readU32(byteOffset: Int): UInt = data.getInt(byteOffset).toUInt()

    private fun readU8(byteOffset: Int): Int = data.get(byteOffset).toInt() and 0xFF

    private fun lemmaString(index: Int): String {
        val offset = readU32(lemmaOffsetsOffset + index * 4).toInt()
        return poolString(offset, readU8(lemmaLengthsOffset + index))
    }

    private fun poolString(offset: Int, length: Int): String {
        val start = stringPoolOffset + offset
        val bytes = ByteArray(length)
        for (i in bytes.indices) bytes[i] = data.get(start + i)
        return String(bytes, Charsets.UTF_8)
    }

    private fun compareKey(key: ByteArray, poolOffset: Int, poolLength: Int): Int {
        val base = stringPoolOffset + poolOffset
        val n = minOf(key.size, poolLength)
        var i = 0
        while (i < n) {
            val a = key[i].toInt() and 0xFF
            val b = data.get(base + i).toInt() and 0xFF
            if (a != b) return if (a < b) -1 else 1
            i++
        }
        if (key.size == poolLength) return 0
        return if (key.size < poolLength) -1 else 1
    }

    private fun findWord(key: ByteArray): Int? {
        var left = 0
        var right = wordFormCount - 1
        while (left <= right) {
            val mid = (left + right) ushr 1
            val offset = readU32(wordOffsetsOffset + mid * 4).toInt()
            val c = compareKey(key, offset, readU8(wordLengthsOffset + mid))
            when {
                c == 0 -> return mid
                c > 0 -> left = mid + 1
                else -> right = mid - 1
            }
        }
        return null
    }

    private fun findBigram(k1: ByteArray, k2: ByteArray): Int? {
        var left = 0
        var right = bigramCount - 1
        while (left <= right) {
            val mid = (left + right) ushr 1
            val o1 = readU32(bigramW1OffsetsOffset + mid * 4).toInt()
            var c = compareKey(k1, o1, readU8(bigramW1LengthsOffset + mid))
            if (c == 0) {
                val o2 = readU32(bigramW2OffsetsOffset + mid * 4).toInt()
                c = compareKey(k2, o2, readU8(bigramW2LengthsOffset + mid))
                if (c == 0) return mid
            }
            if (c > 0) left = mid + 1 else right = mid - 1
        }
        return null
    }

    private fun normalize(value: String): String {
        val folded = value.replace('\u2019', '\'').lowercase()
        return Normalizer.normalize(folded, Normalizer.Form.NFC)
    }

    private fun checkedHeaderCount(value: UInt): Int {
        if (value > Int.MAX_VALUE.toUInt()) throw BinaryLemmatizerException.Truncated(Int.MAX_VALUE, dataSize)
        return value.toInt()
    }

    private fun advance(offset: Int, amount: Long): Int {
        val next = offset.toLong() + amount
        if (amount < 0L || next > dataSize.toLong() || next > Int.MAX_VALUE.toLong()) {
            val expected = if (next > Int.MAX_VALUE.toLong()) Int.MAX_VALUE else next.toInt()
            throw BinaryLemmatizerException.Truncated(expected, dataSize)
        }
        return next.toInt()
    }

    private fun align4(offset: Int): Int = advance(offset, ((4 - (offset and 3)) and 3).toLong())

    companion object {
        private const val HEADER_SIZE = 32
        private const val MAGIC: UInt = 0x4C454D41u
        private val POS_CODES = arrayOf("no", "so", "lo", "ao", "fs", "fn", "st", "to", "gr", "uh")
        private val CASE_CODES = arrayOf(null, "nf", "þf", "þgf", "ef", null, null, null)
        private val GENDER_CODES = arrayOf(null, "kk", "kvk", "hk")
        private val NUMBER_CODES = arrayOf("et", "ft")
    }
}
