import XCTest

@testable import TypeEngine

final class TypingSessionTests: XCTestCase {

    private func session() -> TypingSession {
        TypingSession(engine: Fixtures.engine())
    }

    /// Feed text character-by-character, like keystrokes coming through the
    /// proxy, returning the suggestions from the final keystroke.
    @discardableResult
    private func typeThrough(
        _ session: TypingSession, _ text: String, limit: Int = 3
    ) -> [Suggestion] {
        var result: [Suggestion] = []
        var buffer = ""
        for ch in text {
            buffer.append(ch)
            result = session.suggestions(for: buffer, limit: limit)
        }
        return result
    }

    // MARK: - splitCurrentWord

    func testSplitCurrentWordWithNoDelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "hest")
        XCTAssertEqual(context, "")
        XCTAssertEqual(word, "hest")
    }

    func testSplitCurrentWordAfterSpace() {
        let (context, word) = TypingSession.splitCurrentWord(of: "góðan d")
        XCTAssertEqual(context, "góðan ")
        XCTAssertEqual(word, "d")
    }

    func testSplitCurrentWordWithTrailingDelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "hestur ")
        XCTAssertEqual(context, "hestur ")
        XCTAssertEqual(word, "")
    }

    func testSplitCurrentWordTreatsPunctuationAsDelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "já,nei")
        XCTAssertEqual(context, "já,")
        XCTAssertEqual(word, "nei")
    }

    func testApostropheIsNotADelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "she don't")
        XCTAssertEqual(context, "she ")
        XCTAssertEqual(word, "don't")
    }

    func testTypographicApostropheIsNotADelimiter() {
        // iOS smart punctuation inserts U+2019, not the straight apostrophe.
        let (context, word) = TypingSession.splitCurrentWord(of: "she don’t")
        XCTAssertEqual(context, "she ")
        XCTAssertEqual(word, "don’t")
    }

    func testHyphenIsNotADelimiter() {
        let (_, word) = TypingSession.splitCurrentWord(of: "vel-þekkt")
        XCTAssertEqual(word, "vel-þekkt")
    }

    func testNewlineIsADelimiter() {
        let (context, word) = TypingSession.splitCurrentWord(of: "halló\nheim")
        XCTAssertEqual(context, "halló\n")
        XCTAssertEqual(word, "heim")
    }

    func testLastWordStripsDelimiters() {
        XCTAssertEqual(TypingSession.lastWord(in: "fara í búð, "), "búð")
        XCTAssertEqual(TypingSession.lastWord(in: "hestur."), "hestur")
        XCTAssertNil(TypingSession.lastWord(in: "  ,. "))
        XCTAssertNil(TypingSession.lastWord(in: ""))
    }

    // MARK: - Completion gate

    func testSingleCharacterYieldsNoSuggestions() {
        XCTAssertTrue(session().suggestions(for: "h").isEmpty)
    }

    func testTwoCharactersYieldSuggestions() {
        XCTAssertFalse(session().suggestions(for: "he").isEmpty)
    }

    func testEmptyTextYieldsNextWordPredictions() {
        // Empty current word is prediction, not completion; not gated.
        XCTAssertFalse(session().suggestions(for: "").isEmpty)
    }

    func testGateAppliesToCurrentWordNotWholeText() {
        // 1-char *current word* after committed context is still gated.
        let s = session()
        typeThrough(s, "góðan d")
        XCTAssertTrue(s.suggestions(for: "góðan d").isEmpty)
    }

    // MARK: - Commit detection

    func testTypingSpaceCommitsWordAndUpdatesPosterior() {
        let s = session()
        typeThrough(s, "the ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "the")
        XCTAssertLessThan(s.probabilityIcelandic, 0.5)
        XCTAssertEqual(s.posteriorUpdateCount, 1)
    }

    func testCommittedWordIsReadFromContextNotTypedFragment() {
        // Autocorrect flow: the user typed "teh", KeyboardKit replaced it
        // with "the" and inserted a space; the session must confirm "the".
        let s = session()
        typeThrough(s, "teh")
        s.suggestions(for: "the ")
        XCTAssertEqual(s.lastCommittedWord, "the")
        XCTAssertLessThan(s.probabilityIcelandic, 0.5)
    }

    func testDoubleSpaceCommitsOnlyOnce() {
        let s = session()
        typeThrough(s, "the  ")
        XCTAssertEqual(s.committedWordCount, 1)
    }

    func testCommaCommitsWord() {
        let s = session()
        typeThrough(s, "hestur,")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "hestur")
        XCTAssertGreaterThan(s.probabilityIcelandic, 0.5)
    }

    func testUnknownWordCommitDoesNotMovePosterior() {
        let s = session()
        typeThrough(s, "zzzqqq ")
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.posteriorUpdateCount, 0)
        XCTAssertEqual(s.probabilityIcelandic, 0.5)
    }

    func testOnlyTrailingWordOfContextIsCommitted() {
        let s = session()
        typeThrough(s, "og hestur ")
        // "og" commits at the first space, "hestur" at the second.
        XCTAssertEqual(s.committedWordCount, 2)
        XCTAssertEqual(s.lastCommittedWord, "hestur")
    }

    // MARK: - External text changes (cursor jumps, host mutation)

    func testExternalChangeNotePreventsSpuriousCommit() {
        let s = session()
        typeThrough(s, "hestur bor")
        XCTAssertEqual(s.committedWordCount, 1)
        // Cursor jumps to just after "hestur " — new window ends with a
        // delimiter, which would look like a word commit without the note.
        s.noteExternalTextChange()
        s.suggestions(for: "hestur ")
        XCTAssertEqual(s.committedWordCount, 1, "cursor jump must not commit")
    }

    func testCursorJumpIsDetectedInternallyWithoutNote() {
        // Even with NO noteExternalTextChange call, the session's window-
        // change classifier must not misread a cursor jump (word-in-progress
        // vanishing from the window without new text) as a word commit.
        let s = session()
        typeThrough(s, "hestur bor")
        s.suggestions(for: "hestur ")
        XCTAssertEqual(s.committedWordCount, 1, "cursor jump misread as commit")
    }

    func testBackspacingAwayWordInProgressDoesNotRecommit() {
        // "hestur " committed once; starting a word and deleting it again
        // must not re-commit "hestur" (old quirk: prevWord nonempty + word
        // empty was treated as a commit even when nothing was added).
        let s = session()
        typeThrough(s, "hestur b")
        XCTAssertEqual(s.committedWordCount, 1)
        s.suggestions(for: "hestur ")  // backspace deleted the "b"
        XCTAssertEqual(s.committedWordCount, 1, "backspace must not re-commit")
    }

    func testHostMultiWordChangeWithoutNoteIsNotCommitted() {
        // A change that introduces several words at once is a host paste/
        // autofill, not a user keystroke — no commit even without the note.
        let s = session()
        typeThrough(s, "hest")
        s.suggestions(for: "completely different ")
        XCTAssertEqual(s.committedWordCount, 0)
    }

    func testSlidingTruncatedWindowStillCommits() {
        // Length-capped proxy window: the front chars fall away while
        // typing. The session must still detect the commit.
        let s = session()
        s.suggestions(for: "stur borð")
        s.suggestions(for: "stur borða")
        s.suggestions(for: "tur borða ")  // window slid by one + space
        XCTAssertEqual(s.committedWordCount, 1)
        XCTAssertEqual(s.lastCommittedWord, "borða")
    }

    // MARK: - Window-aware external-change note (extension forwarding)

    func testWindowNoteIsIgnoredForOwnEdits() {
        // textDidChange fires after our own insertions too; forwarding the
        // (new) window must not reset the pending word.
        let s = session()
        typeThrough(s, "teh")
        s.noteExternalTextChange(window: "teh")  // same window: no-op
        s.noteExternalTextChange(window: "the ")  // valid evolution: no-op
        s.suggestions(for: "the ")
        XCTAssertEqual(s.committedWordCount, 1, "note must not swallow the commit")
        XCTAssertEqual(s.lastCommittedWord, "the")
    }

    func testWindowNoteClearsOnInconsistentWindow() {
        let s = session()
        typeThrough(s, "hestur bor")
        // Cursor jumped somewhere unrelated: window not a typing evolution.
        s.noteExternalTextChange(window: "annar texti allt")
        s.suggestions(for: "hestur ")
        XCTAssertEqual(s.committedWordCount, 1, "note should have cleared pending word")
    }

    // MARK: - Sentence-truncation bigram-context carry

    func testSentenceTruncationCarriesBigramContext() {
        // The iOS proxy cuts the before-window at ". "; the words are still
        // on screen, so the first word of the new sentence should keep
        // bigram context ("góðan" -> "dag" in the fixtures).
        let s = session()
        typeThrough(s, "góðan.")
        XCTAssertEqual(s.lastCommittedWord, "góðan")
        let predictions = s.suggestions(for: "")  // proxy sentence cut
        XCTAssertEqual(predictions.first?.text, "dag", "carried bigram context should rank dag first")
    }

    func testTruncationCarryDoesNotSurviveExternalChange() {
        let s = session()
        typeThrough(s, "góðan.")
        s.suggestions(for: "")
        s.noteExternalTextChange()  // cursor jump
        let predictions = s.suggestions(for: "")
        XCTAssertNotEqual(predictions.first?.text, "dag", "carry must not survive external changes")
    }

    func testBackspaceToEmptyDoesNotCarryContext() {
        // Deleting everything is not a sentence cut: no terminator in the
        // pre-collapse window, so no carried context.
        let s = session()
        typeThrough(s, "góðan dag")
        s.suggestions(for: "góðan ")
        s.suggestions(for: "góðan")
        s.suggestions(for: "góða")
        s.suggestions(for: "gó")
        s.suggestions(for: "g")
        let predictions = s.suggestions(for: "")
        XCTAssertNotEqual(predictions.first?.text, "dag")
    }

    // MARK: - Sentence-boundary lane decay

    func testSentenceTerminatorDecaysLaneTowardNeutral() {
        // Same words, one committed by ". " instead of " ": the sentence
        // boundary must shed laneBoundaryDecay of the distance to 0.5 —
        // relax, not reset.
        let spaceSession = session()
        typeThrough(spaceSession, "og að er ")
        let boundarySession = session()
        typeThrough(boundarySession, "og að er. ")
        let d = boundarySession.engine.config.laneBoundaryDecay
        XCTAssertEqual(
            boundarySession.probabilityIcelandic,
            0.5 + (spaceSession.probabilityIcelandic - 0.5) * (1 - d),
            accuracy: 1e-9
        )
        XCTAssertGreaterThan(boundarySession.probabilityIcelandic, 0.6, "lane must survive the boundary")
    }

    func testCommaDoesNotDecayLane() {
        let spaceSession = session()
        typeThrough(spaceSession, "og að er ")
        let commaSession = session()
        typeThrough(commaSession, "og að er, ")
        XCTAssertEqual(
            commaSession.probabilityIcelandic,
            spaceSession.probabilityIcelandic,
            accuracy: 1e-9,
            "only sentence terminators decay the lane"
        )
    }

    // MARK: - Reset

    func testResetClearsPosteriorAndCounters() {
        let s = session()
        typeThrough(s, "the and ")
        XCTAssertNotEqual(s.probabilityIcelandic, 0.5)
        s.reset()
        XCTAssertEqual(s.probabilityIcelandic, 0.5)
        XCTAssertEqual(s.committedWordCount, 0)
        XCTAssertEqual(s.posteriorUpdateCount, 0)
        XCTAssertNil(s.lastCommittedWord)
    }
}
