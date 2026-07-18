import Foundation
import XCTest

@testable import TypeEngine

final class AutocompleteRequestSequencerTests: XCTestCase {

    func testLatestDifferentTextSupersedesOlderTicket() {
        let sequencer = AutocompleteRequestSequencer()
        let old = sequencer.accept(text: "teh")
        let latest = sequencer.accept(text: "tehx")

        XCTAssertTrue(sequencer.isSuperseded(old))
        XCTAssertFalse(sequencer.isSuperseded(latest))
    }

    func testRepeatedIdenticalTextDoesNotSupersede() {
        let sequencer = AutocompleteRequestSequencer()
        let first = sequencer.accept(text: "teh")
        let second = sequencer.accept(text: "teh")

        XCTAssertFalse(sequencer.isSuperseded(first))
        XCTAssertFalse(sequencer.isSuperseded(second))
    }

    func testConcurrentAcceptanceIssuesUniqueGenerations() {
        let sequencer = AutocompleteRequestSequencer()
        let resultLock = NSLock()
        var generations: [UInt64] = []

        DispatchQueue.concurrentPerform(iterations: 128) { index in
            let ticket = sequencer.accept(text: "window-\(index)")
            resultLock.lock()
            generations.append(ticket.generation)
            resultLock.unlock()
        }

        XCTAssertEqual(Set(generations).count, 128)
        XCTAssertEqual(generations.min(), 1)
        XCTAssertEqual(generations.max(), 128)
    }
}
