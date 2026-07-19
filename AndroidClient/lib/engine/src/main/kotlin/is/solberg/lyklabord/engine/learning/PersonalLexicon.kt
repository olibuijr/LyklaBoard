package `is`.solberg.lyklabord.engine.learning

import `is`.solberg.lyklabord.engine.lexicon.LexEntry
import `is`.solberg.lyklabord.engine.lexicon.Lexicon

/** Immutable Lexicon snapshot of learned and user-added surface forms. */
class PersonalLexicon(model: PersonalModel) : Lexicon {
    private val unigrams: Map<String, UInt>
    private val bigrams: Map<String, UInt>
    override val totalUnigramTokens: ULong

    init {
        val uni = linkedMapOf<String, UInt>()
        model.learnedWords.forEach { uni[it] = model.frequency(of = it) ?: 0u }
        model.userAddedWords.forEach { uni[it] = model.frequency(of = it) ?: 1u }
        unigrams = uni
        val bi = linkedMapOf<String, UInt>()
        model.bigrams.forEach { (key, count) ->
            val space = key.indexOf(' ')
            if (space < 0) return@forEach
            val first = key.substring(0, space)
            val second = key.substring(space + 1)
            if (!model.isTombstoned(first) && !model.isTombstoned(second)) bi[key] = count
        }
        bigrams = bi
        totalUnigramTokens = unigrams.values.fold(0uL) { total, value -> total + value.toULong() }
    }

    override fun frequency(of: String): UInt? = unigrams[of]
    override fun bigramFrequency(first: String, second: String): UInt? = bigrams["$first $second"]
    override fun completions(of: String, limit: Int): List<LexEntry> =
        if (limit <= 0) emptyList() else unigrams.asSequence().filter { it.key.startsWith(of) }
            .sortedWith(compareByDescending<Map.Entry<String, UInt>> { it.value }.thenBy { it.key })
            .take(limit).map { LexEntry(it.key, it.value) }.toList()
    override fun continuations(of: String, limit: Int): List<LexEntry> =
        if (limit <= 0) emptyList() else bigrams.asSequence().filter { it.key.startsWith("$of ") }
            .map { LexEntry(it.key.removePrefix("$of "), it.value) }
            .sortedWith(compareByDescending<LexEntry> { it.frequency }.thenBy { it.word }).take(limit).toList()
}
