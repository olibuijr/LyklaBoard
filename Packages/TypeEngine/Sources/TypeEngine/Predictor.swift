import Foundation
import Lexicon

/// Next-word and mid-word prediction from bigram tables of both lexicons,
/// blended by the language posterior, with unigram fallback.
///
/// NOTE on candidate pooling: the Lexicon protocol only supports point
/// lookups of bigram frequencies (no "followers of word" enumeration), so
/// next-word candidates are the top unigrams of each lexicon
/// (`completions(of: "", ...)`) re-ranked by bigram context. When no bigram
/// context matches, this degrades exactly to top-unigram fallback. Flagged
/// for the wiring wave: a `continuations(of:limit:)` API on the real Lexicon
/// would let true bigram followers surface even when they are rare unigrams.
public struct Predictor {
    let model: BlendedLanguageModel
    let config: EngineConfig

    public init(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: MorphologyProviding? = nil,
        config: EngineConfig = EngineConfig()
    ) {
        self.config = config
        self.model = BlendedLanguageModel(
            icelandic: icelandic,
            english: english,
            morphology: morphology,
            config: config
        )
    }

    init(model: BlendedLanguageModel, config: EngineConfig) {
        self.config = config
        self.model = model
    }

    /// Next-word suggestions after `previousWord` (nil at sentence start).
    public func nextWords(
        previousWord: String?,
        pIcelandic: Double = 0.5,
        limit: Int = 3
    ) -> [Suggestion] {
        guard limit > 0 else { return [] }
        var pool = Set<String>()
        for lexicon in [model.icelandic, model.english] {
            for entry in lexicon.completions(of: "", limit: config.unigramPoolLimit) {
                pool.insert(entry.word)
            }
        }
        return rank(pool: pool, previousWord: previousWord, pIcelandic: pIcelandic, limit: limit)
    }

    /// Mid-word: completions of the current prefix, re-ranked by bigram
    /// context with the previous word.
    public func completions(
        of prefix: String,
        previousWord: String?,
        pIcelandic: Double = 0.5,
        limit: Int = 3
    ) -> [Suggestion] {
        guard limit > 0, !prefix.isEmpty else {
            return nextWords(previousWord: previousWord, pIcelandic: pIcelandic, limit: limit)
        }
        let lowered = prefix.lowercased()
        var pool = Set<String>()
        for lexicon in [model.icelandic, model.english] {
            for entry in lexicon.completions(of: lowered, limit: config.unigramPoolLimit) {
                pool.insert(entry.word)
            }
        }
        return rank(pool: pool, previousWord: previousWord, pIcelandic: pIcelandic, limit: limit)
    }

    private func rank(
        pool: Set<String>,
        previousWord: String?,
        pIcelandic: Double,
        limit: Int
    ) -> [Suggestion] {
        var scored: [(word: String, score: Double)] = pool.map { word in
            let p = model.blendedProbability(of: word, previous: previousWord, pIcelandic: pIcelandic)
            return (word, log(p))
        }
        scored.sort { $0.score > $1.score || ($0.score == $1.score && $0.word < $1.word) }

        let confidencePool = scored.prefix(8)
        let maxScore = confidencePool.first?.score ?? 0
        let z = confidencePool.reduce(0.0) { $0 + exp($1.score - maxScore) }

        return scored.prefix(limit).map { entry in
            Suggestion(
                text: entry.word,
                isAutocorrect: false,  // predictions never auto-replace
                confidence: z > 0 ? exp(entry.score - maxScore) / z : 0
            )
        }
    }
}
