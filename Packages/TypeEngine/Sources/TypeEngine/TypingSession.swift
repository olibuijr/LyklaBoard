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
/// 2. classify how the window changed since the previous call (append /
///    word-replacement / shrink / truncation slide / external change) and
///    only treat a delimiter-completed word as committed when the change is
///    a valid single-keystroke evolution — cursor jumps and host-app
///    mutations are detected internally and never miscounted as commits,
/// 3. feed genuinely committed words to `TypeEngine.confirmWord` (language
///    posterior update),
/// 4. apply the ≥2-typed-characters gate before completion/correction-style
///    suggestions (single-letter prefixes hit the 20k-entry completion scan
///    cap on is.lex, ~2.8 ms/call; 2+ char prefixes have far smaller
///    ranges; an empty current word is next-word prediction, which is
///    cheap),
/// 5. ask the engine for suggestions.
///
/// Not thread-safe (it owns mutable per-call state and TypeEngine's
/// posterior); confine it to one queue, exactly like `TypeEngine` itself.
public final class TypingSession {

    public let engine: TypeEngine

    /// Number of word commits detected so far (i.e. `confirmWord` calls).
    public private(set) var committedWordCount = 0
    /// Number of commits that actually moved the language posterior (words
    /// not strongly attributable to one language leave it unchanged).
    public private(set) var posteriorUpdateCount = 0
    /// The most recently committed word, as read back out of the committed
    /// text (so it reflects an applied autocorrect, not the raw fragment).
    public private(set) var lastCommittedWord: String?

    /// The full window seen by the previous `suggestions(for:)` call;
    /// nil when there is no trusted last-seen state (fresh session, reset,
    /// or just after an external change).
    private var lastSeenWindow: String?
    /// The `currentWord` parsed from the previous `suggestions(for:)` call,
    /// used by the word-commit transition check.
    private var previousCurrentWord = ""
    /// Bigram context carried across a proxy sentence-truncation reset:
    /// when the window collapses to empty right after a sentence terminator
    /// (iOS proxies cut the before-window at ". "), the words the user just
    /// typed are still on screen — keep the last committed word as bigram
    /// context for the first word of the new sentence. Cleared by external
    /// changes, reset, and as soon as the new window has its own context.
    private var carriedContext: String?

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

        switch classifyChange(to: textBeforeCursor) {
        case .evolution(let appendedAfterContext):
            confirmIfCommitted(
                context: context,
                currentWord: currentWord,
                appendedAfterContext: appendedAfterContext
            )
        case .truncationReset:
            // Window collapsed to empty right after a sentence terminator:
            // retain bigram context across the proxy's sentence cut.
            carriedContext = lastCommittedWord
        case .external:
            carriedContext = nil
        }
        if !context.isEmpty {
            // The new window has its own committed context; stop carrying.
            carriedContext = nil
        }

        previousCurrentWord = currentWord
        lastSeenWindow = textBeforeCursor

        // ≥2-char gate (see type doc, point 4).
        if currentWord.count == 1 {
            return []
        }

        let effectiveContext = context.isEmpty ? (carriedContext ?? "") : context
        return engine.suggestions(
            context: effectiveContext,
            currentWord: currentWord,
            limit: limit
        )
    }

    /// Tell the session the text before the cursor changed for a reason
    /// other than typing — cursor jump, host-app mutation (autofill, undo),
    /// switching fields. This clears the pending word-in-progress so the
    /// commit detector doesn't misread the new window as "the user just
    /// finished a word" (spurious `confirmWord`) or attribute a host-inserted
    /// word to the user. The session also detects most external changes
    /// internally (see `classifyChange`); this is the belt-and-braces path.
    public func noteExternalTextChange() {
        previousCurrentWord = ""
        lastSeenWindow = nil
        carriedContext = nil
    }

    /// Window-aware variant, safe to forward from the extension's
    /// `textDidChange`/`selectionDidChange` — which ALSO fire after our own
    /// insertions. Idempotent: the note is ignored when `window` is
    /// consistent with the session's own last-seen state (unchanged, or a
    /// valid typing evolution the next `suggestions(for:)` call will handle);
    /// only a genuinely inconsistent window clears the pending word.
    public func noteExternalTextChange(window: String) {
        guard lastSeenWindow != nil else { return }
        if case .external = classifyChange(to: window) {
            noteExternalTextChange()
        }
    }

    /// Forget all per-session state and reset the language posterior to the
    /// 50/50 prior. Harness use (e.g. `:reset`, scenario isolation); the
    /// extension currently keeps one session for its whole lifetime.
    public func reset() {
        previousCurrentWord = ""
        lastSeenWindow = nil
        carriedContext = nil
        committedWordCount = 0
        posteriorUpdateCount = 0
        lastCommittedWord = nil
        engine.resetLanguagePosterior()
    }

    // MARK: - Window-change classification

    private enum WindowChange {
        /// The window is consistent with our last-seen state: unchanged,
        /// appended-to, current word replaced (autocorrect / suggestion
        /// tap), shrunk by deletion, or slid by proxy truncation.
        /// `appendedAfterContext` is the text that appeared after the
        /// previous committed context ("" when nothing was added there).
        case evolution(appendedAfterContext: String)
        /// The window collapsed to empty immediately after a sentence
        /// terminator — the iOS proxy's sentence cut (". " boundary).
        case truncationReset
        /// The window cannot be explained by typing since the last call:
        /// cursor jump, host mutation, field switch.
        case external
    }

    private func classifyChange(to window: String) -> WindowChange {
        guard let previous = lastSeenWindow else {
            // No trusted state: adopt the window without committing anything.
            return .external
        }
        if window == previous {
            return .evolution(appendedAfterContext: "")
        }

        let previousContext = Self.splitCurrentWord(of: previous).context

        // Change confined to at/after the previous word boundary: plain
        // typing, or the current word being replaced by an applied
        // suggestion/autocorrect (KeyboardKit inserts word + delimiter).
        if window.hasPrefix(previousContext) {
            return .evolution(appendedAfterContext: String(window.dropFirst(previousContext.count)))
        }

        // Window shrank to a prefix of what we saw: backspacing (possibly
        // past the word boundary) or a jump back — neither commits.
        if previous.hasPrefix(window) {
            if window.isEmpty, Self.endsWithSentenceTerminator(previous), lastCommittedWord != nil {
                return .truncationReset
            }
            return .evolution(appendedAfterContext: "")
        }

        // Sliding window (length-capped proxy): the front of the previous
        // window was truncated away while the user kept typing. Align the
        // longest suffix of `previous` that is a prefix of `window`; accept
        // only keystroke-sized growth past the overlap.
        var index = previous.index(after: previous.startIndex)
        while index < previous.endIndex {
            let candidate = previous[index...]
            if window.hasPrefix(candidate) {
                let appended = window.count - candidate.count
                if appended <= 4 {
                    let context = Self.splitCurrentWord(of: String(candidate)).context
                    return .evolution(appendedAfterContext: String(window.dropFirst(context.count)))
                }
                break
            }
            index = previous.index(after: index)
        }

        return .external
    }

    private static func endsWithSentenceTerminator(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else { return false }
        return last == "." || last == "!" || last == "?"
    }

    // MARK: - Word commit

    /// Minimal word-commit detection for the language posterior (full
    /// learning integration is M2): a word counts as committed when the
    /// previous call had a word in progress, this call doesn't — i.e. the
    /// user just typed a delimiter (space/period/…) after it, or applied a
    /// toolbar suggestion / autocorrect (both insert the word + a space) —
    /// AND the window change actually added that word+delimiter after the
    /// previous context. Backspacing a word-in-progress away adds nothing
    /// (no commit), and a change that introduced several words at once is a
    /// host paste/autofill, not a user keystroke (no commit). The confirmed
    /// word is read back out of the committed text so it reflects any
    /// applied correction, not the raw typed fragment.
    private func confirmIfCommitted(
        context: String,
        currentWord: String,
        appendedAfterContext: String
    ) {
        guard currentWord.isEmpty, !previousCurrentWord.isEmpty else { return }
        guard !appendedAfterContext.isEmpty else { return }
        // A single keystroke commits at most one word.
        guard appendedAfterContext.split(whereSeparator: Self.isDelimiter).count <= 1 else { return }
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
