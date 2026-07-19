package `is`.solberg.lyklabord.engine.learning

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json

object IsoDateSerializer : KSerializer<Date> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("Date", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Date) = encoder.encodeString(format(value))
    override fun deserialize(decoder: Decoder): Date = parse(decoder.decodeString())
    private fun format(value: Date): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(value)
    private fun parse(value: String): Date = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }.parse(value) ?: error("invalid ISO date")
}

@Serializable
data class PersonalModelExport(
    @SerialName("\$schema") val schema: String,
    val format: String,
    val formatVersion: Int,
    val modelSchemaVersion: Int,
    val note: String,
    @Serializable(with = IsoDateSerializer::class) val exportedAt: Date,
    val learnedWords: List<Word>,
    val userAddedWords: List<String>,
    val tombstones: List<String>,
    val bigrams: List<Bigram>,
    val touchStatistics: List<Touch>,
) {
    @Serializable
    data class Word(
        val word: String,
        val count: UInt,
        val icelandic: UInt,
        val english: UInt,
        val unknown: UInt,
        val daysSeen: List<Int>,
        val explicitlyAccepted: Boolean,
        val userAdded: Boolean,
    )
    @Serializable data class Bigram(val first: String, val second: String, val count: UInt)
    @Serializable data class Touch(val key: String, val stats: TouchKeyStats)
}

fun PersonalModel.exportDocument(
    note: String = "Lyklaborð personal dictionary export. See \$schema for the format.",
    schema: String = PersonalModel.exportSchemaURL,
    exportedAt: Date = Date(),
): PersonalModelExport {
    val keys = (words.keys.filter(::isLearned) + userAddedWords).toSet().sorted()
    val exportedWords = keys.map { key ->
        val stats = words[key] ?: PersonalModel.WordStats()
        PersonalModelExport.Word(key, stats.count, stats.icelandicCount, stats.englishCount, stats.unknownCount,
            stats.daysSeen, stats.explicitlyAccepted, isUserAdded(key))
    }
    val exportedBigrams = bigrams.map { (key, count) ->
        val split = key.indexOf(' ')
        if (split >= 0) PersonalModelExport.Bigram(key.substring(0, split), key.substring(split + 1), count)
        else PersonalModelExport.Bigram(key, "", count)
    }.sortedWith(compareBy<PersonalModelExport.Bigram> { it.first }.thenBy { it.second })
    val exportedTouch = touch.map { (key, stats) -> PersonalModelExport.Touch(key, stats) }.sortedBy { it.key }
    return PersonalModelExport(schema, PersonalModel.exportFormatIdentifier, PersonalModel.exportFormatVersion,
        PersonalModel.schemaVersion, note, exportedAt, exportedWords, userAddedWords, tombstones.sorted(), exportedBigrams, exportedTouch)
}

fun PersonalModel.exportedJSONData(
    note: String = "Lyklaborð personal dictionary export. See \$schema for the format.",
    schema: String = PersonalModel.exportSchemaURL,
    exportedAt: Date = Date(),
): ByteArray = Json { encodeDefaults = true; prettyPrint = true }.encodeToString(exportDocument(note, schema, exportedAt)).toByteArray()
