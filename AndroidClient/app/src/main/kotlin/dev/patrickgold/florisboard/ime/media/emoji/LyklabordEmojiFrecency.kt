package dev.patrickgold.florisboard.ime.media.emoji

import android.content.Context
import java.io.File
import kotlin.math.max
import kotlin.math.pow
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Device-local emoji frecency, persisted in the app's files directory. */
object LyklabordEmojiFrecency {
    private const val FileName = "emojiFrecency.v1.json"
    private const val HalfLifeSeconds = 30.0 * 86_400.0
    private const val MaxEntries = 60
    private val json = Json { ignoreUnknownKeys = true }
    private var cachedFilePath: String? = null
    private var cachedEntries: MutableMap<String, List<Double>>? = null

    /** Popular global + Europe/Iceland-weighted defaults, including Iceland's flag. */
    val seed: List<String> = listOf(
        "😂", "❤️", "🤣", "😭", "🥰", "😍", "😊", "🙏", "👍", "🔥",
        "✨", "🎉", "🥺", "😅", "💀", "👀", "🙌", "😘", "😎", "🇮🇸",
    )

    /** Record one use, lazily decaying its prior score before adding one. */
    @Synchronized
    fun record(context: Context, emoji: String) {
        if (emoji.isEmpty()) return
        val now = now()
        val entries = getEntries(context)
        entries[emoji] = listOf(decayedScore(entries[emoji], now) + 1.0, now)
        if (entries.size > MaxEntries) {
            val strongest = entries.entries
                .sortedByDescending { decayedScore(it.value, now) }
                .take(MaxEntries)
            entries.clear()
            strongest.forEach { (key, value) -> entries[key] = value }
        }
        save(context, entries)
    }

    /** Return personal emojis by decayed score, padded with the stable seed. */
    @Synchronized
    fun top(context: Context, count: Int): List<String> {
        if (count <= 0) return emptyList()
        val now = now()
        val result = getEntries(context)
            .filterValues { it.size == 2 }
            .entries
            .sortedByDescending { decayedScore(it.value, now) }
            .mapTo(mutableListOf()) { it.key }
        for (emoji in seed) {
            if (result.size >= count) break
            if (emoji !in result) result += emoji
        }
        return result.take(count)
    }

    private fun file(context: Context): File = File(context.applicationContext.filesDir, FileName)

    private fun getEntries(context: Context): MutableMap<String, List<Double>> {
        val target = file(context)
        if (cachedEntries == null || cachedFilePath != target.path) {
            cachedFilePath = target.path
            cachedEntries = load(context).toMutableMap()
        }
        return cachedEntries!!
    }

    private fun load(context: Context): Map<String, List<Double>> = runCatching {
        val target = file(context)
        if (!target.isFile) emptyMap() else json.decodeFromString<Map<String, List<Double>>>(target.readText())
    }.getOrDefault(emptyMap())

    private fun save(context: Context, entries: Map<String, List<Double>>) {
        runCatching { file(context).writeText(json.encodeToString(entries)) }
    }

    private fun now(): Double = System.currentTimeMillis() / 1_000.0

    private fun decayFactor(lastTouch: Double, now: Double): Double {
        val elapsed = max(0.0, now - lastTouch)
        return 2.0.pow(-elapsed / HalfLifeSeconds)
    }

    private fun decayedScore(entry: List<Double>?, now: Double): Double {
        if (entry == null || entry.size != 2) return 0.0
        return entry[0] * decayFactor(entry[1], now)
    }
}
