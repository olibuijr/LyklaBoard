package `is`.solberg.lyklabord.engine.morph

import `is`.solberg.lyklabord.engine.ParadigmsProviding
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Part of speech of a PAR1 paradigm lemma group. */
enum class ParadigmPOS(val rawValue: UByte) {
    noun(0u),
    adjective(1u),
}

/** Packed BÍN grammatical feature bundle stored per PAR1 entry. */
data class ParadigmBundle(val rawValue: UShort) {
    val caseCode: Int
        get() = rawValue.toInt() and 0x3
    val caseName: String
        get() = caseNames[caseCode]
    val isPlural: Boolean
        get() = ((rawValue.toInt() shr 2) and 0x1) == 1
    val pos: ParadigmPOS
        get() = if (((rawValue.toInt() shr 3) and 0x1) == 0) ParadigmPOS.noun else ParadigmPOS.adjective
    val isDefinite: Boolean
        get() = pos == ParadigmPOS.noun && ((rawValue.toInt() shr 4) and 0x1) == 1
    val adjectiveGenderCode: Int
        get() = (rawValue.toInt() shr 4) and 0x3
    val adjectiveDegreeCode: Int
        get() = (rawValue.toInt() shr 6) and 0x3
    val adjectiveIsWeak: Boolean
        get() = ((rawValue.toInt() shr 8) and 0x1) == 1

    fun replacingCase(code: Int): ParadigmBundle =
        ParadigmBundle((((rawValue.toInt() and 0xfffc) or (code and 0x3)).toUShort()))

    val description: String
        get() {
            val number = if (isPlural) "ft" else "et"
            if (pos == ParadigmPOS.noun) {
                return "no:$caseName:$number:${if (isDefinite) "gr" else "ngr"}"
            }
            val gender = arrayOf("kk", "kvk", "hk", "?")[adjectiveGenderCode]
            val degree = arrayOf("fst", "mst", "est", "?")[adjectiveDegreeCode]
            return "lo:$caseName:$number:$gender:$degree:${if (adjectiveIsWeak) "vb" else "sb"}"
        }

    override fun toString(): String = description

    companion object {
        val caseNames: List<String> = listOf("nf", "þf", "þgf", "ef")

        fun noun(caseCode: Int, plural: Boolean = false, definite: Boolean = false): ParadigmBundle {
            var raw = caseCode and 0x3
            if (plural) raw = raw or (1 shl 2)
            if (definite) raw = raw or (1 shl 4)
            return ParadigmBundle(raw.toUShort())
        }
    }
}

data class ParadigmForm(val form: String, val bundle: ParadigmBundle)

data class ParadigmGroup(
    val lemma: String,
    val pos: ParadigmPOS,
    val genderCode: UByte,
    val forms: List<ParadigmForm>,
)

data class ParadigmAnalysis(
    val lemma: String,
    val pos: ParadigmPOS,
    val genderCode: UByte,
    val bundle: ParadigmBundle,
)

sealed class ParadigmsReaderError(message: String) : Exception(message) {
    class InvalidMagic(val magic: UInt) : ParadigmsReaderError(
        "Invalid paradigms format: expected magic 0x50415231, got 0x${magic.toString(16)}",
    )

    class UnsupportedVersion(val version: UInt) : ParadigmsReaderError("Unsupported paradigms version: $version")

    class Truncated(val expected: Int, val actual: Int) :
        ParadigmsReaderError("Truncated paradigms binary: need $expected bytes, file has $actual")
}

/** Lazy little-endian reader for the PAR1 generation-direction artifact. */
class ParadigmsReader(buffer: ByteBuffer) : ParadigmsProviding {
    private val data: ByteBuffer = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
    private val dataSize: Int = data.limit()

    val version: Int
    val groupCount: Int
    val entryCount: Int
    val formCount: Int
    val minLemmaFreq: Int

    private val stringPoolOffset: Int
    private val groupTableOffset: Int
    private val entriesOffset: Int
    private val formTableOffset: Int
    private val permutationOffset: Int

    init {
        if (dataSize < 32) throw ParadigmsReaderError.Truncated(32, dataSize)
        val magic = readU32(0)
        if (magic != MAGIC) throw ParadigmsReaderError.InvalidMagic(magic)
        val versionRaw = readU32(4)
        if (versionRaw != 1u) throw ParadigmsReaderError.UnsupportedVersion(versionRaw)
        version = versionRaw.toInt()
        val stringPoolSize = checkedCount(readU32(8))
        groupCount = checkedCount(readU32(12))
        entryCount = checkedCount(readU32(16))
        formCount = checkedCount(readU32(20))
        minLemmaFreq = checkedCount(readU32(24))

        var offset = 32L
        stringPoolOffset = offset.toInt()
        offset += stringPoolSize.toLong()
        groupTableOffset = checkedOffset(offset)
        offset += groupCount.toLong() * GROUP_RECORD_SIZE
        entriesOffset = checkedOffset(offset)
        offset += entryCount.toLong() * ENTRY_RECORD_SIZE
        formTableOffset = checkedOffset(offset)
        offset += formCount.toLong() * FORM_RECORD_SIZE
        permutationOffset = checkedOffset(offset)
        offset += entryCount.toLong() * 4L
        val expected = checkedOffset(offset)
        if (dataSize < expected) throw ParadigmsReaderError.Truncated(expected, dataSize)
    }

    override fun groups(ofLemma: String): List<ParadigmGroup> {
        val key = ofLemma.lowercase().toByteArray(Charsets.UTF_8)
        var index = lowerBoundGroup(key)
        val result = ArrayList<ParadigmGroup>()
        while (index < groupCount) {
            val record = groupRecord(index)
            if (compareKey(key, record.lemmaOffset, record.lemmaLen) != 0) break
            val forms = ArrayList<ParadigmForm>(record.entryCount)
            for (entryIndex in record.entryStart until record.entryStart + record.entryCount) {
                val entry = entryRecord(entryIndex)
                forms += ParadigmForm(poolString(entry.formOffset, entry.formLen), ParadigmBundle(entry.bundle.toUShort()))
            }
            result += ParadigmGroup(
                poolString(record.lemmaOffset, record.lemmaLen),
                if (record.pos == 0) ParadigmPOS.noun else ParadigmPOS.adjective,
                record.gender.toUByte(),
                forms,
            )
            index++
        }
        return result
    }

    override fun analyses(ofForm: String): List<ParadigmAnalysis> {
        val key = ofForm.lowercase().toByteArray(Charsets.UTF_8)
        val index = lowerBoundForm(key)
        if (index >= formCount) return emptyList()
        val record = formRecord(index)
        if (compareKey(key, record.formOffset, record.formLen) != 0) return emptyList()
        val result = ArrayList<ParadigmAnalysis>(record.permCount)
        for (permIndex in record.permStart until record.permStart + record.permCount) {
            val entryIndex = readU32(permutationOffset + permIndex * 4).toInt()
            val entry = entryRecord(entryIndex)
            val group = groupRecord(entry.groupIndex)
            result += ParadigmAnalysis(
                poolString(group.lemmaOffset, group.lemmaLen),
                if (group.pos == 0) ParadigmPOS.noun else ParadigmPOS.adjective,
                group.gender.toUByte(),
                ParadigmBundle(entry.bundle.toUShort()),
            )
        }
        return result
    }

    override fun bundles(ofForm: String): List<ParadigmBundle> {
        val key = ofForm.lowercase().toByteArray(Charsets.UTF_8)
        val index = lowerBoundForm(key)
        if (index >= formCount) return emptyList()
        val record = formRecord(index)
        if (compareKey(key, record.formOffset, record.formLen) != 0) return emptyList()
        val result = ArrayList<ParadigmBundle>(record.permCount)
        for (permIndex in record.permStart until record.permStart + record.permCount) {
            val entryIndex = readU32(permutationOffset + permIndex * 4).toInt()
            val bundle = ParadigmBundle(readU16(entriesOffset + entryIndex * ENTRY_RECORD_SIZE + 9).toUShort())
            if (!result.contains(bundle)) result += bundle
        }
        return result
    }

    fun caseCodes(ofForm: String): List<Int> {
        val key = ofForm.lowercase().toByteArray(Charsets.UTF_8)
        val index = lowerBoundForm(key)
        if (index >= formCount) return emptyList()
        val record = formRecord(index)
        if (compareKey(key, record.formOffset, record.formLen) != 0) return emptyList()
        val seen = BooleanArray(4)
        for (permIndex in record.permStart until record.permStart + record.permCount) {
            val entryIndex = readU32(permutationOffset + permIndex * 4).toInt()
            seen[readU16(entriesOffset + entryIndex * ENTRY_RECORD_SIZE + 9) and 0x3] = true
        }
        return seen.indices.filter { seen[it] }
    }

    fun isKnownForm(form: String): Boolean {
        val key = form.lowercase().toByteArray(Charsets.UTF_8)
        val index = lowerBoundForm(key)
        return index < formCount && compareKey(key, formRecord(index).formOffset, formRecord(index).formLen) == 0
    }

    val bufferSize: Int
        get() = dataSize

    private data class GroupRecord(
        val lemmaOffset: Int,
        val lemmaLen: Int,
        val pos: Int,
        val gender: Int,
        val entryStart: Int,
        val entryCount: Int,
    )

    private data class EntryRecord(
        val groupIndex: Int,
        val formOffset: Int,
        val formLen: Int,
        val bundle: Int,
    )

    private data class FormRecord(
        val formOffset: Int,
        val formLen: Int,
        val permStart: Int,
        val permCount: Int,
    )

    private fun groupRecord(index: Int): GroupRecord {
        val base = groupTableOffset + index * GROUP_RECORD_SIZE
        return GroupRecord(
            readU32(base).toInt(),
            readByte(base + 4),
            readByte(base + 5),
            readByte(base + 6),
            readU32(base + 8).toInt(),
            readU32(base + 12).toInt(),
        )
    }

    private fun entryRecord(index: Int): EntryRecord {
        val base = entriesOffset + index * ENTRY_RECORD_SIZE
        return EntryRecord(readU32(base).toInt(), readU32(base + 4).toInt(), readByte(base + 8), readU16(base + 9))
    }

    private fun formRecord(index: Int): FormRecord {
        val base = formTableOffset + index * FORM_RECORD_SIZE
        return FormRecord(readU32(base).toInt(), readByte(base + 4), readU32(base + 8).toInt(), readU32(base + 12).toInt())
    }

    private fun poolString(offset: Int, length: Int): String {
        val bytes = ByteArray(length)
        for (i in bytes.indices) bytes[i] = data.get(stringPoolOffset + offset + i)
        return String(bytes, Charsets.UTF_8)
    }

    private fun compareKey(key: ByteArray, poolOffset: Int, poolLength: Int): Int {
        val base = stringPoolOffset + poolOffset
        val n = minOf(key.size, poolLength)
        for (i in 0 until n) {
            val a = key[i].toInt() and 0xff
            val b = data.get(base + i).toInt() and 0xff
            if (a != b) return if (a < b) -1 else 1
        }
        return when {
            key.size == poolLength -> 0
            key.size < poolLength -> -1
            else -> 1
        }
    }

    private fun lowerBoundGroup(key: ByteArray): Int {
        var low = 0
        var high = groupCount
        while (low < high) {
            val mid = (low + high) shr 1
            val record = groupRecord(mid)
            if (compareKey(key, record.lemmaOffset, record.lemmaLen) > 0) low = mid + 1 else high = mid
        }
        return low
    }

    private fun lowerBoundForm(key: ByteArray): Int {
        var low = 0
        var high = formCount
        while (low < high) {
            val mid = (low + high) shr 1
            val record = formRecord(mid)
            if (compareKey(key, record.formOffset, record.formLen) > 0) low = mid + 1 else high = mid
        }
        return low
    }

    private fun readU32(offset: Int): UInt = data.getInt(offset).toUInt()
    private fun readU16(offset: Int): Int = data.getShort(offset).toInt() and 0xffff
    private fun readByte(offset: Int): Int = data.get(offset).toInt() and 0xff

    private fun checkedCount(value: UInt): Int {
        if (value > Int.MAX_VALUE.toUInt()) throw ParadigmsReaderError.Truncated(Int.MAX_VALUE, dataSize)
        return value.toInt()
    }

    private fun checkedOffset(value: Long): Int {
        if (value > Int.MAX_VALUE) throw ParadigmsReaderError.Truncated(Int.MAX_VALUE, dataSize)
        return value.toInt()
    }

    companion object {
        private const val MAGIC: UInt = 0x5041_5231u
        private const val GROUP_RECORD_SIZE = 16
        private const val ENTRY_RECORD_SIZE = 12
        private const val FORM_RECORD_SIZE = 16
    }
}
