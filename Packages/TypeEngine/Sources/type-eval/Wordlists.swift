/// Realistic small wordlists that seed the DictLexicon doubles for the
/// micro-eval. Frequencies are rough Zipf-shaped counts (think "per ~100k
/// tokens"), hand-assembled — good enough to exercise ranking; the real .lex
/// files replace these in the wiring wave.
enum EvalWordlists {

    static let english: [String: UInt32] = [
        // function words / top of Zipf
        "the": 6000, "be": 3500, "to": 3400, "of": 3200, "and": 3000,
        "a": 2800, "in": 2200, "that": 1500, "have": 1300, "it": 1250,
        "for": 1150, "not": 1100, "on": 1000, "with": 950, "he": 900,
        "as": 870, "you": 860, "do": 840, "at": 800, "this": 780,
        "but": 760, "his": 740, "by": 720, "from": 700, "they": 680,
        "we": 660, "say": 640, "her": 620, "she": 600, "or": 580,
        "an": 560, "will": 540, "my": 520, "one": 500, "all": 480,
        "would": 460, "there": 440, "their": 430, "what": 420, "so": 400,
        "up": 380, "out": 360, "if": 340, "about": 320, "who": 300,
        "get": 290, "which": 280, "go": 270, "me": 260, "when": 250,
        "make": 240, "can": 230, "like": 220, "time": 210, "no": 200,
        "just": 195, "him": 190, "know": 185, "take": 180, "people": 175,
        "into": 170, "year": 165, "your": 160, "good": 155, "some": 150,
        "could": 145, "them": 140, "see": 135, "other": 130, "than": 125,
        "then": 120, "now": 118, "look": 116, "only": 114, "come": 112,
        "its": 110, "over": 108, "think": 106, "also": 104, "back": 102,
        "after": 100, "use": 98, "two": 96, "how": 94, "our": 92,
        "work": 90, "first": 88, "well": 86, "way": 84, "even": 82,
        "new": 80, "want": 78, "because": 76, "any": 74, "these": 72,
        "give": 70, "day": 68, "most": 66, "us": 64, "ten": 30,
        "real": 55, "really": 90, "here": 85, "very": 88,
        // targets for the classic-typo pairs
        "address": 42, "receive": 38, "separate": 30, "definitely": 36,
        "occurred": 24, "until": 60, "friend": 55, "believe": 50,
        "calendar": 22, "embarrass": 10, "environment": 34, "government": 58,
        "guard": 26, "happened": 44, "immediately": 32, "knowledge": 36,
        "necessary": 40, "occasion": 20, "publicly": 16, "successful": 30,
        "truly": 24, "basically": 26, "tomorrow": 46, "weird": 28,
        "accommodate": 12, "true": 48, "success": 34, "public": 52,
        // dogfood wave (2026-07-15): "Hmmm ik" = "ok"
        "ok": 210,
        // split-pair halves (space-miss category)
        "is": 2400, "world": 60, "hello": 40,
    ]

    static let englishBigrams: [String: UInt32] = [
        "of the": 600, "in the": 550, "to the": 400, "on the": 300,
        "with the": 250, "and the": 240, "to be": 220, "for the": 200,
        "i think": 60, "thank you": 55, "see you": 40, "good day": 12,
    ]

    static let icelandic: [String: UInt32] = [
        // function words / top of Zipf
        "og": 5800, "að": 5600, "í": 4400, "á": 3800, "er": 3200,
        "sem": 2600, "um": 1900, "en": 1700, "var": 1600, "til": 1500,
        "með": 1400, "ekki": 1350, "það": 1300, "við": 1250, "hann": 1200,
        "hún": 900, "ég": 1100, "þú": 700, "af": 680,
        "fyrir": 660, "svo": 500, "þeir": 380, "þær": 200, "þau": 260,
        "eru": 640, "hafa": 500, "hefur": 480, "verður": 300, "vera": 460,
        "fara": 340, "koma": 320, "sjá": 280, "gera": 360, "segja": 300,
        "þetta": 800, "hér": 240, "þar": 300, "núna": 180, "kannski": 120,
        "mjög": 260, "bara": 400, "líka": 320, "þá": 540, "allt": 340,
        "ekkert": 200, "eitthvað": 190, "gott": 240, "góður": 200,
        "góðan": 160, "gaman": 150, "takk": 220, "já": 480, "nei": 260,
        // content words
        "dagur": 140, "dag": 260, "daginn": 200, "kvöld": 130, "morgun": 110,
        "morgunmatur": 14, "matur": 120, "borða": 90, "hestur": 70,
        "hestar": 30, "hesti": 16, "hest": 24, "hús": 160, "húsið": 90,
        "bíll": 90, "bíllinn": 50, "barn": 130, "börn": 110, "börnin": 60,
        "maður": 300, "menn": 180, "kona": 170, "konur": 90,
        "íslenska": 120, "íslensku": 100, "ísland": 200, "íslandi": 160,
        "skóli": 90, "skólinn": 60, "skóla": 100, "vinna": 150, "vinnu": 120,
        "bók": 110, "bækur": 60, "vatn": 100, "vatnið": 40, "kaffi": 90,
        "mjólk": 60, "brauð": 70, "fiskur": 80, "fisk": 60,
        "veður": 140, "veðrið": 90, "sól": 90, "sólin": 60, "rigning": 50,
        "snjór": 40, "vetur": 90, "sumar": 120, "sumarið": 60, "haust": 50,
        "vor": 40, "ár": 220, "árið": 150, "mánuður": 40, "vika": 60,
        "vikan": 24, "klukkan": 90, "gleði": 40, "göngum": 26, "ganga": 90,
        "strákur": 60, "stelpa": 60, "fjall": 70, "fjöll": 40,
        "fallegur": 70, "falleg": 60, "fallegt": 60, "stór": 110,
        "lítill": 80, "lítið": 130, "nýr": 90, "nýtt": 100, "gamall": 60,
        "sæll": 70, "blessaður": 30, "halló": 60, "heim": 110, "heima": 130,
        "verða": 200, "vel": 240, "fá": 300, "fær": 140, "fékk": 130,
        // dogfood wave (2026-07-15): under-firing repair targets
        "alveg": 260, "nóg": 160, "nógu": 140, "fáránlega": 40,
        "fáránlegur": 30,
        // beam-decoder wave (2026-07-15): spatial2 target (dogfood
        // "koetip" = kortið with e→r and p→ð adjacent-key noise)
        "kortið": 60,
    ]

    static let icelandicBigrams: [String: UInt32] = [
        "að vera": 300, "það er": 500, "er að": 400, "og það": 200,
        "ég er": 260, "er ekki": 240, "góðan dag": 90, "góðan daginn": 60,
        "gott kvöld": 30, "takk fyrir": 130, "í dag": 220, "á morgun": 90,
        "gott veður": 26, "fallegt veður": 12, "borða mat": 8,
        "fara heim": 30, "koma heim": 22,
    ]
}

/// Lane-relaxation eval pack (categories accentlazy / accentguard / apos /
/// aposguard). Seeds a SECOND engine so the original categories stay
/// byte-identical (adding vocabulary changes the calibration sample).
///
/// The Icelandic additions are GENERATED from data/eval/sentences.is.txt —
/// held-out-style: sentences from line 6000 on, first word per sentence
/// with ≥1 long-press acute (á é í ó ú ý), skeleton length ≥ 4, corpus
/// count ≥ 8; unigram counts are the corpus counts /8, (context, word)
/// bigrams get corpus count /40. Generator documented in the fixture
/// header (scripts live with the eval studio; rerun to regenerate).
/// The collision/guard entries (vist/víst, ver/vér, van/ván, fór) and the
/// English contraction pack are hand-authored with realistic RELATIVE
/// counts — notably don't ≫ cant ≈ can't, unlike en.lex v2's
/// apostrophe-stripped corpus noise.
enum AccentWordlists {

    static let icelandic: [String: UInt32] = [
        // generated from sentences.is.txt (see enum doc)
        "af": 116, "aldrei": 4, "bandarísk": 2, "bond": 3,
        "bróðir": 2, "bóka": 2, "bókin": 3, "bókinni": 2,
        "bókum": 2, "connery": 2, "engin": 2, "ensku": 7,
        "er": 243, "frá": 93, "fulltrúi": 2, "fyrsta": 16,
        "fékk": 10, "hafði": 23, "hann": 119, "hans": 33,
        "helsti": 2, "hún": 45, "júní": 20, "kaliforníu": 2,
        "latínu": 2, "mánuði": 2, "móti": 3, "móðir": 3,
        "nóvember": 6, "og": 589, "persónu": 2, "ráða": 2,
        "ráðgjafi": 2, "sem": 274, "sína": 8, "sínar": 2,
        "síðan": 15, "síðar": 13, "sótti": 2, "til": 177,
        "tvisvar": 2, "var": 217, "varð": 32, "yngri": 3,
        "á": 329, "ágúst": 6, "ákvað": 2, "áratug": 2,
        "árið": 86, "ársins": 5, "árunum": 3, "ástralíu": 2,
        "átti": 8, "áður": 21, "í": 520, "ólst": 2,
        "útgáfu": 7, "útskrifaðist": 2, "ýmsum": 3, "þrjár": 2,
        "þrátt": 4, "þótt": 3, "þýðir": 2,
        // hand-authored skeleton collisions (triple-gate + sletta guards):
        // víst/vist at ratio 7.6 (< 10 — dominance fails, offer-only),
        // ver ≫ vér (never restored the wrong way), ván rare vs English
        // "van" (sletta guard), fór (restores past EN-valid "for").
        "vist": 5, "víst": 38, "ver": 30, "vér": 3, "ván": 3, "fór": 380,
    ]

    static let icelandicBigrams: [String: UInt32] = [
        // generated (see enum doc)
        "af bókinni": 2, "aldrei ráða": 2, "bond nóvember": 2,
        "connery ákvað": 2, "engin bóka": 2, "ensku útgáfu": 2,
        "er bandarísk": 2, "frá ágúst": 2, "frá árunum": 2,
        "frá ástralíu": 2, "fyrsta bókin": 2, "hafði þótt": 2,
        "hann sótti": 2, "hans árið": 17, "helsti ráðgjafi": 2,
        "hún útskrifaðist": 2, "nóvember júní": 4, "og fékk": 2,
        "og móðir": 2, "og ýmsum": 2, "sem átti": 2, "sem þýðir": 2,
        "til ársins": 2, "tvisvar áður": 4, "var síðar": 2,
        "varð fulltrúi": 2, "yngri bróðir": 2, "á latínu": 2,
        "á móti": 2, "á áratug": 2, "í bókum": 2, "í kaliforníu": 2,
        // hand-authored guards: bigram support for the SKELETON reading
        // ("í vist") must hold restoration back (context gate).
        "í vist": 4, "ég fór": 12,
    ]

    static let english: [String: UInt32] = [
        // contraction pack (realistic relative counts — see enum doc)
        "don't": 380, "i'm": 260, "can't": 150, "won't": 90,
        "didn't": 80, "isn't": 70, "you're": 90, "i've": 60,
        "that's": 150, "he's": 80, "we'll": 40, "i'll": 55,
        // attested skeletons (dominance-ratio guards) + error-class rival
        "cant": 140, "ill": 90, "font": 300,
        // contexts / cross-language collision halves / the bare pronoun
        // (base list lacks "i" — needed by the lone i→I mirror)
        "why": 300, "said": 200, "van": 900, "i": 2400,
    ]

    static let englishBigrams: [String: UInt32] = [
        "why don't": 25, "said i'm": 8, "i can't": 12, "you didn't": 6,
        "he isn't": 4, "and you're": 5, "i won't": 6, "we didn't": 4,
    ]

    /// Merge the base wordlists with the pack, keeping the LARGER count on
    /// conflicts: the base list's function-word magnitudes (í 4400, og
    /// 5800 …) must survive the pack's corpus-scaled counts or the
    /// single-letter frequency bars stop clearing.
    static func merged(_ base: [String: UInt32], _ pack: [String: UInt32]) -> [String: UInt32] {
        base.merging(pack) { old, new in max(old, new) }
    }
}
