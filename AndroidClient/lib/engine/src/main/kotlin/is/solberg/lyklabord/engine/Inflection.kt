package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfig
import `is`.solberg.lyklabord.engine.morph.MorphologyProviding
import `is`.solberg.lyklabord.engine.morph.ParadigmBundle
import `is`.solberg.lyklabord.engine.morph.ParadigmPOS
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.zip.GZIPInputStream
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

/** Abstraction over the PAR1 artifact, allowing dictionary-backed test fakes. */
interface ParadigmsProviding {
    fun groups(ofLemma: String): List<`is`.solberg.lyklabord.engine.morph.ParadigmGroup>
    fun analyses(ofForm: String): List<`is`.solberg.lyklabord.engine.morph.ParadigmAnalysis>
    fun bundles(ofForm: String): List<ParadigmBundle> = analyses(ofForm).map { it.bundle }.distinct()
}

/** The statistical case-government table from governors.json.gz. */
class GovernorsModel {
    class Governor(
        val mass: Double,
        val caseProbabilities: List<Double>,
        val caseEntropyRatio: Double,
        val nounBundleProbabilities: List<Double>? = null,
    )

    private lateinit var table: Map<String, Governor>
    val governorCount: Int
        get() = table.size

    /** Test/fixture entry point. */
    constructor(table: Map<String, Governor>) {
        this.table = table.toMap()
    }

    /** Decompress and scan a gzip artifact supplied by the caller. */
    constructor(gzippedJSON: ByteArray) {
        table = scanTable(scanGzip(gzippedJSON))
    }
    constructor(gzippedJSON: InputStream) {
        table = scanTable(scanGzip(gzippedJSON))
    }

    fun governor(of: String): Governor? = table[of]

    companion object {
        fun fromJsonData(jsonData: ByteArray): GovernorsModel = GovernorsModel(scanTable(jsonData))

        private fun scanGzip(data: ByteArray): ByteArray {
            if (data.size < 3 || data[0] != 0x1f.toByte() || data[1] != 0x8b.toByte() || data[2] != 8.toByte()) {
                throw GovernorsModelError.NotGzip
            }
            return scanGzip(ByteArrayInputStream(data))
        }

        private fun scanGzip(input: InputStream): ByteArray {
            try {
                GZIPInputStream(input).use { gzip ->
                    val output = ByteArrayOutputStream()
                    val chunk = ByteArray(16 * 1024)
                    while (true) {
                        val count = gzip.read(chunk)
                        if (count < 0) break
                        if (count > 0) output.write(chunk, 0, count)
                    }
                    return output.toByteArray()
                }
            } catch (error: Exception) {
                if (error is GovernorsModelError) throw error
                throw GovernorsModelError.CorruptGzip(error)
            }
        }

        private fun scanTable(bytes: ByteArray): Map<String, Governor> {
            val scanner = Scanner(bytes)
            if (!scanner.seekToKey("governors") || !scanner.consume('{'.code.toByte())) {
                throw GovernorsModelError.MalformedJSON
            }
            val table = LinkedHashMap<String, Governor>(16_384)
            if (scanner.consume('}'.code.toByte())) return table
            do {
                val word = scanner.string()
                if (word == null || !scanner.consume(':'.code.toByte()) || !scanner.consume('{'.code.toByte())) {
                    throw GovernorsModelError.MalformedJSON
                }
                var mass = 0.0
                val probabilities = MutableList(4) { 0.0 }
                var entropyRatio = 0.0
                var nounBundles: MutableList<Double>? = null
                if (!scanner.consume('}'.code.toByte())) {
                    do {
                        val key = scanner.string()
                        if (key == null || !scanner.consume(':'.code.toByte())) throw GovernorsModelError.MalformedJSON
                        when (key) {
                            "mass" -> mass = scanner.number() ?: 0.0
                            "case_entropy_ratio" -> entropyRatio = scanner.number() ?: 0.0
                            "case_distribution" -> {
                                if (!scanner.consume('{'.code.toByte())) throw GovernorsModelError.MalformedJSON
                                if (!scanner.consume('}'.code.toByte())) {
                                    do {
                                        val name = scanner.string()
                                        val p = if (name != null && scanner.consume(':'.code.toByte())) scanner.number() else null
                                        if (name == null || p == null) throw GovernorsModelError.MalformedJSON
                                        val code = ParadigmBundle.caseNames.indexOf(name)
                                        if (code >= 0) probabilities[code] = p
                                    } while (scanner.consume(','.code.toByte()))
                                    if (!scanner.consume('}'.code.toByte())) throw GovernorsModelError.MalformedJSON
                                }
                            }
                            "bundle_distribution" -> {
                                if (!scanner.consume('{'.code.toByte())) throw GovernorsModelError.MalformedJSON
                                if (!scanner.consume('}'.code.toByte())) {
                                    do {
                                        val keyPart = scanner.string()
                                        val p = if (keyPart != null && scanner.consume(':'.code.toByte())) scanner.number() else null
                                        if (keyPart == null || p == null) throw GovernorsModelError.MalformedJSON
                                        val slot = nounSlot(keyPart)
                                        if (slot != null) {
                                            if (nounBundles == null) nounBundles = MutableList(16) { 0.0 }
                                            nounBundles[slot] += p
                                        }
                                    } while (scanner.consume(','.code.toByte()))
                                    if (!scanner.consume('}'.code.toByte())) throw GovernorsModelError.MalformedJSON
                                }
                            }
                            else -> if (!scanner.skipValue()) throw GovernorsModelError.MalformedJSON
                        }
                    } while (scanner.consume(','.code.toByte()))
                    if (!scanner.consume('}'.code.toByte())) throw GovernorsModelError.MalformedJSON
                }
                table[word] = Governor(mass, probabilities, entropyRatio, nounBundles)
            } while (scanner.consume(','.code.toByte()))
            return table
        }

        private fun nounSlot(key: String): Int? {
            val parts = key.split(':')
            if (parts.size != 4 || parts[0] != "no") return null
            val code = ParadigmBundle.caseNames.indexOf(parts[1])
            if (code < 0) return null
            var slot = code
            if (parts[2] == "ft") slot = slot or 4
            if (parts[3] == "gr") slot = slot or 8
            return slot
        }
    }

    class Scanner(private val bytes: ByteArray) {
        private var index = 0

        private fun skipWhitespace() {
            while (index < bytes.size) {
                when (bytes[index].toInt() and 0xff) {
                    0x20, 0x09, 0x0a, 0x0d -> index++
                    else -> return
                }
            }
        }

        fun consume(byte: Byte): Boolean {
            skipWhitespace()
            if (index >= bytes.size || bytes[index] != byte) return false
            index++
            return true
        }

        fun string(): String? {
            if (!consume('"'.code.toByte())) return null
            val start = index
            while (index < bytes.size) {
                val byte = bytes[index]
                if (byte == '\\'.code.toByte()) {
                    index += 2
                    continue
                }
                if (byte == '"'.code.toByte()) {
                    val value = bytes.copyOfRange(start, index).toString(Charsets.UTF_8)
                    index++
                    return value
                }
                index++
            }
            return null
        }

        fun number(): Double? {
            skipWhitespace()
            val start = index
            while (index < bytes.size) {
                when (bytes[index].toInt().and(0xff)) {
                    in '0'.code..'9'.code, '-'.code, '+'.code, '.'.code, 'e'.code, 'E'.code -> index++
                    else -> return bytes.copyOfRange(start, index).toString(Charsets.UTF_8).toDoubleOrNull()
                }
            }
            return bytes.copyOfRange(start, index).toString(Charsets.UTF_8).toDoubleOrNull()
        }

        fun skipValue(): Boolean {
            skipWhitespace()
            if (index >= bytes.size) return false
            val first = bytes[index]
            if (first == '{'.code.toByte() || first == '['.code.toByte()) {
                var depth = 0
                var inString = false
                while (index < bytes.size) {
                    val byte = bytes[index]
                    if (inString) {
                        if (byte == '\\'.code.toByte()) index++
                        else if (byte == '"'.code.toByte()) inString = false
                    } else {
                        when (byte) {
                            '"'.code.toByte() -> inString = true
                            '{'.code.toByte(), '['.code.toByte() -> depth++
                            '}'.code.toByte(), ']'.code.toByte() -> {
                                depth--
                                if (depth == 0) {
                                    index++
                                    return true
                                }
                            }
                        }
                    }
                    index++
                }
                return false
            }
            if (first == '"'.code.toByte()) return string() != null
            while (index < bytes.size) {
                if (bytes[index] == ','.code.toByte() || bytes[index] == '}'.code.toByte() || bytes[index] == ']'.code.toByte()) return true
                index++
            }
            return false
        }

        fun seekToKey(key: String): Boolean {
            if (!consume('{'.code.toByte())) return false
            do {
                val found = string() ?: return false
                if (!consume(':'.code.toByte())) return false
                if (found == key) return true
                if (!skipValue()) return false
            } while (consume(','.code.toByte()))
            return false
        }
    }
}

sealed class GovernorsModelError(message: String) : Exception(message) {
    object MalformedJSON : GovernorsModelError("Malformed governors JSON")
    object NotGzip : GovernorsModelError("Governors artifact is not gzip")
    class CorruptGzip(cause: Throwable? = null) : GovernorsModelError("Corrupt governors gzip") {
        init { initCause(cause) }
    }
}

/** Stage-B artifacts injected into the type engine. */
class InflectionModel(
    val paradigms: ParadigmsProviding,
    val governors: GovernorsModel,
)

/** Shared mutable holder for the injected model and personal lemma lift. */
class InflectionStore {
    var model: InflectionModel? = null
        private set
    var lift: LemmaBoostProviding? = null
        private set

    fun setModel(model: InflectionModel?) {
        this.model = model
    }

    fun rebuildLift(words: List<String>, morphology: MorphologyProviding?, liftNats: Double) {
        val current = model
        if (current == null || morphology == null || liftNats <= 0.0 || words.isEmpty()) {
            lift = null
            return
        }
        val built = PersonalLemmaLift(words, morphology, current.paradigms, liftNats)
        lift = if (built.isEmpty) null else built
    }

    fun governorFit(
        previousWord: String?,
        pIcelandic: Double,
        morphology: MorphologyProviding?,
        config: EngineConfig,
    ): GovernorFit? {
        val current = model ?: return null
        if (config.morphBackoffWeight <= 0.0 || previousWord == null ||
            pIcelandic < config.morphBackoffMinPosterior
        ) return null
        val governor = current.governors.governor(previousWord) ?: return null
        if (governor.mass < config.morphMinGovernorMass) return null
        return GovernorFit(previousWord, governor, current.paradigms, morphology, config.morphBackoffWeight, config.morphCaseFitFloor)
    }
}

/** Precomputed λ_morph case-government scoring context. */
class GovernorFit internal constructor(
    val previousWord: String,
    val governor: GovernorsModel.Governor,
    val paradigms: ParadigmsProviding,
    val morphology: MorphologyProviding?,
    val weight: Double,
    floor: Double,
) {
    val caseLogRatios: List<Double> = governor.caseProbabilities.map { p -> if (p > 0.0) max(ln(p / 0.25), floor) else floor }
    val dominantCaseCode: Int = (1 until 4).fold(0) { best, code ->
        if (governor.caseProbabilities[code] > governor.caseProbabilities[best]) code else best
    }
    val nounSlotRefinements: List<Double>?

    init {
        val bundleProbabilities = governor.nounBundleProbabilities
        if (bundleProbabilities == null) {
            nounSlotRefinements = null
        } else {
            val caseTotals = MutableList(4) { 0.0 }
            for (slot in 0 until 16) caseTotals[slot and 0x3] += bundleProbabilities[slot]
            val refinements = MutableList(16) { floor }
            for (slot in 0 until 16) {
                val total = caseTotals[slot and 0x3]
                val p = bundleProbabilities[slot]
                if (total > 0.0 && p > 0.0) refinements[slot] = min(max(ln((p / total) / 0.25), floor), ln(4.0))
            }
            nounSlotRefinements = refinements
        }
    }

    fun fitNats(`for`: String): Double {
        val bundles = paradigms.bundles(`for`)
        if (bundles.isNotEmpty()) {
            var best = Double.NEGATIVE_INFINITY
            for (bundle in bundles) {
                var fit = caseLogRatios[bundle.caseCode]
                if (bundle.pos == ParadigmPOS.noun && nounSlotRefinements != null) {
                    val slot = bundle.caseCode or (if (bundle.isPlural) 4 else 0) or (if (bundle.isDefinite) 8 else 0)
                    fit += nounSlotRefinements!![slot]
                }
                if (fit > best) best = fit
            }
            return weight * best
        }
        val morph = morphology ?: return 0.0
        var best = Double.NEGATIVE_INFINITY
        for (name in morph.nounAdjectiveCases(`for`)) {
            val code = ParadigmBundle.caseNames.indexOf(name)
            if (code >= 0 && caseLogRatios[code] > best) best = caseLogRatios[code]
        }
        return if (best == Double.NEGATIVE_INFINITY) 0.0 else weight * best
    }

    fun supportedCaseCodes(minSecondProbability: Double): List<Int> {
        val result = mutableListOf(dominantCaseCode)
        var second: Int? = null
        for (code in 0 until 4) {
            if (code == dominantCaseCode) continue
            if (second == null || governor.caseProbabilities[code] > governor.caseProbabilities[second!!]) second = code
        }
        if (second != null && governor.caseProbabilities[second!!] >= minSecondProbability) result += second!!
        return result
    }

    fun wrongFormSiblings(ofValidTyped: String, minAdvantage: Double): List<String> {
        val analyses = paradigms.analyses(ofValidTyped)
        if (analyses.isEmpty()) return emptyList()
        val best = analyses.maxByOrNull { caseLogRatios[it.bundle.caseCode] } ?: return emptyList()
        if (best.bundle.caseCode == dominantCaseCode || caseLogRatios[dominantCaseCode] - caseLogRatios[best.bundle.caseCode] < minAdvantage) return emptyList()
        val target = best.bundle.replacingCase(dominantCaseCode)
        val siblings = ArrayList<String>()
        for (group in paradigms.groups(best.lemma)) {
            if (group.pos != best.pos || group.genderCode != best.genderCode) continue
            for (form in group.forms) if (form.bundle == target && form.form != ofValidTyped && !siblings.contains(form.form)) siblings += form.form
        }
        return siblings
    }
}

/** Multiplicative lemma-level ranking boost seam. */
interface LemmaBoostProviding {
    fun lemmaBoost(forCandidate: String): Double
}

private class PersonalLemmaLift(
    learnedWords: List<String>,
    morphology: MorphologyProviding,
    paradigms: ParadigmsProviding,
    liftNats: Double,
) : LemmaBoostProviding {
    private val learnedKeys = HashSet<String>()
    private val siblingKeys = HashSet<String>()
    private val multiplier = exp(liftNats)
    val isEmpty: Boolean
        get() = siblingKeys.isEmpty()

    init {
        for (word in learnedWords) {
            val key = word.lowercase()
            learnedKeys += key
            val lemmas = morphology.lemmaCandidates(key)
            if (lemmas.size != 1) continue
            val lemma = lemmas.first()
            for (group in paradigms.groups(lemma)) {
                for (form in group.forms) {
                    if (form.form in siblingKeys) continue
                    val attributions = paradigms.analyses(form.form).map { it.lemma }.toSet()
                    if (attributions == setOf(lemma)) siblingKeys += form.form
                }
            }
        }
        siblingKeys.removeAll(learnedKeys)
    }

    override fun lemmaBoost(forCandidate: String): Double {
        val key = forCandidate.lowercase()
        if (key in learnedKeys) return 1.0
        return if (key in siblingKeys) multiplier else 1.0
    }
}
