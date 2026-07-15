import Foundation
import TypeEngine

/// Drives a `TypingSession` through a `ProxySimulator` exactly the way the
/// keyboard extension is driven on device:
///
/// - every keystroke is `proxy.insertText` (or `deleteBackward`),
/// - the session only ever sees `proxy.contextBeforeInput` — the truncated
///   window, never the full document,
/// - typing a word delimiter while the bar holds an `.autocorrect`
///   suggestion first replaces the current word (delete-backward x n +
///   insert), mirroring KeyboardKit's `StandardActionHandler` space-commit,
/// - cursor jumps / host mutations notify the session via
///   `noteExternalTextChange()` and trigger a refresh, which is what a
///   correct extension should do from `selectionDidChange`/`textDidChange`.
final class Typist {
    let session: TypingSession
    let proxy: ProxySimulator
    var limit: Int

    private(set) var lastSuggestions: [Suggestion] = []
    /// The context window the session saw on the most recent refresh.
    private(set) var lastContextBefore = ""
    private(set) var lastLatencyMicros = 0.0
    private(set) var latenciesMicros: [Double] = []
    /// Set when the most recent keystroke applied an autocorrect.
    private(set) var lastAppliedAutocorrect: (from: String, to: String)?

    private let clock = ContinuousClock()

    init(engine: TypeEngine, proxy: ProxySimulator = ProxySimulator(), limit: Int = 5) {
        self.session = TypingSession(engine: engine)
        self.proxy = proxy
        self.limit = limit
    }

    /// Word currently in progress, as of the last refresh.
    var currentWord: String {
        TypingSession.splitCurrentWord(of: lastContextBefore).currentWord
    }

    // MARK: - Typing

    func type(_ text: String) {
        for character in text { typeCharacter(character) }
    }

    func typeCharacter(_ character: Character) {
        lastAppliedAutocorrect = nil
        // KeyboardKit space-commit: a delimiter keystroke first applies the
        // pending autocorrect suggestion (replace current word), then inserts
        // the delimiter.
        if TypingSession.isDelimiter(character),
            let autocorrect = lastSuggestions.first(where: { $0.isAutocorrect })
        {
            let word = currentWord
            if !word.isEmpty, autocorrect.text != word {
                for _ in 0..<word.count { proxy.deleteBackward() }
                proxy.insertText(autocorrect.text)
                lastAppliedAutocorrect = (from: word, to: autocorrect.text)
            }
        }
        proxy.insertText(String(character))
        refresh()
    }

    func pressBackspace(_ count: Int = 1) {
        for _ in 0..<count {
            proxy.deleteBackward()
            refresh()
        }
    }

    // MARK: - External events

    /// Cursor jump / host mutation happened on the proxy; tell the session
    /// and re-run autocomplete on the new window.
    func externalChange() {
        session.noteExternalTextChange()
        refresh()
    }

    /// Same event, but WITHOUT notifying the session — exercises the
    /// session's internal non-append window-change detection (the
    /// belt-and-braces path for hosts/timing where the extension's
    /// selectionDidChange/textDidChange forwarding is missed).
    func silentExternalChange() {
        refresh()
    }

    /// Simulate the extension forwarding `textDidChange`/`selectionDidChange`
    /// to the session: the window-aware, idempotent note. Fires after our
    /// own insertions too on device, so scenarios use it to prove it never
    /// disturbs normal typing.
    func forwardWindowNote() {
        session.noteExternalTextChange(window: proxy.contextBeforeInput)
    }

    /// Re-read the proxy and re-run autocomplete (KeyboardKit does this on
    /// every text change; also useful to sync after stale reads).
    func refresh() {
        let before = proxy.contextBeforeInput
        lastContextBefore = before
        let start = clock.now
        lastSuggestions = session.suggestions(for: before, limit: limit)
        let micros = start.duration(to: clock.now).microseconds
        lastLatencyMicros = micros
        latenciesMicros.append(micros)
    }

    /// Fresh field: empty document, session state + posterior reset.
    func reset(document: String = "") {
        proxy.hostReplaceText(document)
        session.reset()
        lastSuggestions = []
        lastContextBefore = ""
        lastAppliedAutocorrect = nil
        latenciesMicros.removeAll()
        lastLatencyMicros = 0
    }

    // MARK: - Presentation helpers

    /// Human description of what a space press would commit right now.
    var spaceCommitDescription: String {
        let word = currentWord
        if word.isEmpty {
            return "space is just a space (no word in progress)"
        }
        if let autocorrect = lastSuggestions.first(where: { $0.isAutocorrect }) {
            return "space commits \"\(autocorrect.text)\" (AUTOCORRECT from \"\(word)\")"
        }
        return "space commits \"\(word)\" (as typed)"
    }

    /// One-line suggestion bar, autocorrect flagged with `*`.
    var barDescription: String {
        guard !lastSuggestions.isEmpty else { return "(no suggestions)" }
        return lastSuggestions.enumerated()
            .map { index, s in "\(index + 1).\(s.text)\(s.isAutocorrect ? "*" : "")" }
            .joined(separator: "  ")
    }
}
