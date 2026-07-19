package `is`.solberg.lyklabord.engine
import `is`.solberg.lyklabord.engine.learning.PersonalModel

/** A surface-form/count pair from the personal vocabulary. */
data class PersonalWord(val word: String, val count: UInt)

/** Engine-facing view of the user's personal learning store. */
interface PersonalVocabulary {
    /** All valid personal unigrams (learned + user-added), excluding tombstones. */
    fun allWords(): List<PersonalWord>

    /** Personal bigram followers of [first], descending count. */
    fun continuations(of: String, limit: Int): List<PersonalWord>

    /** Personal count of an exact surface-form bigram, or null when unseen. */
    fun bigramCount(first: String, second: String): UInt?

    /** Whether the exact surface form was deleted in the dictionary editor. */
    fun isTombstoned(word: String): Boolean

    /** Whether the exact surface form was learned through a deliberate user act. */
    fun isExplicit(word: String): Boolean = false
}

/** Immutable engine-side view over a read-only [PersonalModel] snapshot. */
class PersonalSnapshot(private val model: PersonalModel) : PersonalVocabulary {
    override fun allWords(): List<PersonalWord> {
        val seen = mutableSetOf<String>()
        val words = ArrayList<PersonalWord>()
        for (word in model.learnedWords + model.userAddedWords) {
            if (!seen.add(word)) continue
            words += PersonalWord(word, model.frequency(of = word) ?: 1u)
        }
        return words
    }

    override fun continuations(of: String, limit: Int): List<PersonalWord> =
        model.continuations(of = of, limit = limit).map { PersonalWord(it.word, it.frequency) }

    override fun bigramCount(first: String, second: String): UInt? =
        model.bigramFrequency(first, second)

    override fun isTombstoned(word: String): Boolean = model.isTombstoned(word)

    override fun isExplicit(word: String): Boolean = model.isExplicit(word)
}

/**
 * Mutable holder for an injected personal snapshot plus the in-session learned
 * overlay. All access is confined to the engine's owning queue.
 */
class PersonalStore {
    private data class Entry(var surface: String, var count: UInt, var explicit: Boolean)

    private var snapshot: PersonalVocabulary? = null
    private val index = mutableMapOf<String, Entry>()
    private val session = mutableMapOf<String, Entry>()
    private val displayHints = mutableMapOf<String, String>()

    val isActive: Boolean
        get() = snapshot != null || session.isNotEmpty()

    fun setSnapshot(snapshot: PersonalVocabulary?) {
        this.snapshot = snapshot
        index.clear()
        displayHints.clear()
        if (snapshot == null) return
        for (entry in snapshot.allWords()) {
            val key = entry.word.lowercase()
            val explicit = snapshot.isExplicit(entry.word)
            val existing = index[key]
            if (existing != null) {
                if (entry.count > existing.count) existing.surface = entry.word
                existing.count += entry.count
                existing.explicit = existing.explicit || explicit
            } else {
                index[key] = Entry(entry.word, maxOf(entry.count, 1u), explicit)
            }
        }
    }

    fun learnSession(word: String) {
        val key = word.lowercase()
        val entry = session[key] ?: Entry(word, 0u, true)
        entry.count += 1u
        session[key] = entry
    }

    fun clearSession() {
        session.clear()
    }

    fun forgetSession(word: String) {
        session.remove(word.lowercase())
    }

    fun isValidWord(word: String): Boolean {
        if (!isActive) return false
        val key = word.lowercase()
        return index.containsKey(key) || session.containsKey(key)
    }

    fun isTombstoned(word: String): Boolean {
        val snapshot = snapshot ?: return false
        return caseVariants(word).any { snapshot.isTombstoned(it) }
    }

    fun isExplicitWord(word: String): Boolean {
        val key = word.lowercase()
        return index[key]?.explicit == true || session[key]?.explicit == true
    }

    fun count(of: String): UInt {
        val key = of.lowercase()
        return (index[key]?.count ?: 0u) + (session[key]?.count ?: 0u)
    }

    fun displaySurface(of: String): String? {
        if (!isActive) return null
        val surface = index[of]?.surface ?: session[of]?.surface ?: displayHints[of]
        return if (surface != null && surface != of) surface else null
    }

    fun completions(of: String, limit: Int): List<PersonalWord> {
        if (!isActive || limit <= 0) return emptyList()
        val merged = mutableMapOf<String, UInt>()
        for ((key, entry) in index) {
            if (key.startsWith(of)) merged[key] = (merged[key] ?: 0u) + entry.count
        }
        for ((key, entry) in session) {
            if (key.startsWith(of)) merged[key] = (merged[key] ?: 0u) + entry.count
        }
        return merged.entries
            .sortedWith(compareByDescending<Map.Entry<String, UInt>> { it.value }.thenBy { it.key })
            .take(limit)
            .map { PersonalWord(it.key, it.value) }
    }

    fun continuations(of: String, limit: Int): List<PersonalWord> {
        val snapshot = snapshot ?: return emptyList()
        if (limit <= 0) return emptyList()
        val merged = mutableMapOf<String, UInt>()
        for (variant in caseVariants(of)) {
            for (entry in snapshot.continuations(of = variant, limit = limit)) {
                val key = entry.word.lowercase()
                if (key != entry.word && !index.containsKey(key) && !displayHints.containsKey(key)) {
                    displayHints[key] = entry.word
                }
                merged[key] = maxOf(merged[key] ?: 0u, entry.count)
            }
        }
        return merged.entries
            .sortedWith(compareByDescending<Map.Entry<String, UInt>> { it.value }.thenBy { it.key })
            .take(limit)
            .map { PersonalWord(it.key, it.value) }
    }

    fun bigramCount(first: String, second: String): UInt? {
        val snapshot = snapshot ?: return null
        var best: UInt? = null
        val wordVariants = caseVariants(second).toMutableList()
        index[second.lowercase()]?.surface?.let { canonical ->
            if (canonical !in wordVariants) wordVariants += canonical
        }
        for (firstVariant in caseVariants(first)) {
            for (wordVariant in wordVariants) {
                val count = snapshot.bigramCount(firstVariant, wordVariant) ?: continue
                best = best?.let { maxOf(it, count) } ?: count
            }
        }
        return best
    }

    val allValidKeys: List<String>
        get() = (index.keys + session.keys).toSortedSet().toList()

    val snapshotWords: List<String>
        get() = index.values.map { it.surface }.sorted()

    val sessionWords: List<String>
        get() = session.values.map { it.surface }.sorted()

    companion object {
        fun caseVariants(of: String): List<String> {
            val variants = ArrayList<String>(3)
            variants += of
            val lower = of.lowercase()
            if (lower != of) variants += lower
            if (lower.isNotEmpty()) {
                val capitalized = lower.first().uppercase() + lower.drop(1)
                if (capitalized !in variants) variants += capitalized
            }
            return variants
        }
    }
}
