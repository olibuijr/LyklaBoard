package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfig
import `is`.solberg.lyklabord.engine.morph.MorphologyProviding
import `is`.solberg.lyklabord.engine.morph.ParadigmPOS

/** One legal decomposition of an out-of-vocabulary word. */
data class CompoundSplit(
    /** Non-final parts, in order. */
    val modifiers: List<String>,
    /** The final part, carrying the compound's inflection. */
    val head: String,
)

/** Icelandic compound decomposition with bounded per-token memo caches. */
class CompoundAnalyzer {
    private val splitCache = HashMap<String, CompoundSplit?>()
    private val modifierCache = HashMap<String, Boolean>()
    private val headCache = HashMap<String, Boolean>()
    private val cacheLimit = 4096

    /** Drop all memoized analyses (for example after swapping the inflection model). */
    fun clearCache() {
        splitCache.clear()
        modifierCache.clear()
        headCache.clear()
    }

    private fun <K, V> bound(cache: MutableMap<K, V>) {
        if (cache.size >= cacheLimit) cache.clear()
    }

    /**
     * Return the best legal decomposition of [of] (longest head, then fewest
     * parts), or null. The input is expected to be a lowercased pipeline word.
     */
    fun split(
        of: String,
        morphology: MorphologyProviding,
        paradigms: ParadigmsProviding,
        config: EngineConfig,
    ): CompoundSplit? {
        val minModifier = config.compoundMinModifierLength
        val minHead = config.compoundMinHeadLength
        val chars = of.toList()
        val n = chars.size
        if (n < minModifier + minHead || n > config.compoundMaxWordLength || !chars.all { it.isLetter() }) {
            return null
        }
        if (neverCompounds.containsKey(of)) return null
        if (splitCache.containsKey(of)) return splitCache[of]

        var result: CompoundSplit? = null
        outer@ for (i in minModifier..(n - minHead)) {
            val head = chars.subList(i, n).joinToString("")
            if (!isHead(head, morphology, minHead)) continue
            val maxParts = maxOf(1, config.compoundMaxModifiers)
            for (parts in 1..maxParts) {
                if (i < parts * minModifier) continue
                val modifiers = segmentModifiers(
                    chars.subList(0, i), parts, paradigms, minModifier,
                ) ?: continue
                result = CompoundSplit(modifiers, head)
                break@outer
            }
        }
        bound(splitCache)
        splitCache[of] = result
        return result
    }

    private fun segmentModifiers(
        region: List<Char>,
        parts: Int,
        paradigms: ParadigmsProviding,
        minLength: Int,
    ): List<String>? {
        if (parts == 1) {
            val word = region.joinToString("")
            return if (isModifier(word, paradigms, minLength)) listOf(word) else null
        }
        val lower = minLength
        val upper = region.size - (parts - 1) * minLength
        if (lower > upper) return null
        for (j in lower..upper) {
            val first = region.subList(0, j).joinToString("")
            if (!isModifier(first, paradigms, minLength)) continue
            val rest = segmentModifiers(region.subList(j, region.size), parts - 1, paradigms, minLength)
                ?: continue
            return listOf(first) + rest
        }
        return null
    }

    /** Legal open-class or bound-suffix compound head. */
    fun isHead(part: String, morphology: MorphologyProviding, minLength: Int): Boolean {
        if (part.length < minLength) return false
        headCache[part]?.let { return it }
        val legal = boundHeadForms.contains(part) || morphology.hasOpenClassAnalysis(part)
        bound(headCache)
        headCache[part] = legal
        return legal
    }

    /** Legal paradigm-backed linking-form modifier. */
    fun isModifier(part: String, paradigms: ParadigmsProviding, minLength: Int): Boolean {
        if (part.length < minLength) return false
        modifierCache[part]?.let { return it }
        var legal = false
        for (analysis in paradigms.analyses(part)) {
            val bundle = analysis.bundle
            when (analysis.pos) {
                ParadigmPOS.noun -> {
                    if (bundle.isDefinite) continue
                    if (bundle.caseCode == 3) {
                        legal = true
                    } else if (!bundle.isPlural) {
                        when (analysis.genderCode.toInt()) {
                            0 -> legal = bundle.caseCode == 1
                            1 -> legal = bundle.caseCode == 0
                            2 -> legal = bundle.caseCode == 0 || bundle.caseCode == 1
                        }
                    }
                }
                ParadigmPOS.adjective -> {
                    if (bundle.adjectiveDegreeCode == 0 && !bundle.adjectiveIsWeak && bundle.caseCode == 3) {
                        legal = true
                    }
                }
            }
            if (legal) break
        }
        bound(modifierCache)
        modifierCache[part] = legal
        return legal
    }

    companion object {
        /** Wrongly joined forms that standard Icelandic writes separately. */
        val neverCompounds: Map<String, String> = mapOf(
            "margskonar" to "margs konar",
            "afturábak" to "aftur á bak",
            "afþvíað" to "af því að",
            "annarstaðar" to "annars staðar",
            "fjögurhundruð" to "fjögur hundruð",
            "mikilsháttar" to "mikils háttar",
            "niðrá" to "niður á",
            "níuhundruð" to "níu hundruð",
            "samskonar" to "sams konar",
            "seinnihluta" to "seinni hluta",
        )

        /** BÍN bound-suffix surface forms, legal only as compound heads. */
        val boundHeadForms: Set<String> = setOf(
            "bera", "berana", "berann", "beranna", "berans", "beranum", "berar", "berarnir",
            "beri", "berinn", "berum", "berunum", "bura", "burana", "burann", "buranna",
            "burans", "buranum", "burar", "burarnir", "buri", "burinn", "burum", "burunum",
            "fara", "farana", "farann", "faranna", "farans", "faranum", "farar", "fararnir",
            "fari", "farinn", "freyja", "freyjan", "freyjanna", "freyju", "freyjum", "freyjuna",
            "freyjunnar", "freyjunni", "freyjunum", "freyjur", "freyjurnar", "fygla", "fyglanna", "fygli",
            "fyglin", "fyglinu", "fyglis", "fyglisins", "fyglið", "fyglum", "fyglunum", "förum",
            "förunum", "gjafa", "gjafana", "gjafann", "gjafanna", "gjafans", "gjafanum", "gjafar",
            "gjafarnir", "gjafi", "gjafinn", "gjöfum", "gjöfunum", "gresa", "gresanna", "gresi",
            "gresin", "gresinu", "gresis", "gresisins", "gresið", "gresum", "gresunum", "hafa",
            "hafana", "hafann", "hafanna", "hafans", "hafanum", "hafar", "hafarnir", "hafi",
            "hafinn", "höfum", "höfunum", "ing", "inga", "ingana", "inganna", "ingar",
            "ingarnir", "ingi", "inginn", "inginum", "ingnum", "ings", "ingsins", "ingum",
            "ingunum", "ingur", "ingurinn", "ista", "istana", "istann", "istanna", "istans",
            "istanum", "istar", "istarnir", "isti", "istinn", "istum", "istunum", "leika",
            "leikana", "leikann", "leikanna", "leikans", "leikanum", "leikar", "leikarnir", "leiki",
            "leikinn", "leikum", "leikunum", "leysa", "leysan", "leysi", "leysinu", "leysis",
            "leysisins", "leysið", "leysna", "leysnanna", "leysu", "leysum", "leysuna", "leysunnar",
            "leysunni", "leysunum", "leysur", "leysurnar", "lægni", "lægnin", "lægnina", "lægninnar",
            "lægninni", "menning", "menninga", "menningana", "menninganna", "menningar", "menningarnir", "menningi",
            "menninginn", "menninginum", "menningnum", "mennings", "menningsins", "menningum", "menningunum", "menningur",
            "menningurinn", "nætta", "nættanna", "nætti", "nættin", "nættinu", "nættis", "nættisins",
            "nættið", "nættum", "nættunum", "ræn", "ræna", "rænan", "rænar", "rænast",
            "rænasta", "rænastan", "rænastar", "rænasti", "rænastir", "rænastra", "rænastrar", "rænastri",
            "rænasts", "rænastur", "ræni", "rænir", "rænn", "rænna", "rænnar", "rænni",
            "ræns", "rænt", "rænu", "rænum", "rænust", "rænustu", "rænustum", "sama",
            "saman", "samar", "samara", "samari", "samast", "samasta", "samastan", "samastar",
            "samasti", "samastir", "samastra", "samastrar", "samastri", "samasts", "samastur", "sami",
            "samir", "samra", "samrar", "samri", "sams", "samt", "samur", "skap",
            "skapar", "skaparins", "skapinn", "skapnum", "skapur", "skapurinn", "stýra", "stýran",
            "stýranna", "stýru", "stýrum", "stýruna", "stýrunnar", "stýrunni", "stýrunum", "stýrur",
            "stýrurnar", "sæi", "sæir", "sæja", "sæjan", "sæjar", "sæjast", "sæjasta",
            "sæjastan", "sæjastar", "sæjasti", "sæjastir", "sæjastra", "sæjastrar", "sæjastri", "sæjasts",
            "sæjastur", "sæju", "sæjum", "sæjust", "sæjustu", "sæjustum", "sær", "særra",
            "særrar", "særri", "sæs", "sætt", "söm", "sömu", "sömum", "sömust",
            "sömustu", "sömustum", "tug", "tuga", "tugan", "tugar", "tugara", "tugari",
            "tugast", "tugasta", "tugastan", "tugastar", "tugasti", "tugastir", "tugastra", "tugastrar",
            "tugastri", "tugasts", "tugastur", "tugi", "tugir", "tugra", "tugrar", "tugri",
            "tugs", "tugt", "tugu", "tugum", "tugur", "tugust", "tugustu", "tugustum",
            "verja", "verjana", "verjann", "verjanna", "verjans", "verjanum", "verjar", "verjarnir",
            "verji", "verjinn", "verjum", "verjunum", "yrki", "yrkinn", "yrkja", "yrkjana",
            "yrkjann", "yrkjanna", "yrkjans", "yrkjanum", "yrkjar", "yrkjarnir", "yrkjum", "yrkjunum",
            "yrða", "yrðanna", "yrði", "yrðin", "yrðinu", "yrðis", "yrðisins", "yrðið",
            "yrðum", "yrðunum", "þega", "þegana", "þegann", "þeganna", "þegans", "þeganum",
            "þegar", "þegarnir", "þegi", "þeginn", "þegum", "þegunum",
        )
    }
}
