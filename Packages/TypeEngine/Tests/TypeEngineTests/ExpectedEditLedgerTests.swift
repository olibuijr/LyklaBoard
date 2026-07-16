import XCTest

@testable import TypeEngine

/// Unit tests for the proxy-edit ledger (azooKey `ExpectedEditTracker`
/// pattern, research/oss-harvest.md §2) — the direct record/match/expiry
/// mechanics, then its integration into `TypingSession`'s window
/// classification. The end-to-end acceptance cases (stale hosts, swallowed
/// edits, interleaved externals, mode-2 inserts) additionally run through
/// the `type-repl` scenario suite (`Scenarios/core.scenarios`, "Proxy-edit
/// ledger" section), which drives the identical instrumented path the
/// keyboard extension uses.
final class ExpectedEditLedgerTests: XCTestCase {

    // MARK: - Ledger mechanics

    func testMatchedObservationConsumesTheRecord() {
        var ledger = ExpectedEditLedger()
        ledger.record(before: "hest", after: "hestu", anchor: "hest")
        XCTAssertEqual(ledger.explain(observed: "hestu", anchor: "hest"), .matched)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testNoOpEditIsNeverRecorded() {
        var ledger = ExpectedEditLedger()
        ledger.record(before: "hest", after: "hest", anchor: "hest")
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertEqual(ledger.explain(observed: "hest", anchor: "hest"), .noRecords)
    }

    func testBackToBackEditsConfirmAtTheLatestChainPoint() {
        // Several edits before one observation (fast typing / one keystroke
        // doing revert + apply + insert as separate records): the single
        // observation of the final state consumes the whole chain.
        var ledger = ExpectedEditLedger()
        ledger.record(before: "a", after: "ab", anchor: "a")
        ledger.record(before: "ab", after: "abc", anchor: "a")
        ledger.record(before: "abc", after: "abcd", anchor: "a")
        XCTAssertEqual(ledger.explain(observed: "abcd", anchor: "a"), .matched)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testIntermediateMatchKeepsLaterRecordsPending() {
        // A stale observation confirms only the first edit; the second
        // stays pending and confirms on the next observation.
        var ledger = ExpectedEditLedger()
        ledger.record(before: "a", after: "ab", anchor: "a")
        ledger.record(before: "ab", after: "abc", anchor: "a")
        XCTAssertEqual(ledger.explain(observed: "ab", anchor: "a"), .matched)
        XCTAssertFalse(ledger.isEmpty)
        XCTAssertEqual(ledger.explain(observed: "abc", anchor: "ab"), .matched)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testStaleObservationLeavesTheRecordPending() {
        var ledger = ExpectedEditLedger()
        ledger.record(before: "hest", after: "hestu", anchor: "hest")
        XCTAssertEqual(ledger.explain(observed: "hest", anchor: "hest"), .stale)
        XCTAssertFalse(ledger.isEmpty)
        XCTAssertEqual(ledger.explain(observed: "hestu", anchor: "hest"), .matched)
    }

    func testUnconfirmedRecordExpiresAfterThreeObservations() {
        var ledger = ExpectedEditLedger()
        ledger.record(before: "hest", after: "hestu", anchor: "hest")
        XCTAssertEqual(ledger.explain(observed: "hest", anchor: "hest"), .stale)
        XCTAssertEqual(ledger.explain(observed: "hest", anchor: "hest"), .stale)
        XCTAssertEqual(ledger.explain(observed: "hest", anchor: "hest"), .stale)
        // Third stale observation reached the expiry: the chain is dropped.
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertEqual(ledger.explain(observed: "hest", anchor: "hest"), .noRecords)
    }

    func testUnexplainedObservationClearsTheLedger() {
        var ledger = ExpectedEditLedger()
        ledger.record(before: "hest", after: "hestu", anchor: "hest")
        XCTAssertEqual(
            ledger.explain(observed: "something else", anchor: "hest"), .unexplained)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testAnchorDriftIsUnexplained() {
        // The oldest pending edit does not start from the window the
        // session last observed: the world moved in between.
        var ledger = ExpectedEditLedger()
        ledger.record(before: "hest", after: "hestu", anchor: nil)
        XCTAssertEqual(
            ledger.explain(observed: "hestu", anchor: "other window"), .unexplained)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testChainBreakAtRecordTimeCondemnsTheNextObservation() {
        // An external mutation slipped between our own edits: the second
        // record's before does not chain onto the first record's after.
        var ledger = ExpectedEditLedger()
        ledger.record(before: "hest", after: "hestu", anchor: "hest")
        ledger.record(before: "swapped by host", after: "swapped by hostx", anchor: "hest")
        XCTAssertEqual(
            ledger.explain(observed: "swapped by hostx", anchor: "hest"), .unexplained)
        // One-shot: the flag clears with the condemned observation.
        XCTAssertTrue(ledger.isEmpty)
    }

    func testRetroConfirmedRecordIsDropped() {
        // Device timing race: the observation for an edit was processed
        // BEFORE the record landed (the record's after IS the anchor).
        // Recording it must not poison the chain.
        var ledger = ExpectedEditLedger()
        ledger.record(before: "hest", after: "hestu", anchor: "hestu")
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertEqual(ledger.explain(observed: "hestur", anchor: "hestu"), .noRecords)
    }

    func testCapacityOverflowDegradesConservatively() {
        var ledger = ExpectedEditLedger()
        var window = ""
        for _ in 0..<(ExpectedEditLedger.capacity + 1) {
            let next = window + "x"
            ledger.record(before: window, after: next, anchor: nil)
            window = next
        }
        // The overflowing record condemned the chain: one external, then a
        // clean slate.
        XCTAssertEqual(ledger.explain(observed: window, anchor: nil), .unexplained)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testWouldExplainDoesNotConsume() {
        var ledger = ExpectedEditLedger()
        ledger.record(before: "hest", after: "hestu", anchor: "hest")
        XCTAssertTrue(ledger.wouldExplain(observed: "hestu", anchor: "hest"))
        XCTAssertTrue(ledger.wouldExplain(observed: "hest", anchor: "hest"))  // stale shape
        XCTAssertFalse(ledger.wouldExplain(observed: "other", anchor: "hest"))
        // Still pending: the real observation gets the exact match.
        XCTAssertFalse(ledger.isEmpty)
        XCTAssertEqual(ledger.explain(observed: "hestu", anchor: "hest"), .matched)
    }

    // MARK: - TypingSession integration

    private func session() -> TypingSession {
        TypingSession(engine: Fixtures.engine())
    }

    /// Type text keystroke-by-keystroke WITH ledger instrumentation — the
    /// exact embedder contract (extension action handler / harness Typist):
    /// record the self-edit, then observe.
    @discardableResult
    private func typeInstrumented(
        _ session: TypingSession, from start: String = "", _ text: String
    ) -> String {
        var window = start
        for ch in text {
            let after = window + String(ch)
            session.noteSelfEdit(before: window, after: after)
            session.suggestions(for: after)
            window = after
        }
        return window
    }

    func testInstrumentedTypingCommitsExactlyLikeHeuristicTyping() {
        let s = session()
        typeInstrumented(s, "hestur borða ")
        XCTAssertEqual(s.committedWordCount, 2)
        XCTAssertEqual(s.lastCommittedWord, "borða")
        XCTAssertGreaterThan(s.probabilityIcelandic, 0.5)
    }

    func testHostCompletingThePendingWordIsCreditedOnlyByHeuristics() {
        // THE case the ledger exists for (research/oss-harvest.md §2): a
        // host mutation that happens to look like a valid typing evolution.
        // "hest" pending; the host (autofill/IME) silently completes it to
        // "hestur ". The un-instrumented heuristic classifier is fooled and
        // credits a commit; the instrumented session knows it issued no
        // such edit and classifies external.
        let heuristic = session()
        typeThrough(heuristic, "hest")
        heuristic.suggestions(for: "hestur ")
        XCTAssertEqual(
            heuristic.committedWordCount, 1,
            "documents the heuristic limitation the ledger removes")

        let instrumented = session()
        typeInstrumented(instrumented, "hest")
        instrumented.suggestions(for: "hestur ")  // no matching self-edit
        XCTAssertEqual(
            instrumented.committedWordCount, 0,
            "unexplained window change must be external, never a commit")
    }

    func testSelfEditConfirmedLateStillCommits() {
        // Stale proxy: the observation after the space keystroke still
        // shows the pre-space window; the next observation confirms the
        // recorded edit and the commit lands late but intact.
        let s = session()
        let window = typeInstrumented(s, "hestur")
        s.noteSelfEdit(before: window, after: window + " ")
        s.suggestions(for: window)  // stale read: pre-edit state
        XCTAssertEqual(s.committedWordCount, 0)
        s.suggestions(for: window + " ")  // the edit confirms
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "hestur")
    }

    func testSwallowedSelfEditExpiresAndTypingRecovers() {
        // The host swallowed our edit: the expectation never confirms and
        // expires after three observations; heuristic classification then
        // resumes and typing from the host's real state works normally.
        let s = session()
        typeInstrumented(s, "hest")
        s.noteSelfEdit(before: "hest", after: "hestu")  // swallowed by host
        for _ in 0..<3 {
            s.suggestions(for: "hest")  // observations keep the pre-edit state
        }
        XCTAssertEqual(s.committedWordCount, 0)
        // Recovered: instrumented typing continues from the real window.
        typeInstrumented(s, from: "hest", "ur ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "hestur")
    }

    func testUnrecordedChangedWindowIsExternalForInstrumentedEmbedders() {
        // Once an embedder records self-edits, a changed window with NO
        // pending expectation is external by definition — even a
        // single-word append that heuristics would credit.
        let s = session()
        typeInstrumented(s, "hestur borða")
        XCTAssertEqual(s.committedWordCount, 1)
        s.suggestions(for: "hestur borða takk ")  // nobody recorded this
        XCTAssertEqual(s.committedWordCount, 1, "unrecorded append must not commit")
    }

    func testWindowNotePeeksWithoutConsumingTheExpectation() {
        // The extension forwards textDidChange BEFORE the autocomplete pass
        // sometimes; the note must recognize the pending expectation as
        // self-caused (no reset) and leave it for the observation, which
        // still gets the exact match and the commit.
        let s = session()
        let window = typeInstrumented(s, "hestur")
        s.noteSelfEdit(before: window, after: window + " ")
        s.noteExternalTextChange(window: window + " ")  // must be a no-op
        s.suggestions(for: window + " ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "hestur")
    }

    func testInterleavedExternalBetweenOwnEditsResetsState() {
        // Host mutates the document between two of our edits (record-time
        // chain break): the next observation is external — no commit, and
        // the new window is adopted.
        let s = session()
        typeInstrumented(s, "hest")
        s.noteSelfEdit(before: "allt annad", after: "allt annadx")  // world moved
        s.suggestions(for: "allt annadx")
        XCTAssertEqual(s.committedWordCount, 0)
        // Adopted: instrumented typing continues on the new window.
        typeInstrumented(s, from: "allt annadx", " takk ")
        XCTAssertEqual(s.lastCommittedWord, "takk")
    }

    func testResetReturnsTheSessionToHeuristicClassification() {
        let s = session()
        typeInstrumented(s, "hest ")
        XCTAssertEqual(s.committedWordCount, 1)
        s.reset()
        // Un-instrumented (heuristic) typing must work again after reset.
        typeThrough(s, "hestur ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "hestur")
    }

    // MARK: - Helpers

    /// Heuristic-mode typing (no self-edit records) — the pre-ledger
    /// embedder contract, still supported.
    @discardableResult
    private func typeThrough(_ session: TypingSession, _ text: String) -> [Suggestion] {
        var result: [Suggestion] = []
        var buffer = ""
        for ch in text {
            buffer.append(ch)
            result = session.suggestions(for: buffer)
        }
        return result
    }
}
