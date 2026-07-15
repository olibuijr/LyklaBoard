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

    /// λ: weight of log P_lang relative to log P_spatial in the corrector
    /// score. 1.0 = classic noisy channel.
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

    /// Cost per not-yet-typed character when a candidate is a strict-prefix
    /// completion of the typed word (completion-as-suggestion).
    public var completionCharCost: Double = 0.5
    /// How many prefix completions to pull from each lexicon while correcting.
    public var completionPoolLimit: Int = 8
    /// How many top unigrams per lexicon feed next-word prediction.
    public var unigramPoolLimit: Int = 50

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
    /// Hard cap on edit2 expansions (protects the extension's CPU budget).
    public var maxEdits2Expansions: Int = 500_000

    /// EMA step for the language posterior update per confirmed word.
    public var posteriorAlpha: Double = 0.25
    /// The posterior never saturates past 90/10 in either direction.
    public var posteriorFloor: Double = 0.1
    public var posteriorCeiling: Double = 0.9

    public init() {}
}

enum Language {
    case icelandic
    case english
}

/// Shared bilingual probability model: smoothed unigram + interpolated bigram
/// probabilities per language, blended by the running language posterior.
struct BlendedLanguageModel {
    let icelandic: Lexicon
    let english: Lexicon
    let morphology: MorphologyProviding?
    let config: EngineConfig

    func lexicon(for language: Language) -> Lexicon {
        language == .icelandic ? icelandic : english
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

    /// Add-k smoothed unigram probability.
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

    /// P(word | context) blended across languages by the posterior:
    /// P(w|IS)·P(IS) + P(w|EN)·P(EN).
    func blendedProbability(of word: String, previous: String?, pIcelandic: Double) -> Double {
        let pIS = contextualProbability(of: word, previous: previous, language: .icelandic)
        let pEN = contextualProbability(of: word, previous: previous, language: .english)
        return pIcelandic * pIS + (1 - pIcelandic) * pEN
    }
}
