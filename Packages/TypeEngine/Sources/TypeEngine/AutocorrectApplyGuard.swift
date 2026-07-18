//
//  AutocorrectApplyGuard.swift
//  TypeEngine
//
//  Apply-time staleness guard for delimiter-triggered autocorrect
//  (wave #28, root-caused from device session 2026-07-17T08-30-35):
//  suggestion delivery from the async engine queue to the main-actor
//  `AutocompleteContext` is not guaranteed to be current relative to
//  keystrokes, so the `.autocorrect` suggestion sitting in the context when
//  a delimiter lands can belong to a PREVIOUS word ("Þatturinn" applied
//  over "Lovr", six passes stale). The keyboard-side bridge stamps every
//  suggestion with the engine's pending token at production time
//  (`LyklabordAutocompleteService.pendingTokenInfoKey`); at auto-apply
//  time the action handler calls `shouldAutoApply` to verify that recorded
//  token still matches the token the delimiter is about to commit. On
//  mismatch the apply is skipped and the delimiter inserts plainly — the
//  user keeps what they typed, never a resurrected older correction.
//
//  Pure and platform-free on purpose: the extension-layer race cannot run
//  on macOS, so the decision logic lives here (the same macOS-testable
//  package that owns the pending-token semantics via
//  `TypingSession.splitCurrentWord`) with XCTest coverage in
//  TypeEngineTests. Bar taps are unaffected — the user sees what they tap;
//  only the delimiter auto-apply path consults this guard.
//
public enum AutocorrectApplyGuard {

    /// Whether a delimiter keystroke may auto-apply the armed autocorrect
    /// suggestion.
    ///
    /// - Parameters:
    ///   - recordedPendingToken: the pending token the engine stamped into
    ///     the suggestion when it was produced (the WHOLE session token —
    ///     may span dots/'@' and a trailing deferred dot — NOT
    ///     KeyboardKit's dot-sheared current word). `nil` means the
    ///     suggestion carries no stamp (not produced by our bridge): never
    ///     auto-apply, fail closed.
    ///   - textBeforeCursor: the live proxy text before the cursor at apply
    ///     time (the delimiter has not been inserted yet).
    ///
    /// The comparison is case-sensitive and uses the exact token boundary
    /// the bridge used (`TypingSession.splitCurrentWord`), so the
    /// deferred-dot token "teh." and dotted tokens like
    /// "profilmynd.tilvinstri" compare whole. An empty recorded token never
    /// auto-applies (an autocorrect requires a pending word; empty means
    /// the suggestion was produced at a word boundary — e.g. a stale bar
    /// surviving into a mode-2 prediction insert).
    public static func shouldAutoApply(
        recordedPendingToken: String?,
        textBeforeCursor: String
    ) -> Bool {
        guard let recorded = recordedPendingToken, !recorded.isEmpty else { return false }
        let live = TypingSession.splitCurrentWord(of: textBeforeCursor).currentWord
        return recorded == live
    }

    /// Delivery-side staleness check (defense in depth behind
    /// `shouldAutoApply`): whether an autocomplete result computed for
    /// `requestText` under `requestGeneration` has been superseded by a
    /// newer request for DIFFERENT input text, and should therefore be
    /// published as outdated (KeyboardKit's `ServiceResult.isOutdated`
    /// makes the context drop it without clearing the bar).
    ///
    /// A newer request for the SAME text is not superseding — publishing
    /// the identical suggestions is harmless and keeps the bar fresh.
    public static func isSupersededResult(
        requestGeneration: UInt64,
        requestText: String,
        latestGeneration: UInt64,
        latestText: String
    ) -> Bool {
        latestGeneration != requestGeneration && latestText != requestText
    }
}
