import Foundation
import LemmaCore

// Productive compound acceptance (wave 22 — PLAN.md "Compounds", the
// dogfood "stökklrikanum" → "stökkleikanum" class).
//
// Icelandic compounding is productive and unbounded: speakers freely form
// compounds ("stökkleikanum" = stökk + leikanum) that no lexicon can
// enumerate — BÍN's 3.07M forms notwithstanding. This module ports the
// RULES of Miðeind's compound analyzer (BinPackage
// `src/islenska/dawgdictionary.py` `Wordbase.slice_compound_word_candidates`
// + `bindb.py` `_compound_meanings`, the algorithm GreynirEngine's bindb.py
// wraps) onto the artifacts this engine already ships:
//
//  * A compound is modifier(+modifier)* + head, where the HEAD carries the
//    whole word's inflection ("leikanum" dative definite validates
//    "stökkleikanum") and must belong to an OPEN word class — Miðeind's
//    `_OPEN_CATS` restriction (noun/verb/adjective; their suffix DAWG
//    contains no adverbs or function words, "mjög"/"yfir" are not legal
//    heads).
//  * A MODIFIER must be a linking form: Miðeind's prefix DAWG
//    (`ordalisti-prefixes`, 524k forms) is, empirically, noun GENITIVES
//    (indefinite, any number — the -s-/-ar-/-a-/-u- "bandstafir" ARE the
//    genitive endings, so no separate linking-letter machinery is needed),
//    noun STEMS (masc. þf.et, fem. nf.et, neut. nf/þf.et — "stökk", "eld",
//    "bók"), and strong-positive adjective genitives ("sjúkra" →
//    sjúkrahús). Verified against their shipped list: nominatives like
//    "hestur", datives, and every definite (article-suffixed) form are
//    excluded. We evaluate this rule against paradigms.bin, whose bundles
//    carry the DEFINITENESS bit that lemma-is.bin v2 morph lacks
//    (rule precision vs. Miðeind's list collapses 0.83 → 0.43 without it)
//    and whose lemma-frequency floor (≥ 10) mirrors the effect of
//    Miðeind's curation (proper-name stems and rare junk drop out).
//  * Multi-part compounds: every non-final part must be a legal modifier
//    (their DAWG combination rule). The modifier-chain depth is
//    `config.compoundMaxModifiers` (default 2, e.g. skaða+bóta+reglan —
//    wave 22's deliberate ceiling, kept after the wave-31 measurement:
//    real 4-part compounds exist (gervigreindar+gagna+verin,
//    álfa+brunn+fugla+garðurinn) but see the wave-31 WAVES.md entry for
//    the numbers behind keeping the default at 2).
//  * Ranking: longest head first, then fewest parts — Miðeind's
//    "longest last part, fewest total parts" sort, expressed by scanning
//    split points left to right and preferring the 1-modifier reading.
//  * BOUND suffix forms: BÍN ships `ord.suffix.csv` — inflection templates
//    for word-final elements that are NOT standalone words ("-leikanum",
//    "-menningur", "-yrði"; birting='S' in BinPackage). lemma-is.bin does
//    not carry them, so the distinct surface forms (≥ 3 chars, 358 of
//    them) are embedded below. This is exactly why "stökkleikanum" is
//    decomposable at all: "leikanum" exists only as a compound head.
//
// Deliberate deviations from Miðeind (each tightens, except the last):
//  * Minimum part lengths 4/4 (config) vs. their implicit 2: an OOV
//    3-char-part compound is rare (short compounds are IN BÍN), and the
//    dev-corpus sweep showed 3/3 protecting 2.7% of typo rows vs 1.2% at
//    4/4 with zero loss on the real-compound positives.
//  * No adjective STEMS as modifiers (only adjective genitives):
//    "frá"(frár)/"villt" stems protected space-miss typos on dev.
//  * `suffix-removals.txt` (their empirical bad-head list: forms whose
//    every reading is archaic/poetic) is NOT ported — lemma-is.bin carries
//    no register marks. Compound validity feeds only the autocorrect VETO
//    and candidate generation, never auto-apply, so the cost of a bad
//    head is a weaker correction, not a wrong one.
//  * Their defective-paradigm (tantum) demotion picks the best ANALYSIS;
//    we only need existence, so it is skipped.
//
// License note: the bound-suffix form list below derives from BÍN
// (Stofnun Árna Magnússonar, CC BY-SA 4.0) via BinPackage's
// resources/ord.suffixes.csv — same source and license as lemma-is.bin.

/// One legal decomposition of an out-of-vocabulary word.
struct CompoundSplit: Equatable {
    /// Non-final parts, in order (1 or 2 of them this wave).
    let modifiers: [String]
    /// The final part — carries the compound's inflection.
    let head: String
}

/// Decomposition engine + per-token memo caches. A reference type shared
/// across the `BlendedLanguageModel` copies (same pattern as
/// `PersonalStore`/`InflectionStore`); confined to the engine's owning
/// queue like every other engine-internal store.
final class CompoundAnalyzer {

    // MARK: - Memo caches (hot path: validity runs per keystroke boundary)

    /// word → split (nil = analyzed, no legal split). Bounded.
    private var splitCache: [String: CompoundSplit?] = [:]
    private var modifierCache: [String: Bool] = [:]
    private var headCache: [String: Bool] = [:]
    private let cacheLimit = 4096

    /// Drop everything (inflection-model swap).
    func clearCache() {
        splitCache.removeAll(keepingCapacity: true)
        modifierCache.removeAll(keepingCapacity: true)
        headCache.removeAll(keepingCapacity: true)
    }

    private func bound<K, V>(_ cache: inout [K: V]) {
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
    }

    // MARK: - Decomposition

    /// The best legal decomposition of `word` (longest head, fewest parts),
    /// or nil. `word` is expected in pipeline form (lowercased); non-letter
    /// characters disqualify. Callers gate on the word being OOV — this
    /// function does not re-check.
    func split(
        of word: String,
        morphology: MorphologyProviding,
        paradigms: ParadigmsProviding,
        config: EngineConfig
    ) -> CompoundSplit? {
        let minModifier = config.compoundMinModifierLength
        let minHead = config.compoundMinHeadLength
        let chars = Array(word)
        let n = chars.count
        guard n >= minModifier + minHead, n <= config.compoundMaxWordLength,
            chars.allSatisfy(\.isLetter)
        else { return nil }
        // Never-a-compound deny set (wave 31 — Miðeind's negative
        // curation): a morphologically-legal-looking join that standard
        // orthography ALWAYS writes as separate words gains no compound
        // reading, whatever the modifier/head rules say.
        if Self.neverCompounds[word] != nil { return nil }
        if let cached = splitCache[word] { return cached }
        var result: CompoundSplit?
        // Longest head first (split point left to right); at each point
        // prefer the fewest-modifier reading (Miðeind's "longest last
        // part, fewest total parts" order). Modifier-chain depth is
        // config.compoundMaxModifiers (wave 22 shipped exactly 2; wave 31
        // generalized the scan behind the knob, default unchanged).
        outer: for i in minModifier...(n - minHead) {
            let head = String(chars[i...])
            guard isHead(head, morphology: morphology, minLength: minHead) else { continue }
            let maxParts = max(1, config.compoundMaxModifiers)
            for parts in 1...maxParts where i >= parts * minModifier {
                if let modifiers = segmentModifiers(
                    chars[..<i], into: parts, paradigms: paradigms, minLength: minModifier)
                {
                    result = CompoundSplit(modifiers: modifiers, head: head)
                    break outer
                }
            }
        }
        bound(&splitCache)
        splitCache[word] = result
        return result
    }

    /// Segment `region` into exactly `parts` legal modifiers (each ≥
    /// `minLength`), scanning earlier split points first — for parts == 2
    /// this reproduces wave 22's shortest-first-part order byte for byte.
    /// Returns the parts in order, or nil when no legal segmentation
    /// exists.
    private func segmentModifiers(
        _ region: ArraySlice<Character>, into parts: Int,
        paradigms: ParadigmsProviding, minLength: Int
    ) -> [String]? {
        if parts == 1 {
            let word = String(region)
            return isModifier(word, paradigms: paradigms, minLength: minLength) ? [word] : nil
        }
        let lower = region.startIndex + minLength
        let upper = region.endIndex - (parts - 1) * minLength
        guard lower <= upper else { return nil }
        for j in lower...upper {
            let first = String(region[..<j])
            guard isModifier(first, paradigms: paradigms, minLength: minLength) else { continue }
            if let rest = segmentModifiers(
                region[j...], into: parts - 1, paradigms: paradigms, minLength: minLength)
            {
                return [first] + rest
            }
        }
        return nil
    }

    /// Legal compound HEAD: an open-class (noun/verb/adjective) BÍN form,
    /// or a bound suffix form from ord.suffix.csv. Memoized.
    func isHead(
        _ part: String, morphology: MorphologyProviding, minLength: Int
    ) -> Bool {
        guard part.count >= minLength else { return false }
        if let cached = headCache[part] { return cached }
        let legal =
            Self.boundHeadForms.contains(part)
            || morphology.hasOpenClassAnalysis(part)
        bound(&headCache)
        headCache[part] = legal
        return legal
    }

    /// Legal compound MODIFIER (linking form) per the paradigms.bin bundle
    /// rule documented above. Memoized.
    func isModifier(
        _ part: String, paradigms: ParadigmsProviding, minLength: Int
    ) -> Bool {
        guard part.count >= minLength else { return false }
        if let cached = modifierCache[part] { return cached }
        var legal = false
        for analysis in paradigms.analyses(ofForm: part) {
            let bundle = analysis.bundle
            switch analysis.pos {
            case .noun:
                // Definite (article-suffixed) forms never link
                // ("hestsins", "ömmunnar" are not modifiers).
                guard !bundle.isDefinite else { continue }
                if bundle.caseCode == 3 {  // genitive, either number
                    legal = true
                } else if !bundle.isPlural {
                    // Stem slots: masc þf.et / fem nf.et / neut nf|þf.et.
                    switch analysis.genderCode {
                    case 0: legal = bundle.caseCode == 1
                    case 1: legal = bundle.caseCode == 0
                    case 2: legal = bundle.caseCode == 0 || bundle.caseCode == 1
                    default: break
                    }
                }
            case .adjective:
                // Strong positive genitive only ("sjúkra-", "veikra-");
                // adjective stems deliberately excluded (see header).
                if bundle.adjectiveDegreeCode == 0, !bundle.adjectiveIsWeak,
                    bundle.caseCode == 3
                {
                    legal = true
                }
            }
            if legal { break }
        }
        bound(&modifierCache)
        modifierCache[part] = legal
        return legal
    }

    // MARK: - Never-a-compound deny set (wave 31)

    /// Wrongly-JOINED pseudo-compounds → their canonical split form.
    /// Miðeind curates against these beyond pure morphological legality:
    /// each LOOKS like a legal genitive-modifier+head join (margs+konar,
    /// mikils+háttar) — the exact shape `isModifier`/`isHead` accept —
    /// but standard Icelandic orthography always writes them as separate
    /// words (GreynirCorrect error class C002, `test_wrong_compounds`;
    /// harvested in research/mideind-compound-cases.jsonl, MIT).
    ///
    /// Two duties:
    ///  * `split(of:)` refuses them — they must never earn compound
    ///    validity protection. (Mostly a structural guard today: BÍN's
    ///    descriptive coverage actually ATTESTS 8 of the 10 as whole
    ///    surface forms — margskonar carries a full indeclinable-
    ///    adjective paradigm — so lexicon validity, not compound
    ///    analysis, is what protects them from auto-replace. The
    ///    conservatism invariant stands; the deny set keeps the compound
    ///    layer from ever ADDING protection, e.g. for inflected or
    ///    future variants BÍN does not carry.)
    ///  * The corrector OFFERS the canonical split form in the bar
    ///    (offer-only, wrong-form-offer semantics): one tap writes the
    ///    standard orthography. The two forms BÍN does NOT attest
    ///    (fjögurhundruð, níuhundruð) already auto-split via the
    ///    ordinary space-miss machinery — the offer path only ever runs
    ///    for words the validity veto silences.
    static let neverCompounds: [String: String] = [
        "margskonar": "margs konar",
        "afturábak": "aftur á bak",
        "afþvíað": "af því að",
        "annarstaðar": "annars staðar",
        "fjögurhundruð": "fjögur hundruð",
        "mikilsháttar": "mikils háttar",
        "niðrá": "niður á",
        "níuhundruð": "níu hundruð",
        "samskonar": "sams konar",
        "seinnihluta": "seinni hluta",
    ]

    // MARK: - Bound suffix forms (BÍN ord.suffix.csv via BinPackage)

    /// Distinct surface forms (≥ 3 chars) of BÍN's 26 bound-suffix
    /// paradigms (-beri, -buri, -fari, -freyja, -fygli, -gjafi, -gresi,
    /// -hafi, -ingur, -isti, -leiki, -leysa, -leysi, -lægni, -menningur,
    /// -nætti, -rænn, -samur, -skapur, -stýra, -sær, -tugur, -verji,
    /// -yrki, -yrði, -þegi). These exist ONLY as compound heads — BÍN
    /// marks them utg=-1 ("þekkjast ekki sem sjálfstæð orð") and
    /// lemma-is.bin omits them.
    static let boundHeadForms: Set<String> = [
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
    ]
}
