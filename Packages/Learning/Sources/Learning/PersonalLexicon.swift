import Foundation
import Lexicon

/// Immutable `Lexicon`-conforming snapshot of a `PersonalModel`, so the
/// wave-2 engine can blend the personal store as a third suggestion source
/// through exactly the same protocol as the base `is.lex` / `en.lex`
/// readers (`FrequencyLexicon`) — no special-casing in the blender.
///
/// Why a wrapper instead of conforming `PersonalModel` directly:
/// `Lexicon` requires `Sendable`, and the model is a mutable reference type
/// that the app compacts on its own schedule. A value-type snapshot taken at
/// keyboard launch (and refreshed when the app signals a new model file) is
/// both trivially Sendable and immune to mid-keystroke mutation.
///
/// Only LEARNED words are exposed (threshold met, explicit signal, or
/// user-added — never tombstoned): pending one-off commits must not leak
/// into ranking. Bigram continuations are pair-level evidence and are
/// exposed as the model recorded them (minus tombstoned followers).
///
/// Personal scale is small (thousands of entries), so `completions` /
/// `continuations` are linear scans — measured in microseconds at this size,
/// mirroring the `DictLexicon` approach in TypeEngine.
public struct PersonalLexicon: Lexicon, Sendable {
    private let unigrams: [String: UInt32]
    private let bigrams: [String: UInt32]
    public let totalUnigramTokens: UInt64

    public init(model: PersonalModel) {
        var unigrams: [String: UInt32] = [:]
        for word in model.learnedWords {
            unigrams[word] = model.frequency(of: word) ?? 0
        }
        for word in model.userAddedWords {
            unigrams[word] = model.frequency(of: word) ?? 1
        }
        self.unigrams = unigrams

        var bigrams: [String: UInt32] = [:]
        for (key, count) in model.bigrams {
            guard let spaceIndex = key.firstIndex(of: " ") else { continue }
            let first = String(key[..<spaceIndex])
            let second = String(key[key.index(after: spaceIndex)...])
            guard !model.isTombstoned(first), !model.isTombstoned(second) else { continue }
            bigrams[key] = count
        }
        self.bigrams = bigrams

        totalUnigramTokens = unigrams.values.reduce(UInt64(0)) { $0 + UInt64($1) }
    }

    public func frequency(of word: String) -> UInt32? {
        unigrams[word]
    }

    public func bigramFrequency(_ first: String, _ second: String) -> UInt32? {
        bigrams["\(first) \(second)"]
    }

    public func completions(of prefix: String, limit: Int) -> [(word: String, frequency: UInt32)] {
        guard limit > 0 else { return [] }
        return unigrams
            .filter { $0.key.hasPrefix(prefix) }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit)
            .map { (word: $0.key, frequency: $0.value) }
    }

    public func continuations(of word: String, limit: Int) -> [(word: String, frequency: UInt32)] {
        guard limit > 0 else { return [] }
        let prefix = word + " "
        return bigrams
            .compactMap { key, freq -> (word: String, frequency: UInt32)? in
                guard key.hasPrefix(prefix) else { return nil }
                return (word: String(key.dropFirst(prefix.count)), frequency: freq)
            }
            .sorted { $0.frequency > $1.frequency || ($0.frequency == $1.frequency && $0.word < $1.word) }
            .prefix(limit)
            .map { $0 }
    }
}
