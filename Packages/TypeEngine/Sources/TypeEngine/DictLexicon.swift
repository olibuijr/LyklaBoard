import Lexicon

/// Dictionary-backed `Lexicon` for tests and the micro-eval harness.
///
/// The canonical `Lexicon` protocol lives in the Lexicon package (alongside
/// the production `FrequencyLexicon` mmap reader over `.lex` files); this
/// test double stays here because TypeEngine's tests and `type-eval` seed it
/// with tiny in-memory wordlists. Not intended for production use
/// (linear-scan completions).
public struct DictLexicon: Lexicon {
    private let unigrams: [String: UInt32]
    private let bigrams: [String: UInt32]
    public let totalUnigramTokens: UInt64

    /// - Parameters:
    ///   - unigrams: word -> frequency (words should be lowercased)
    ///   - bigrams: "first second" (single space) -> frequency
    public init(unigrams: [String: UInt32], bigrams: [String: UInt32] = [:]) {
        self.unigrams = unigrams
        self.bigrams = bigrams
        self.totalUnigramTokens = unigrams.values.reduce(0) { $0 + UInt64($1) }
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

    /// Bigram followers of `word`, descending bigram frequency (linear scan
    /// over the bigram table — test-double quality, mirrors
    /// `FrequencyLexicon.continuations(of:limit:)` semantics).
    public func continuations(of word: String, limit: Int) -> [(word: String, frequency: UInt32)] {
        guard limit > 0 else { return [] }
        let prefix = "\(word) "
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
