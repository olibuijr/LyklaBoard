import Foundation
import Lexicon

/// One ranked suggestion.
public struct Suggestion: Equatable, Sendable {
    public let text: String
    /// True only on the top candidate, and only when the conservatism rules
    /// allow auto-replacement (typed word unknown everywhere + confidence
    /// margin met). A valid typed word NEVER yields isAutocorrect = true.
    public let isAutocorrect: Bool
    /// Softmax posterior over the scored candidate pool, in (0, 1].
    public let confidence: Double

    public init(text: String, isAutocorrect: Bool, confidence: Double) {
        self.text = text
        self.isAutocorrect = isAutocorrect
        self.confidence = confidence
    }
}

/// Result of correcting a single typed word.
public struct CorrectionResult {
    public let suggestions: [Suggestion]
    /// True when the typed word exists in either lexicon or is BÍN-valid.
    /// When true, suggestions are alternatives only (never autocorrect).
    public let typedWordIsValid: Bool
}

/// Noisy-channel corrector: spatial likelihood × blended language prior.
public struct Corrector {
    /// Candidate-generation alphabet: base latin + Icelandic letters +
    /// long-press accents.
    static let alphabet: [Character] = Array("aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö")

    let spatial: SpatialModel
    let model: BlendedLanguageModel
    let config: EngineConfig

    public init(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: MorphologyProviding? = nil,
        config: EngineConfig = EngineConfig()
    ) {
        self.config = config
        self.spatial = SpatialModel(costs: config.spatialCosts)
        self.model = BlendedLanguageModel(
            icelandic: icelandic,
            english: english,
            morphology: morphology,
            config: config
        )
    }

    init(model: BlendedLanguageModel, config: EngineConfig) {
        self.config = config
        self.spatial = SpatialModel(costs: config.spatialCosts)
        self.model = model
    }

    /// Ranked correction candidates for `typed` (assumed a single word).
    ///
    /// - Parameters:
    ///   - typed: the word as typed (will be lowercased internally)
    ///   - previousWord: last committed word, for bigram context (lowercased)
    ///   - pIcelandic: current language posterior P(IS)
    ///   - limit: max suggestions returned
    public func correct(
        typed rawTyped: String,
        previousWord: String? = nil,
        pIcelandic: Double = 0.5,
        limit: Int = 3
    ) -> CorrectionResult {
        let typed = rawTyped.lowercased()
        let typedChars = Array(typed)
        guard !typedChars.isEmpty, limit > 0 else {
            return CorrectionResult(suggestions: [], typedWordIsValid: false)
        }

        let typedIsValid = model.isKnownAnywhere(typed)

        // ---- Candidate generation ----------------------------------------
        // word -> spatial cost
        var candidates: [String: Double] = [:]

        func admit(_ word: String) {
            guard word != typed, candidates[word] == nil else { return }
            candidates[word] = spatialCost(typedChars: typedChars, candidate: word)
        }

        // 1. edits1, existence-checked against lexicons + BÍN.
        let e1 = Self.edits1(of: typedChars)
        for word in e1 where isCandidateWord(word, checkMorphology: true) {
            admit(word)
        }

        // 2. Prefix completions of the typed word (completion-as-suggestion).
        for lexicon in [model.icelandic, model.english] {
            for completion in lexicon.completions(of: typed, limit: config.completionPoolLimit) {
                admit(completion.word)
            }
        }

        // 3. edits2, only for words of length >= 5 with no good edits1 hit.
        // Existence check skips BÍN here: a full morphology probe per edits2
        // expansion is too expensive (~100µs each on the mmap-ed binary).
        let bestSoFar = candidates.values.min() ?? .infinity
        if typedChars.count >= 5, bestSoFar > config.edits2Gate {
            var expansions = 0
            outer: for base in e1 {
                for word in Self.edits1(of: Array(base)) {
                    expansions += 1
                    if expansions > config.maxEdits2Expansions { break outer }
                    if word != typed, candidates[word] == nil,
                        isCandidateWord(word, checkMorphology: false)
                    {
                        admit(word)
                    }
                }
            }
        }

        // ---- Scoring ------------------------------------------------------
        // score = -spatialCost + λ·log P_lang(candidate | context, posterior)
        var scored: [(word: String, spatialCost: Double, score: Double)] = candidates.map {
            word, cost in
            let p = model.blendedProbability(of: word, previous: previousWord, pIcelandic: pIcelandic)
            return (word, cost, -cost + config.languageWeight * log(p))
        }
        scored.sort { $0.score > $1.score || ($0.score == $1.score && $0.word < $1.word) }

        // ---- Conservatism / autocorrect decision --------------------------
        var autocorrect = false
        if !typedIsValid,
            let best = scored.first,
            typedChars.count >= config.minAutocorrectLength,
            best.spatialCost <= config.autocorrectMaxSpatialCost
        {
            let margin = scored.count > 1 ? best.score - scored[1].score : .infinity
            autocorrect = margin >= config.autocorrectMargin
        }

        // ---- Confidence: softmax over the top of the candidate pool -------
        let confidencePool = scored.prefix(8)
        let maxScore = confidencePool.first?.score ?? 0
        let z = confidencePool.reduce(0.0) { $0 + exp($1.score - maxScore) }

        let suggestions = scored.prefix(limit).enumerated().map { index, entry in
            Suggestion(
                text: entry.word,
                isAutocorrect: index == 0 && autocorrect,
                confidence: z > 0 ? exp(entry.score - maxScore) / z : 0
            )
        }
        return CorrectionResult(suggestions: Array(suggestions), typedWordIsValid: typedIsValid)
    }

    // MARK: - Internals

    private func isCandidateWord(_ word: String, checkMorphology: Bool) -> Bool {
        if model.icelandic.frequency(of: word) != nil { return true }
        if model.english.frequency(of: word) != nil { return true }
        if checkMorphology, model.morphology?.isKnown(word) == true { return true }
        return false
    }

    /// Spatial cost of a candidate; strict-prefix completions are charged
    /// per not-yet-typed character instead of per "insertion error".
    func spatialCost(typedChars: [Character], candidate: String) -> Double {
        let candidateChars = Array(candidate)
        var cost = spatial.typingCost(typed: typedChars, intended: candidateChars)
        if candidateChars.count > typedChars.count, candidateChars.starts(with: typedChars) {
            let extra = Double(candidateChars.count - typedChars.count)
            cost = min(cost, extra * config.completionCharCost)
        }
        return cost
    }

    /// All strings at Damerau-Levenshtein distance 1 from `chars`.
    static func edits1(of chars: [Character]) -> Set<String> {
        var out = Set<String>()
        let n = chars.count
        // deletions
        for i in 0..<n {
            var copy = chars
            copy.remove(at: i)
            out.insert(String(copy))
        }
        // transpositions
        if n >= 2 {
            for i in 0..<(n - 1) where chars[i] != chars[i + 1] {
                var copy = chars
                copy.swapAt(i, i + 1)
                out.insert(String(copy))
            }
        }
        // substitutions
        for i in 0..<n {
            for ch in alphabet where ch != chars[i] {
                var copy = chars
                copy[i] = ch
                out.insert(String(copy))
            }
        }
        // insertions
        for i in 0...n {
            for ch in alphabet {
                var copy = chars
                copy.insert(ch, at: i)
                out.insert(String(copy))
            }
        }
        return out
    }
}
