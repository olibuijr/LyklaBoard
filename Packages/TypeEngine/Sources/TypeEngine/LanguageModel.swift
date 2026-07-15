import Foundation
import Lexicon

/// Anything that can validate word forms morphologically (BÍN via LemmaCore's
/// BinaryLemmatizer in production; a fake in tests).
public protocol MorphologyProviding: AnyObject {
    func isKnown(_ word: String) -> Bool
}

/// All engine tunables in one place. Defaults documented inline; every value
/// is expected to move once the micro-eval corpus grows.
public struct EngineConfig: Sendable {
    /// Spatial model constants (see SpatialModel.Costs).
    public var spatialCosts = SpatialModel.Costs()

    /// λ: weight of the language score relative to log P_spatial in the
    /// corrector score. 1.0 = classic noisy channel.
    public var languageWeight: Double = 1.0

    /// Add-k smoothing constant for unigram probabilities.
    public var addK: Double = 0.5
    /// Assumed vocabulary size V for add-k smoothing (P = (f+k)/(N+kV)).
    public var assumedVocabularySize: Double = 100_000
    /// Frequency assigned to a word that is BÍN-valid (isKnown) but missing
    /// from the Icelandic frequency table. Rare inflected forms should be
    /// suggestible but never outrank attested words.
    public var binFloorFrequency: UInt32 = 2

    /// β: weight of the bigram MLE vs the unigram probability when a previous
    /// word is available: P(w|prev) = β·(bf/f_prev) + (1-β)·P_uni(w).
    public var bigramInterpolation: Double = 0.6

    /// τ: temperature of the cross-language calibration, in nats per
    /// within-lexicon standard deviation. Each lexicon's log-probabilities
    /// are z-scored against that lexicon's own log-frequency distribution
    /// before blending, so differently-scaled corpora become comparable
    /// (see LexiconCalibration); τ converts those σ-units back into nats.
    public var calibrationTemperature: Double = 1.0

    /// Cost per not-yet-typed character when a candidate is a strict-prefix
    /// completion of the typed word (completion-as-suggestion).
    public var completionCharCost: Double = 0.5
    /// How many prefix completions to pull from each lexicon while correcting.
    public var completionPoolLimit: Int = 8
    /// How many top unigrams per lexicon feed next-word prediction fallback.
    public var unigramPoolLimit: Int = 50
    /// How many bigram continuations per lexicon feed next-word prediction.
    public var continuationPoolLimit: Int = 24

    /// Auto-replace only fires when the top candidate beats the runner-up by
    /// this many nats (conservatism: under-correct rather than over-correct).
    public var autocorrectMargin: Double = 1.25
    /// Auto-replace never fires when the top candidate's spatial cost exceeds
    /// this (wild rewrites are suggestion-bar-only).
    public var autocorrectMaxSpatialCost: Double = 6.0
    /// Never auto-replace very short inputs.
    public var minAutocorrectLength: Int = 3

    /// Edits-distance-2 candidates are generated only when the typed word has
    /// at least 5 characters AND the best edits1 candidate's spatial cost is
    /// above this gate (i.e. no good close hit exists).
    public var edits2Gate: Double = 4.5
    /// edits2 is skipped entirely for typed words longer than this (the
    /// expansion count grows quadratically with length and long words are
    /// served well enough by edits1 + completions).
    public var edits2MaxLength: Int = 16
    /// Hard cap on edits2 expansions (protects the extension's CPU budget;
    /// on the real mmap-ed artifacts the wall-clock budget below binds long
    /// before this does — the cap mainly bounds fast in-memory lexicons).
    public var maxEdits2Expansions: Int = 120_000
    /// Wall-clock budget for the edits2 expansion walk, in seconds. When it
    /// runs out the corrector falls back to whatever edits1/completion
    /// candidates it already has (worst-case latency gate; see PLAN.md
    /// "edits2 latency landmine").
    public var edits2TimeBudget: TimeInterval = 0.008

    /// EMA step for the language posterior update per confirmed word.
    public var posteriorAlpha: Double = 0.25
    /// The posterior never saturates past 90/10 in either direction.
    public var posteriorFloor: Double = 0.1
    public var posteriorCeiling: Double = 0.9
    /// A committed word known in exactly one lexicon only moves the posterior
    /// when its calibrated z-score there is at least this (junk/noise-tier
    /// entries — web scrapings, typos baked into the corpus — are not
    /// language evidence). BÍN-valid words bypass the floor for Icelandic.
    public var posteriorAttributionFloor: Double = -1.25
    /// A committed word known in both lexicons only moves the posterior when
    /// its calibrated z-scores differ by at least this many σ.
    public var posteriorAttributionMargin: Double = 1.0

    public init() {}
}

enum Language {
    case icelandic
    case english
}

/// Per-lexicon frequency-distribution statistics used to calibrate
/// cross-language comparisons.
///
/// Raw probabilities (f / totalTokens) from differently built corpora are
/// apples-to-oranges: a mid-tier Icelandic noun and a mid-tier English noun
/// can differ by several nats purely because of corpus size, scaling and
/// noise-floor differences (the PLAN.md "hus → his even at P(IS)=0.79"
/// finding). What autocorrect actually needs is *within-language
/// typicality*: how notable is this word inside its own language. So each
/// lexicon's log-frequencies are z-scored against that lexicon's own
/// distribution before blending across languages.
///
/// The distribution is estimated deterministically at engine init by
/// sampling the head of many two-letter prefix buckets via
/// `completions(of:limit:)` (the only enumeration the Lexicon protocol
/// offers). The sample is head-biased in the same way for both lexicons, so
/// the resulting z-scores stay comparable. Sampling also doubles as a page
/// warm-up of the mmap-ed unigram sections.
struct LexiconCalibration: Sendable {
    /// Mean of log(f + addK) over the sample.
    let meanLogFrequency: Double
    /// Standard deviation of log(f + addK) over the sample (≥ minSigma).
    let stdLogFrequency: Double
    /// A spread of sampled words, retained for `warmUp()` page touching.
    let sampleWords: [String]

    /// σ floor: degenerate distributions (tiny test dictionaries with a
    /// handful of equal frequencies) fall back to unit variance instead of
    /// exploding the z-scores.
    private static let minSigma = 0.25

    /// First letters of the sampled two-letter buckets (full engine
    /// alphabet, minus apostrophes).
    private static let bucketFirst: [Character] = Array("aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö")
    /// Second letters — a spread of common vowels/consonants (plus accents
    /// and Icelandic letters) chosen to cover most head words without
    /// scanning every two-letter range of a 300k-word table.
    private static let bucketSecond: [Character] = Array("aáeéiíoóuúyýhnrstlðgkm")
    private static let bucketLimit = 12

    static func measure(_ lexicon: Lexicon, addK: Double) -> LexiconCalibration {
        var logs: [Double] = []
        var words: [String] = []
        logs.reserveCapacity(4096)
        for first in bucketFirst {
            for second in bucketSecond {
                let prefix = String([first, second])
                for entry in lexicon.completions(of: prefix, limit: bucketLimit) {
                    logs.append(log(Double(entry.frequency) + addK))
                    if words.count < 512 { words.append(entry.word) }
                }
            }
        }
        guard logs.count >= 4 else {
            // Effectively empty lexicon (bare test doubles): identity
            // calibration keeps z = log(f + k), which is monotone and
            // harmless when there is nothing to compare against.
            return LexiconCalibration(meanLogFrequency: 0, stdLogFrequency: 1, sampleWords: words)
        }
        let mean = logs.reduce(0, +) / Double(logs.count)
        let variance = logs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(logs.count)
        let sigma = max(sqrt(variance), minSigma)
        return LexiconCalibration(meanLogFrequency: mean, stdLogFrequency: sigma, sampleWords: words)
    }
}

/// Shared bilingual probability model: smoothed unigram + interpolated bigram
/// probabilities per language, calibrated per lexicon and blended by the
/// running language posterior.
struct BlendedLanguageModel {
    let icelandic: Lexicon
    let english: Lexicon
    let morphology: MorphologyProviding?
    let config: EngineConfig
    let icelandicCalibration: LexiconCalibration
    let englishCalibration: LexiconCalibration

    init(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: MorphologyProviding?,
        config: EngineConfig
    ) {
        self.icelandic = icelandic
        self.english = english
        self.morphology = morphology
        self.config = config
        self.icelandicCalibration = LexiconCalibration.measure(icelandic, addK: config.addK)
        self.englishCalibration = LexiconCalibration.measure(english, addK: config.addK)
    }

    func lexicon(for language: Language) -> Lexicon {
        language == .icelandic ? icelandic : english
    }

    func calibration(for language: Language) -> LexiconCalibration {
        language == .icelandic ? icelandicCalibration : englishCalibration
    }

    /// Is the word attested anywhere (either frequency table, or BÍN-valid)?
    func isKnownAnywhere(_ word: String) -> Bool {
        icelandic.frequency(of: word) != nil
            || english.frequency(of: word) != nil
            || morphology?.isKnown(word) == true
    }

    /// Effective unigram frequency, applying the BÍN floor for Icelandic
    /// forms that are morphologically valid but absent from the table.
    func effectiveFrequency(of word: String, language: Language) -> UInt32? {
        if let f = lexicon(for: language).frequency(of: word) { return f }
        if language == .icelandic, morphology?.isKnown(word) == true {
            return config.binFloorFrequency
        }
        return nil
    }

    /// Add-k smoothed unigram probability (uncalibrated, within-language).
    func unigramProbability(of word: String, language: Language) -> Double {
        let f = Double(effectiveFrequency(of: word, language: language) ?? 0)
        let total = Double(lexicon(for: language).totalUnigramTokens)
        let k = config.addK
        return (f + k) / (total + k * config.assumedVocabularySize)
    }

    /// P(word | previous) with bigram/unigram interpolation. Falls back to
    /// the pure unigram probability when there is no usable context.
    func contextualProbability(of word: String, previous: String?, language: Language) -> Double {
        let uni = unigramProbability(of: word, language: language)
        guard
            let previous,
            let prevFreq = lexicon(for: language).frequency(of: previous),
            prevFreq > 0
        else { return uni }
        let bigram = Double(lexicon(for: language).bigramFrequency(previous, word) ?? 0)
        let mle = bigram / Double(prevFreq)
        let beta = config.bigramInterpolation
        return beta * mle + (1 - beta) * uni
    }

    /// The lexicon's reference log-probability: what a word at the sampled
    /// mean log-frequency of language L would score as a smoothed unigram.
    private func referenceLogProbability(language: Language) -> Double {
        let cal = calibration(for: language)
        let total = Double(lexicon(for: language).totalUnigramTokens)
        return cal.meanLogFrequency - log(total + config.addK * config.assumedVocabularySize)
    }

    /// Calibrated contextual score: the word's log P(word | previous, L)
    /// z-scored against lexicon L's own log-frequency distribution.
    /// Affine in log-probability with positive slope, so ranking *within* a
    /// language is unchanged; only cross-language comparisons move.
    func calibratedScore(of word: String, previous: String?, language: Language) -> Double {
        let p = contextualProbability(of: word, previous: previous, language: language)
        let cal = calibration(for: language)
        return (log(p) - referenceLogProbability(language: language)) / cal.stdLogFrequency
    }

    /// Calibrated unigram-only score (no bigram context); used for posterior
    /// attribution of committed words.
    func calibratedUnigramScore(of word: String, language: Language) -> Double {
        calibratedScore(of: word, previous: nil, language: language)
    }

    /// Blended language score, in nats:
    /// log( P(IS)·exp(τ·z_IS) + P(EN)·exp(τ·z_EN) ).
    /// Replaces the raw probability blend — see LexiconCalibration.
    func blendedScore(of word: String, previous: String?, pIcelandic: Double) -> Double {
        let p = min(max(pIcelandic, 1e-6), 1 - 1e-6)
        let tau = config.calibrationTemperature
        let a = log(p) + tau * calibratedScore(of: word, previous: previous, language: .icelandic)
        let b = log(1 - p) + tau * calibratedScore(of: word, previous: previous, language: .english)
        let m = max(a, b)
        return m + log(exp(a - m) + exp(b - m))
    }

    /// Touch representative pages of both lexicons and the morphology binary
    /// so the first real keystrokes don't pay mmap page-fault costs
    /// (PLAN.md "cold-start page faults"). The calibration sampling at init
    /// already walks the unigram sections; this adds point lookups, the
    /// bigram tables and BÍN probes. Idempotent, a few ms warm.
    func warmUp() {
        for (lexicon, cal) in [(icelandic, icelandicCalibration), (english, englishCalibration)] {
            var previous: String?
            for (index, word) in cal.sampleWords.enumerated() {
                _ = lexicon.frequency(of: word)
                if let previous {
                    _ = lexicon.bigramFrequency(previous, word)
                }
                if index % 8 == 0 {
                    _ = lexicon.continuations(of: word, limit: 2)
                }
                previous = word
            }
        }
        if let morphology {
            for word in icelandicCalibration.sampleWords {
                _ = morphology.isKnown(word)
            }
            // Spread probes across the whole key space: every two-letter
            // combination walks a distinct binary-search path through the
            // (large) morphology binary, faulting in the upper index levels
            // that every future lookup shares.
            let alphabet = Array("aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö")
            for first in alphabet {
                for second in alphabet {
                    _ = morphology.isKnown(String([first, second]))
                }
            }
        }
    }
}
