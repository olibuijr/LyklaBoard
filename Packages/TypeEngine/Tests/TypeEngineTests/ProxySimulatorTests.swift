import XCTest

@testable import TypeEngine

final class ProxySimulatorTests: XCTestCase {

    // MARK: - Basic editing

    func testInsertAndContextWindows() {
        let proxy = ProxySimulator()
        proxy.insertText("halló ")
        proxy.insertText("heimur")
        XCTAssertEqual(proxy.document, "halló heimur")
        XCTAssertEqual(proxy.contextBeforeInput, "halló heimur")
        XCTAssertEqual(proxy.contextAfterInput, "")
    }

    func testInsertAtCursorMidDocument() {
        let proxy = ProxySimulator(document: "ab", cursorAt: 1)
        proxy.insertText("X")
        XCTAssertEqual(proxy.document, "aXb")
        XCTAssertEqual(proxy.contextBeforeInput, "aX")
        XCTAssertEqual(proxy.contextAfterInput, "b")
    }

    func testDeleteBackward() {
        let proxy = ProxySimulator(document: "abc")
        proxy.deleteBackward()
        XCTAssertEqual(proxy.document, "ab")
        proxy.moveCursor(to: 0)
        proxy.deleteBackward()  // at start: no-op
        XCTAssertEqual(proxy.document, "ab")
    }

    // MARK: - Cursor and host mutation

    func testMoveCursorClampsToBounds() {
        let proxy = ProxySimulator(document: "abc")
        proxy.moveCursor(to: 99)
        XCTAssertEqual(proxy.cursor, 3)
        proxy.moveCursor(by: -99)
        XCTAssertEqual(proxy.cursor, 0)
    }

    func testHostReplaceTextMovesCursorToEndByDefault() {
        let proxy = ProxySimulator(document: "old")
        proxy.hostReplaceText("brand new")
        XCTAssertEqual(proxy.document, "brand new")
        XCTAssertEqual(proxy.cursor, 9)
        XCTAssertEqual(proxy.contextBeforeInput, "brand new")
    }

    // MARK: - Truncation

    func testSentenceBoundaryTruncation() {
        let proxy = ProxySimulator(document: "Fyrsta setning. önnur setning hér")
        XCTAssertEqual(proxy.contextBeforeInput, "önnur setning hér")
    }

    func testNewlineTruncation() {
        let proxy = ProxySimulator(document: "lína eitt\nlína tvö")
        XCTAssertEqual(proxy.contextBeforeInput, "lína tvö")
    }

    func testPeriodWithoutSpaceDoesNotTruncate() {
        let proxy = ProxySimulator(document: "jokull@triptojapan.com er")
        XCTAssertEqual(proxy.contextBeforeInput, "jokull@triptojapan.com er")
    }

    func testMaxLengthCap() {
        let proxy = ProxySimulator(
            document: "hestur borða koma",
            truncation: .init(maxBeforeLength: 10)
        )
        XCTAssertEqual(proxy.contextBeforeInput, "borða koma")
    }

    func testNoTruncationPolicy() {
        let proxy = ProxySimulator(
            document: "Fyrsta setning. önnur",
            truncation: .none
        )
        XCTAssertEqual(proxy.contextBeforeInput, "Fyrsta setning. önnur")
    }

    func testCustomPolicyWins() {
        let proxy = ProxySimulator(
            document: "whatever text",
            truncation: .init(custom: { String($0.suffix(4)) })
        )
        XCTAssertEqual(proxy.contextBeforeInput, "text")
    }

    // MARK: - Stale reads

    func testStaleReadReturnsPreEditStateOnce() {
        let proxy = ProxySimulator(document: "ab")
        proxy.staleReads = true
        proxy.insertText("c")
        XCTAssertEqual(proxy.contextBeforeInput, "ab", "first read after edit is stale")
        XCTAssertEqual(proxy.contextBeforeInput, "abc", "second read is fresh")
    }

    func testStaleReadsOffByDefault() {
        let proxy = ProxySimulator(document: "ab")
        proxy.insertText("c")
        XCTAssertEqual(proxy.contextBeforeInput, "abc")
    }

    func testCursorMoveClearsPendingStaleSnapshot() {
        let proxy = ProxySimulator(document: "ab")
        proxy.staleReads = true
        proxy.insertText("c")
        proxy.moveCursor(to: 1)
        XCTAssertEqual(proxy.contextBeforeInput, "a")
    }
}
