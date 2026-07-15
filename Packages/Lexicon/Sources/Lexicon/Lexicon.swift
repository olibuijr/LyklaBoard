/// Frequency lexicon for ranking and prediction.
///
/// Distinct from `LemmaCore.BinaryLemmatizer` (which answers "is this a
/// valid Icelandic form, and what's its lemma/morphology") — a `Lexicon`
/// answers "how common is this word / this word pair", which is what
/// autocorrect ranking and next-word prediction need.
public protocol Lexicon: Sendable {
    /// Unigram frequency of a (lowercased) word; nil if unknown.
    func frequency(of word: String) -> UInt32?
    /// Frequency of the bigram "first second"; nil if unseen.
    func bigramFrequency(_ first: String, _ second: String) -> UInt32?
    /// Up to `limit` known words starting with `prefix`, descending frequency.
    func completions(of prefix: String, limit: Int) -> [(word: String, frequency: UInt32)]
    /// Sum of all unigram frequencies (for probability normalization).
    var totalUnigramTokens: UInt64 { get }
}
