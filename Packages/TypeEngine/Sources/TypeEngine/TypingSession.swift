import Foundation

/// UIKit-free typing session over a `TypeEngine`.
///
/// This is the single shared implementation of the "text before cursor" →
/// suggestions pipeline used by BOTH the keyboard extension
/// (`BetterKeyboardAutocompleteService`) and the macOS `type-repl` harness,
/// so the two always run the identical path:
///
/// 1. parse the full text before the cursor into (committed context,
///    word currently being typed),
/// 2. detect the word-commit transition (word-in-progress → delimiter) and
///    feed the committed word to `TypeEngine.confirmWord` (language
///    posterior update),
/// 3. apply the ≥2-typed-characters gate before completion/correction-style
///    suggestions (single-letter prefixes hit the 20k-entry completion scan
///    cap on is.lex, ~2.8 ms/call; 2+ char prefixes have far smaller
///    ranges; an empty current word is next-word prediction, which is
///    cheap),
/// 4. ask the engine for suggestions.
///
/// Not thread-safe (it owns mutable per-call state and TypeEngine's
/// posterior); confine it to one queue, exactly like `TypeEngine` itself.
public final class TypingSession {

    public let engine: TypeEngine

    /// Number of word commits detected so far (i.e. `confirmWord` calls).
    public private(set) var committedWordCount = 0
    /// Number of commits that actually moved the language posterior (words
    /// unknown to both languages, or exact probability ties, leave it
    /// unchanged).
    public private(set) var posteriorUpdateCount = 0
    /// The most recently committed word, as read back out of the committed
    /// text (so it reflects an applied autocorrect, not the raw fragment).
    public private(set) var lastCommittedWord: String?

    /// The `currentWord` parsed from the previous `suggestions(for:)` call,
    /// used to detect the word-commit transition.
    private var previousCurrentWord = ""

    public init(engine: TypeEngine) {
        self.engine = engine
    }

    /// Convenience passthrough: the engine's running P(Icelandic).
    public var probabilityIcelandic: Double { engine.probabilityIcelandic }

    // MARK: - Main entry point

    /// Suggestions for the full text before the input cursor
    /// (`documentContextBeforeInput` on device; the harness buffer on
    /// macOS). Call this once per text change — it is stateful (commit
    /// detection compares against the previous call).
    @discardableResult
    public func suggestions(for textBeforeCursor: String, limit: Int = 3) -> [Suggestion] {
        let (context, currentWord) = Self.splitCurrentWord(of: textBeforeCursor)
        confirmIfCommitted(context: context, currentWord: currentWord)
        previousCurrentWord = currentWord

        // ≥2-char gate (see type doc, point 3).
        if currentWord.count == 1 {
            return []
        }

        return engine.suggestions(
            context: context,
            currentWord: currentWord,
            limit: limit
        )
    }

    /// Tell the session the text before the cursor changed for a reason
    /// other than typing — cursor jump, host-app mutation (autofill, undo),
    /// switching fields. This clears the pending word-in-progress so the
    /// commit detector doesn't misread the new window as "the user just
    /// finished a word" (spurious `confirmWord`) or attribute a host-inserted
    /// word to the user. On device this corresponds to
    /// `textDidChange`/`selectionDidChange`; the extension does not call it
    /// yet (known gap — see harness findings).
    public func noteExternalTextChange() {
        previousCurrentWord = ""
    }

    /// Forget all per-session state and reset the language posterior to the
    /// 50/50 prior. Harness use (e.g. `:reset`, scenario isolation); the
    /// extension currently keeps one session for its whole lifetime.
    public func reset() {
        previousCurrentWord = ""
        committedWordCount = 0
        posteriorUpdateCount = 0
        lastCommittedWord = nil
        engine.resetLanguagePosterior()
    }

    // MARK: - Word commit

    /// Minimal word-commit detection for the language posterior (full
    /// learning integration is M2): a word counts as committed when the
    /// previous call had a word in progress and this call doesn't — i.e. the
    /// user just typed a delimiter (space/period/…) after it, or applied a
    /// toolbar suggestion / autocorrect (both insert the word + a space,
    /// which lands here on the next text change). The confirmed word is read
    /// back out of the committed text so it reflects any applied correction,
    /// not the raw typed fragment.
    private func confirmIfCommitted(context: String, currentWord: String) {
        guard currentWord.isEmpty, !previousCurrentWord.isEmpty else { return }
        guard let committed = Self.lastWord(in: context) else { return }
        let before = engine.probabilityIcelandic
        engine.confirmWord(committed)
        committedWordCount += 1
        lastCommittedWord = committed
        if engine.probabilityIcelandic != before {
            posteriorUpdateCount += 1
        }
    }

    // MARK: - Text parsing

    /// Word-delimiter punctuation, mirroring KeyboardKit's canonical
    /// `String.wordDelimiters` set (punctuation, brackets, guillemets,
    /// Tibetan marks, zero-width space); whitespace/newlines are handled via
    /// `Character.isWhitespace`/`isNewline` below. Kept KeyboardKit-free so
    /// the harness and the extension share one definition — this type is now
    /// the single source of truth. Note apostrophes and hyphens are NOT
    /// delimiters, so English contractions ("don't") and hyphenated words
    /// stay one word.
    private static let delimiterPunctuation: Set<Character> = Set(".,:;!¡?¿()[]{}<>«»་།\u{200B}")

    /// Is this character a word delimiter?
    public static func isDelimiter(_ character: Character) -> Bool {
        character.isWhitespace
            || character.isNewline
            || delimiterPunctuation.contains(character)
    }

    /// Split the text before the cursor into (committed context, word
    /// currently being typed). The current word is the trailing run of
    /// non-delimiter characters; empty when the text ends with a delimiter
    /// (word just committed / sentence start).
    public static func splitCurrentWord(of text: String) -> (context: String, currentWord: String) {
        guard let index = text.lastIndex(where: isDelimiter) else {
            return (context: "", currentWord: text)
        }
        let wordStart = text.index(after: index)
        return (
            context: String(text[..<wordStart]),
            currentWord: String(text[wordStart...])
        )
    }

    /// Trailing word of committed text, with surrounding delimiters
    /// stripped; nil if there is none.
    public static func lastWord(in text: String) -> String? {
        let word = text
            .split(whereSeparator: isDelimiter)
            .last
            .map(String.init)
        guard let word, !word.isEmpty else { return nil }
        return word
    }
}
