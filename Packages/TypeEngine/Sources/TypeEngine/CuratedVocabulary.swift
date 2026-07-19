import Foundation

/// Always-on curated supplementary vocabulary — the shipped "head of the long
/// tail": high-frequency real words that BÍN doesn't contain and the icegrams
/// corpus structurally can't (brands, tech, anglicisms, colloquial —
/// "ChatGPT", "TikTok", "podcast", "deploya", "Bónus", "okei").
///
/// It's modeled as a `PersonalVocabulary` conformer on purpose: that reuses the
/// engine's existing valid-word + completion + display-casing machinery
/// wholesale. `PersonalStore` case-folds the keys for matching and restores the
/// canonical *cased* surface form at display time, so "ChatGPT" and "iPhone"
/// come out of the suggestion bar correctly cased — something the lowercase-only
/// base lexicons (is.lex) cannot do.
///
/// Unlike the user's personal store, this list is:
///   - **always on** — never gated behind Lyklaborð+ (it's free base vocabulary),
///   - **static** — no bigrams, continuations, decay, or tombstones,
///   - **explicit** — every entry carries full autocorrect-veto protection, so
///     typing a curated brand is never "corrected" away.
public struct CuratedVocabulary: PersonalVocabulary {

    private let entries: [(word: String, count: UInt32)]
    private let keys: Set<String>

    /// - Parameters:
    ///   - surfaceForms: case-preserving surface forms ("ChatGPT", "appið").
    ///   - count: the seed count each curated word carries. Kept modest so
    ///     curated words are protected + suggestible + lightly boosted
    ///     (`personalBoost` ~ log(1+count)) without overpowering corpus
    ///     vocabulary. De-duplicates on the case-folded key, first casing wins.
    public init(surfaceForms: [String], count: UInt32 = 8) {
        var seen = Set<String>()
        var entries: [(word: String, count: UInt32)] = []
        for form in surfaceForms {
            let key = form.lowercased()
            guard seen.insert(key).inserted else { continue }
            entries.append((word: form, count: count))
        }
        self.entries = entries
        self.keys = seen
    }

    /// Parse the bundled `extra-vocab.txt`: one surface form per line, `#`
    /// comments and blank lines ignored. Returns nil if the file is missing or
    /// empty (the engine then simply runs without the extra layer).
    public init?(contentsOf url: URL, count: UInt32 = 8) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let forms = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !forms.isEmpty else { return nil }
        self.init(surfaceForms: forms, count: count)
    }

    public func allWords() -> [(word: String, count: UInt32)] { entries }

    public func continuations(of first: String, limit: Int) -> [(word: String, count: UInt32)] { [] }

    public func bigramCount(_ first: String, _ second: String) -> UInt32? { nil }

    public func isTombstoned(_ word: String) -> Bool { false }

    public func isExplicit(_ word: String) -> Bool { keys.contains(word.lowercased()) }

    /// Whether the curated set contains this surface form (case-folded).
    public func contains(_ word: String) -> Bool { keys.contains(word.lowercased()) }

    /// Number of curated entries (post de-duplication).
    public var count: Int { entries.count }
}

/// Unions the always-on curated vocabulary with the user's (Lyklaborð+-gated)
/// personal vocabulary into a single `PersonalVocabulary` the engine consumes.
/// Curated words are static/explicit; personal words carry the live learning
/// signal (counts, bigrams, continuations, tombstones). On a case-folded key
/// collision the engine's `PersonalStore` keeps the highest-count surface as the
/// canonical display form.
public struct CompositeVocabulary: PersonalVocabulary {

    private let curated: CuratedVocabulary
    private let personal: PersonalVocabulary

    public init(curated: CuratedVocabulary, personal: PersonalVocabulary) {
        self.curated = curated
        self.personal = personal
    }

    public func allWords() -> [(word: String, count: UInt32)] {
        curated.allWords() + personal.allWords()
    }

    public func continuations(of first: String, limit: Int) -> [(word: String, count: UInt32)] {
        personal.continuations(of: first, limit: limit)
    }

    public func bigramCount(_ first: String, _ second: String) -> UInt32? {
        personal.bigramCount(first, second)
    }

    public func isTombstoned(_ word: String) -> Bool {
        // A user deletion still silences a curated word (never suggest it); the
        // word stays uncorrected when typed verbatim either way.
        personal.isTombstoned(word)
    }

    public func isExplicit(_ word: String) -> Bool {
        curated.contains(word) || personal.isExplicit(word)
    }
}
