package `is`.solberg.lyklabord.engine.learning

import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

sealed class PersonalModelError(message: String) : Exception(message) {
    class UnsupportedSchemaVersion(val version: Int) : PersonalModelError("Unsupported personal-model schema version $version")
    class IoError(detail: String) : PersonalModelError("Personal model I/O error: $detail")
    class InvalidWord(val word: String) : PersonalModelError("Not a learnable word: $word")
}

class PersonalModel(
    val configuration: Configuration = Configuration(),
) {
    companion object {
        const val schemaVersion: Int = 1
        const val exportFormatIdentifier: String = "lyklabord-personal-export"
        const val exportFormatVersion: Int = 1
        const val exportSchemaURL: String = "https://github.com/jokull/LyklabordApp/blob/main/docs/EXPORT_FORMAT.md"
        internal val json = Json { encodeDefaults = true; ignoreUnknownKeys = true; explicitNulls = true }
        internal fun atomicWrite(file: File, bytes: ByteArray) {
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile ?: File("."), ".${file.name}.${UUID.randomUUID()}.tmp")
            try {
                Files.write(tmp.toPath(), bytes, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)
                try { Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
                catch (_: Exception) { Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING) }
            } catch (e: Exception) { tmp.delete(); throw PersonalModelError.IoError("save failed: $e") }
        }
        fun bigramKey(first: String, second: String): String = "$first $second"
    }

    data class Configuration(
        var learnedDayThreshold: Int = 2,
        var maxDistinctDaysTracked: Int = 8,
        var bigramCap: Int = 20_000,
        var maxWordEntries: Int = 25_000,
        var decayTotalCountCeiling: ULong = 200_000uL,
        var decayFactor: Double = 0.5,
        var touchSampleDecayThreshold: Double = 500.0,
        var touchDecayFactor: Double = 0.5,
    )

    @Serializable
    data class WordStats(
        var count: UInt = 0u,
        var icelandicCount: UInt = 0u,
        var englishCount: UInt = 0u,
        var unknownCount: UInt = 0u,
        var daysSeen: List<Int> = emptyList(),
        var explicitlyAccepted: Boolean = false,
    )

    data class LanguageAttribution(val icelandic: UInt, val english: UInt, val unknown: UInt)
    data class KeyOffset(val dx: Double, val dy: Double, val weight: Double)
    data class Continuation(val word: String, val frequency: UInt)
    data class CompactionSummary(val eventsApplied: Int, val linesSkipped: Int, val decayed: Boolean, var logTruncated: Boolean)

    private var wordsState: MutableMap<String, WordStats> = linkedMapOf()
    private var bigramsState: MutableMap<String, UInt> = linkedMapOf()
    private var tombstonesState: MutableSet<String> = linkedSetOf()
    private var userAddedState: MutableSet<String> = linkedSetOf()
    private var touchState: MutableMap<String, TouchKeyStats> = linkedMapOf()
    var consumedLogMarker: EventLog.ConsumedMarker? = null
        private set

    /** Read-only snapshots for dictionary/export integrations. */
    val words: Map<String, WordStats> get() = wordsState.toMap()
    val bigrams: Map<String, UInt> get() = bigramsState.toMap()
    val tombstones: Set<String> get() = tombstonesState.toSet()
    val userAdded: Set<String> get() = userAddedState.toSet()
    val touch: Map<String, TouchKeyStats> get() = touchState.toMap()
    val wordStats: Map<String, WordStats> get() = words
    val bigramCounts: Map<String, UInt> get() = bigrams
    val tombstonedWords: Set<String> get() = tombstones
    val userAddedWordsSet: Set<String> get() = userAdded
    val touchStatisticsByKey: Map<String, TouchKeyStats> get() = touch

    @Serializable
    private data class StoredMarker(val generation: String, val offset: Long)
    @Serializable
    private data class Stored(
        val schemaVersion: Int,
        val words: Map<String, WordStats>,
        val bigrams: Map<String, UInt>,
        val tombstones: List<String>,
        val userAdded: List<String>,
        val touch: Map<String, TouchKeyStats>,
        val consumedLogMarker: StoredMarker? = null,
    )

    constructor(contentsOf: File, configuration: Configuration = Configuration()) : this(configuration) {
        val stored = try { json.decodeFromString<Stored>(contentsOf.readText(StandardCharsets.UTF_8)) }
        catch (e: PersonalModelError) { throw e }
        catch (e: Exception) { throw PersonalModelError.IoError("load failed: $e") }
        if (stored.schemaVersion != schemaVersion) throw PersonalModelError.UnsupportedSchemaVersion(stored.schemaVersion)
        wordsState = stored.words.toMutableMap()
        bigramsState = stored.bigrams.toMutableMap()
        tombstonesState = stored.tombstones.toMutableSet()
        userAddedState = stored.userAdded.toMutableSet()
        touchState = stored.touch.toMutableMap()
        consumedLogMarker = stored.consumedLogMarker?.let { runCatching { EventLog.ConsumedMarker(UUID.fromString(it.generation), it.offset) }.getOrNull() }
    }

    fun save(to: File) {
        val stored = Stored(schemaVersion, wordsState.toSortedMap(), bigramsState.toSortedMap(), tombstonesState.sorted(),
            userAddedState.sorted(), touchState.toSortedMap(), consumedLogMarker?.let { StoredMarker(it.generation.toString(), it.offset) })
        try { atomicWrite(to, json.encodeToString(stored).toByteArray(StandardCharsets.UTF_8)) }
        catch (e: PersonalModelError) { throw e }
        catch (e: Exception) { throw PersonalModelError.IoError("save failed: $e") }
    }

    fun isLearned(word: String): Boolean {
        if (word in tombstonesState) return false
        if (word in userAddedState) return true
        val stats = wordsState[word] ?: return false
        return stats.explicitlyAccepted || stats.daysSeen.size >= configuration.learnedDayThreshold
    }
    fun isTombstoned(word: String): Boolean = word in tombstonesState
    fun isUserAdded(word: String): Boolean = word in userAddedState
    fun isExplicit(word: String): Boolean = word in userAddedState || wordsState[word]?.explicitlyAccepted == true

    fun frequency(of: String): UInt? {
        if (!isLearned(of)) return null
        val count = wordsState[of]?.count ?: 0u
        return if (of in userAddedState) maxOf(count, 1u) else count
    }
    fun commitCount(of: String): UInt = wordsState[of]?.count ?: 0u
    fun languageAttribution(of: String): LanguageAttribution? = wordsState[of]?.let { LanguageAttribution(it.icelandicCount, it.englishCount, it.unknownCount) }
    fun bigramFrequency(first: String, second: String): UInt? = bigramsState[bigramKey(first, second)]

    fun continuations(of: String, limit: Int): List<Continuation> {
        if (limit <= 0) return emptyList()
        val prefix = "$of "
        return bigramsState.asSequence().filter { (key, _) -> key.startsWith(prefix) }.mapNotNull { (key, count) ->
            val follower = key.removePrefix(prefix)
            if (follower in tombstonesState) null else Continuation(follower, count)
        }.sortedWith(compareByDescending<Continuation> { it.frequency }.thenBy { it.word }).take(limit).toList()
    }

    val learnedWords: List<String> get() = wordsState.keys.filter(::isLearned).sorted()
    val userAddedWords: List<String> get() = userAddedState.sorted()

    fun remove(word: String) {
        wordsState.remove(word); userAddedState.remove(word); tombstonesState.add(word)
        val first = "$word "; val second = " $word"
        bigramsState.entries.removeIf { (key, _) -> key.startsWith(first) || key.endsWith(second) }
    }
    fun addUserWord(word: String) {
        if (!EventLog.isLearnableWord(word)) throw PersonalModelError.InvalidWord(word)
        tombstonesState.remove(word); userAddedState.add(word)
    }
    fun removeTombstone(word: String) { tombstonesState.remove(word) }

    fun upsertExplicitEntry(word: String, seedCount: UInt) {
        val old = wordsState[word] ?: WordStats()
        old.explicitlyAccepted = true
        old.count = maxOf(old.count, seedCount)
        old.unknownCount = maxOf(old.unknownCount, seedCount)
        wordsState[word] = old
    }

    fun keyOffset(forChar: Char): KeyOffset? = touchState[forChar.toString()]?.takeIf { it.count > 0.0 }?.let { KeyOffset(it.meanDX, it.meanDY, it.count) }
    fun touchStatistics(char: Char): TouchKeyStats? = touchState[char.toString()]
    val touchKeys: List<Char> get() = touchState.keys.sorted().mapNotNull { it.firstOrNull() }
    fun resetTouchModel() { touchState.clear() }

    fun compact(applying: EventLog): CompactionSummary {
        val result = applying.read(consumedLogMarker)
        result.events.forEach(::apply)
        consumedLogMarker = result.endMarker
        val decayed = decayIfNeeded()
        enforceCaps()
        return CompactionSummary(result.events.size, result.skippedLines, decayed, false)
    }

    fun compactAndSave(applying: EventLog, to: File, truncatingLog: Boolean = true): CompactionSummary {
        val summary = compact(applying)
        save(to)
        if (truncatingLog) {
            val marker = consumedLogMarker
            if (marker != null) { consumedLogMarker = applying.truncate(marker); save(to) }
            return summary.copy(logTruncated = marker != null)
        }
        return summary
    }

    private fun apply(logged: LoggedEvent) {
        when (val event = logged.event) {
            is LearningEvent.WordCommitted -> {
                learnCommit(event.word, event.languageHint, logged.day, false)
                if (event.previousWord != null && event.previousWord !in tombstonesState && event.word !in tombstonesState) {
                    val key = bigramKey(event.previousWord, event.word); bigramsState[key] = (bigramsState[key] ?: 0u) + 1u
                }
            }
            is LearningEvent.SuggestionAccepted -> learnCommit(event.accepted, LanguageHint.UNKNOWN, logged.day, false)
            is LearningEvent.CorrectionReverted -> learnCommit(event.original, LanguageHint.UNKNOWN, logged.day, false)
            is LearningEvent.WordTapped -> learnCommit(event.word, LanguageHint.UNKNOWN, logged.day, true)
            is LearningEvent.TouchSample -> {
                val key = event.keyChar.toString(); val stats = touchState[key] ?: TouchKeyStats()
                stats.update(event.dx, event.dy)
                if (stats.count > configuration.touchSampleDecayThreshold) stats.decay(configuration.touchDecayFactor)
                touchState[key] = stats
            }
        }
    }

    private fun learnCommit(word: String, hint: LanguageHint, day: Int, explicit: Boolean) {
        if (word in tombstonesState) return
        val stats = wordsState[word] ?: WordStats()
        stats.count += 1u
        when (hint) { LanguageHint.ICELANDIC -> stats.icelandicCount += 1u; LanguageHint.ENGLISH -> stats.englishCount += 1u; LanguageHint.UNKNOWN -> stats.unknownCount += 1u }
        if (explicit) stats.explicitlyAccepted = true
        if (day !in stats.daysSeen && stats.daysSeen.size < configuration.maxDistinctDaysTracked) stats.daysSeen = (stats.daysSeen + day).sorted()
        wordsState[word] = stats
    }

    private fun decayIfNeeded(): Boolean {
        val total = wordsState.values.fold(0uL) { sum, value -> sum + value.count.toULong() }
        if (total <= configuration.decayTotalCountCeiling) return false
        val factor = configuration.decayFactor
        wordsState = wordsState.mapNotNull { (word, old) ->
            val stats = old.copy(count = (old.count.toDouble() * factor).toUInt(), icelandicCount = (old.icelandicCount.toDouble() * factor).toUInt(), englishCount = (old.englishCount.toDouble() * factor).toUInt(), unknownCount = (old.unknownCount.toDouble() * factor).toUInt())
            if (stats.count == 0u && !stats.explicitlyAccepted && word !in userAddedState) null else word to stats
        }.toMap().toMutableMap()
        bigramsState = bigramsState.mapNotNull { (key, count) -> key to (count.toDouble() * factor).toUInt() }.filter { it.second > 0u }.toMap().toMutableMap()
        return true
    }

    private fun enforceCaps() {
        if (bigramsState.size > configuration.bigramCap) bigramsState = bigramsState.entries.sortedWith(compareByDescending<Map.Entry<String, UInt>> { it.value }.thenBy { it.key }).take(configuration.bigramCap).associate { it.key to it.value }.toMutableMap()
        if (wordsState.size > configuration.maxWordEntries) {
            var overage = wordsState.size - configuration.maxWordEntries
            wordsState.entries.filter { !it.value.explicitlyAccepted && it.key !in userAddedState }.sortedWith(compareBy<Map.Entry<String, WordStats>> { it.value.count }.thenBy { it.key }).takeWhile { overage-- > 0 }.forEach { wordsState.remove(it.key) }
        }
    }

}
