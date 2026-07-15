import Foundation
import LemmaCore
import Lexicon

extension BinaryLemmatizer: MorphologyProviding {}

/// Facade over the corrector and predictor with a running bilingual language
/// posterior. Pure synchronous API — no dispatch/async inside; the caller
/// owns threading. Not thread-safe (confirmWord mutates the posterior); use
/// from a single queue.
public final class TypeEngine {
    public let config: EngineConfig

    private let model: BlendedLanguageModel
    private let corrector: Corrector
    private let predictor: Predictor

    /// Running language posterior P(Icelandic), clamped to
    /// [posteriorFloor, posteriorCeiling]. Starts at 0.5.
    public private(set) var probabilityIcelandic: Double

    /// Production initializer: BÍN morphology via LemmaCore.
    public convenience init(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: BinaryLemmatizer?,
        config: EngineConfig = EngineConfig()
    ) {
        self.init(
            icelandic: icelandic,
            english: english,
            morphologyProvider: morphology,
            config: config
        )
    }

    /// Designated initializer; accepts any MorphologyProviding (tests use a
    /// dictionary-backed fake).
    public init(
        icelandic: Lexicon,
        english: Lexicon,
        morphologyProvider: MorphologyProviding? = nil,
        config: EngineConfig = EngineConfig()
    ) {
        self.config = config
        let model = BlendedLanguageModel(
            icelandic: icelandic,
            english: english,
            morphology: morphologyProvider,
            config: config
        )
        self.model = model
        self.corrector = Corrector(model: model, config: config)
        self.predictor = Predictor(model: model, config: config)
        self.probabilityIcelandic = 0.5
    }

    /// Suggestions for the suggestion bar.
    ///
    /// - Parameters:
    ///   - context: committed text before the current word (used only for the
    ///     trailing word, as bigram context)
    ///   - currentWord: the word being typed; empty string means "predict the
    ///     next word"
    ///   - limit: maximum suggestions returned
    public func suggestions(context: String, currentWord: String, limit: Int = 3) -> [Suggestion] {
        let previous = Self.lastWord(in: context)
        let trimmed = currentWord.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return predictor.nextWords(
                previousWord: previous,
                pIcelandic: probabilityIcelandic,
                limit: limit
            )
        }

        let result = corrector.correct(
            typed: trimmed,
            previousWord: previous,
            pIcelandic: probabilityIcelandic,
            limit: limit
        )

        // Preserve the user's leading capitalization.
        if let first = trimmed.first, first.isUppercase {
            return result.suggestions.map {
                Suggestion(
                    text: $0.text.prefix(1).uppercased() + $0.text.dropFirst(),
                    isAutocorrect: $0.isAutocorrect,
                    confidence: $0.confidence
                )
            }
        }
        return result.suggestions
    }

    /// Update the language posterior after the user commits a word
    /// (typed through, tapped a suggestion, or accepted an autocorrect).
    /// Words unknown to both languages leave the posterior unchanged.
    public func confirmWord(_ word: String) {
        let w = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }

        let knownIS = model.effectiveFrequency(of: w, language: .icelandic) != nil
        let knownEN = model.english.frequency(of: w) != nil

        let signal: Double
        switch (knownIS, knownEN) {
        case (true, false):
            signal = 1
        case (false, true):
            signal = 0
        case (true, true):
            let pIS = model.unigramProbability(of: w, language: .icelandic)
            let pEN = model.unigramProbability(of: w, language: .english)
            if pIS == pEN { return }
            signal = pIS > pEN ? 1 : 0
        case (false, false):
            return
        }

        let alpha = config.posteriorAlpha
        let updated = (1 - alpha) * probabilityIcelandic + alpha * signal
        probabilityIcelandic = min(max(updated, config.posteriorFloor), config.posteriorCeiling)
    }

    /// Reset the posterior to the 50/50 prior (e.g. new text field).
    public func resetLanguagePosterior() {
        probabilityIcelandic = 0.5
    }

    // MARK: - Internals

    /// Trailing word of the committed context, lowercased and stripped of
    /// surrounding punctuation; nil if there is none.
    static func lastWord(in context: String) -> String? {
        guard
            let token = context
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                .last
        else { return nil }
        let stripped = token.trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.symbols)
        )
        guard !stripped.isEmpty else { return nil }
        return stripped.lowercased()
    }
}
