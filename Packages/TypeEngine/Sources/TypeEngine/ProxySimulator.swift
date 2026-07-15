import Foundation

/// Headless model of the iOS `UITextDocumentProxy` contract, for the macOS
/// harness (`type-repl`) and unit tests. Real keyboard extensions never see
/// the whole document: they get a truncated window (`documentContextBefore/
/// AfterInput`), can only `insertText`/`deleteBackward` at the cursor, and
/// must survive cursor jumps, host-app text mutation, and briefly-stale
/// context reads after inserts. This type reproduces those constraints so
/// `TypingSession` can be exercised against them off-device.
///
/// Modeled behaviors:
/// - truncated `contextBeforeInput` (configurable policy; default mimics the
///   common iOS shape: cut at the most recent sentence terminator — ./!/?
///   followed by a space — or a newline, and cap at 200 characters,
///   whichever window is shorter)
/// - `insertText` / `deleteBackward` at the cursor only
/// - cursor moves and wholesale host-app text replacement
/// - optional stale reads: the first context read after an `insertText`
///   returns the pre-insert state (real proxies are briefly stale)
///
/// Documented out of scope (device-tested, host-app-specific): per-app
/// window sizes and boundary quirks (hosts differ wildly), multi-stage
/// asynchronous context refresh, marked text / IME composition, and
/// selection ranges (only a caret is modeled).
public final class ProxySimulator {

    // MARK: - Truncation policy

    /// How `contextBeforeInput` is cut down from the full text before the
    /// cursor. Real iOS behavior varies by host app; the default here is the
    /// common shape (current sentence, capped length). Use `custom` to model
    /// a specific host.
    public struct TruncationPolicy {
        /// Hard cap on the returned window, in characters (applied last).
        public var maxBeforeLength: Int
        /// Cut at the most recent sentence terminator (". ", "! ", "? ") or
        /// newline, returning only the text after it.
        public var cutAtSentenceBoundary: Bool
        /// Full override: given the complete text before the cursor, return
        /// the window the proxy exposes. When set, the other fields are
        /// ignored.
        public var custom: ((String) -> String)?

        public init(
            maxBeforeLength: Int = 200,
            cutAtSentenceBoundary: Bool = true,
            custom: ((String) -> String)? = nil
        ) {
            self.maxBeforeLength = maxBeforeLength
            self.cutAtSentenceBoundary = cutAtSentenceBoundary
            self.custom = custom
        }

        /// The whole text before the cursor, no truncation (for tests).
        public static let none = TruncationPolicy(
            maxBeforeLength: .max,
            cutAtSentenceBoundary: false
        )

        func apply(to full: String) -> String {
            if let custom { return custom(full) }
            var window = Substring(full)
            if cutAtSentenceBoundary {
                window = Self.currentSentence(of: window)
            }
            if window.count > maxBeforeLength {
                window = window.suffix(maxBeforeLength)
            }
            return String(window)
        }

        /// Text after the most recent sentence terminator (./!/? followed by
        /// a space) or newline; the whole text when there is none.
        private static func currentSentence(of text: Substring) -> Substring {
            var boundary: Substring.Index?
            var previous: Character?
            var index = text.startIndex
            while index < text.endIndex {
                let ch = text[index]
                if ch.isNewline {
                    boundary = text.index(after: index)
                } else if ch == " ", let previous, ".!?".contains(previous) {
                    boundary = text.index(after: index)
                }
                previous = ch
                index = text.index(after: index)
            }
            guard let boundary else { return text }
            return text[boundary...]
        }
    }

    // MARK: - State

    /// The full document (what the host app holds; the keyboard never sees
    /// all of it).
    public private(set) var document: String
    /// Caret position as a character offset into `document` (0...count).
    public private(set) var cursor: Int

    public var truncation: TruncationPolicy

    /// When true, the first context read after each `insertText` /
    /// `deleteBackward` returns the pre-edit state — modeling the brief
    /// staleness of real proxies. Off by default.
    public var staleReads: Bool = false
    /// Pending stale snapshot: (before, after) windows captured pre-edit.
    private var staleSnapshot: (before: String, after: String)?

    public init(
        document: String = "",
        cursorAt cursor: Int? = nil,
        truncation: TruncationPolicy = TruncationPolicy()
    ) {
        self.document = document
        self.cursor = min(cursor ?? document.count, document.count)
        self.truncation = truncation
    }

    // MARK: - Context windows (what the keyboard sees)

    /// Truncated text before the cursor — the analogue of
    /// `documentContextBeforeInput`. Consumes the stale snapshot if one is
    /// pending.
    public var contextBeforeInput: String {
        if let stale = takeStaleSnapshotIfPending() { return stale.before }
        return truncation.apply(to: fullTextBeforeCursor)
    }

    /// Text after the cursor — the analogue of `documentContextAfterInput`
    /// (unbounded here; after-window truncation is not load-bearing for the
    /// engine, which only consumes the before-window).
    public var contextAfterInput: String {
        if let stale = takeStaleSnapshotIfPending() { return stale.after }
        return fullTextAfterCursor
    }

    /// Read both windows in one consistent snapshot (a single stale snapshot
    /// covers both, like one proxy read).
    public func contextWindows() -> (before: String, after: String) {
        if let stale = takeStaleSnapshotIfPending() { return stale }
        return (truncation.apply(to: fullTextBeforeCursor), fullTextAfterCursor)
    }

    // MARK: - Edits (all the keyboard can do)

    public func insertText(_ text: String) {
        captureStaleSnapshotIfEnabled()
        let index = characterIndex(at: cursor)
        document.insert(contentsOf: text, at: index)
        cursor += text.count
    }

    public func deleteBackward() {
        guard cursor > 0 else { return }
        captureStaleSnapshotIfEnabled()
        let index = characterIndex(at: cursor - 1)
        document.remove(at: index)
        cursor -= 1
    }

    // MARK: - Things that happen TO the keyboard

    /// Move the caret to an absolute character offset (cursor jump: user
    /// tapped elsewhere in the text). Clamped to the document bounds.
    public func moveCursor(to offset: Int) {
        cursor = min(max(offset, 0), document.count)
        staleSnapshot = nil
    }

    /// Move the caret by a relative delta.
    public func moveCursor(by delta: Int) {
        moveCursor(to: cursor + delta)
    }

    /// The host app replaces the text under us (autofill, undo, programmatic
    /// set). Cursor goes to `cursorAt` (default: end of new text).
    public func hostReplaceText(_ newDocument: String, cursorAt: Int? = nil) {
        document = newDocument
        cursor = min(cursorAt ?? newDocument.count, newDocument.count)
        staleSnapshot = nil
    }

    // MARK: - Internals

    private var fullTextBeforeCursor: String {
        String(document.prefix(cursor))
    }

    private var fullTextAfterCursor: String {
        String(document.suffix(document.count - cursor))
    }

    private func characterIndex(at offset: Int) -> String.Index {
        document.index(document.startIndex, offsetBy: offset)
    }

    private func captureStaleSnapshotIfEnabled() {
        guard staleReads else { return }
        staleSnapshot = (truncation.apply(to: fullTextBeforeCursor), fullTextAfterCursor)
    }

    private func takeStaleSnapshotIfPending() -> (before: String, after: String)? {
        guard let snapshot = staleSnapshot else { return nil }
        staleSnapshot = nil
        return snapshot
    }
}
