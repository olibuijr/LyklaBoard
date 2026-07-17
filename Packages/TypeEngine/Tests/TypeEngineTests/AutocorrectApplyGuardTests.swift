import XCTest

@testable import TypeEngine

/// Unit tests for the apply-time autocorrect staleness guard (wave #28).
///
/// The race itself is extension-layer (async engine queue → main-actor
/// context vs. keystrokes) and cannot run on macOS; these tests pin the
/// pure decision logic the action handler consults at delimiter time,
/// including the exact shape of the real device trace that motivated it
/// (session 2026-07-17T08-30-35: the previous word's "Þátturinn"
/// suggestion applied over the freshly typed "Lovr").
final class AutocorrectApplyGuardTests: XCTestCase {

    // MARK: - shouldAutoApply

    func testFreshSuggestionMatchingPendingTokenApplies() {
        XCTAssertTrue(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: "Lovr",
                textBeforeCursor: "Þátturinn Lovr"))
    }

    func testStaleSuggestionFromPreviousWordIsSkipped() {
        // The device trace: the context still holds the suggestion produced
        // for "Þatturinn" (recorded token) when the space after "Lovr"
        // lands. Must NOT apply.
        XCTAssertFalse(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: "Þatturinn",
                textBeforeCursor: "Þátturinn Lovr"))
    }

    func testComparisonIsCaseSensitive() {
        XCTAssertFalse(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: "lovr",
                textBeforeCursor: "Þátturinn Lovr"))
    }

    func testMissingRecordedTokenFailsClosed() {
        // A suggestion without the bridge's stamp is not ours to auto-apply.
        XCTAssertFalse(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: nil,
                textBeforeCursor: "Lovr"))
    }

    func testEmptyRecordedTokenNeverApplies() {
        // An autocorrect requires a pending word: an empty stamp means the
        // suggestion was produced at a word boundary (e.g. a stale bar
        // surviving into a mode-2 prediction insert) — never auto-apply,
        // even when the live token is also empty.
        XCTAssertFalse(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: "",
                textBeforeCursor: "Þátturinn "))
        XCTAssertFalse(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: "",
                textBeforeCursor: ""))
    }

    func testCommittedWordNoLongerPendingIsSkipped() {
        // The word was already committed (window ends in a delimiter):
        // the live pending token is empty, so the recorded token can no
        // longer be the token this delimiter commits.
        XCTAssertFalse(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: "Lovr",
                textBeforeCursor: "Þátturinn Lovr "))
    }

    func testDeferredDotTokenComparesWhole() {
        // '.'-deferral: at the delimiter after "teh." the session token is
        // "teh." (trailing deferred dot kept by splitCurrentWord), and the
        // bridge stamped exactly that. The guard must compare the WHOLE
        // token — KeyboardKit's own dot-sheared current word ("teh") would
        // spuriously mismatch.
        XCTAssertTrue(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: "teh.",
                textBeforeCursor: "hello teh."))
    }

    func testDottedTokenComparesWhole() {
        // Word-internal dots stay one session token ("additionalDeleteCount"
        // machinery); the guard uses the same boundary.
        XCTAssertTrue(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: "profilmynd.tilvinstri",
                textBeforeCursor: "sjá profilmynd.tilvinstri"))
        XCTAssertFalse(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: "profilmynd",
                textBeforeCursor: "sjá profilmynd.tilvinstri"))
    }

    func testUserGrewTheTokenPastTheSuggestionIsSkipped() {
        // Fast typing: the bar still holds the "Lov"-pass suggestion when
        // the delimiter lands after "Lovr" — one keystroke stale, skip.
        XCTAssertFalse(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: "Lov",
                textBeforeCursor: "Þátturinn Lovr"))
    }

    func testTokenAtStartOfTextApplies() {
        XCTAssertTrue(
            AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: "Lovr",
                textBeforeCursor: "Lovr"))
    }

    // MARK: - isSupersededResult

    func testLatestRequestIsNeverSuperseded() {
        XCTAssertFalse(
            AutocorrectApplyGuard.isSupersededResult(
                requestGeneration: 7, requestText: "Lovr",
                latestGeneration: 7, latestText: "Lovr"))
    }

    func testOlderRequestForDifferentTextIsSuperseded() {
        XCTAssertTrue(
            AutocorrectApplyGuard.isSupersededResult(
                requestGeneration: 7, requestText: "Þatturinn",
                latestGeneration: 13, latestText: "Þátturinn Lovr"))
    }

    func testNewerRequestForSameTextDoesNotSupersede() {
        // Republishing identical input's result is harmless; don't drop.
        XCTAssertFalse(
            AutocorrectApplyGuard.isSupersededResult(
                requestGeneration: 7, requestText: "Lovr",
                latestGeneration: 8, latestText: "Lovr"))
    }
}
