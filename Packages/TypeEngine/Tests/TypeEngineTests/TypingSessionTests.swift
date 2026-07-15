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

    func testWithoutExternalChangeNoteCursorJumpCausesSpuriousCommit() {
        // Documents the hazard the extension currently has (it never calls
        // noteExternalTextChange): a cursor jump that removes the
        // word-in-progress from the window is misread as a commit.
        let s = session()
        typeThrough(s, "hestur bor")
        s.suggestions(for: "hestur ")
        XCTAssertEqual(s.committedWordCount, 2, "expected the documented spurious commit")
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
