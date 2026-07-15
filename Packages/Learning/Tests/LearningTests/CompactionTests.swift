import XCTest
@testable import Learning

final class CompactionTests: LearningTestCase {

    // MARK: - Consume-offset correctness

    func testDoubleCompactionDoesNotDoubleCount() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.wordCommitted(word: "hestur", previousWord: nil, languageHint: .icelandic))
        let first = try model.compact(applying: log)
        XCTAssertEqual(first.eventsApplied, 1)

        let second = try model.compact(applying: log)
        XCTAssertEqual(second.eventsApplied, 0, "already-consumed events must not re-apply")
        XCTAssertEqual(model.commitCount(of: "hestur"), 1)
    }

    func testCompactionOnlyConsumesEventsPresentAtRead() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.wordCommitted(word: "fyrsta", previousWord: nil, languageHint: .icelandic))
        try model.compact(applying: log)

        // Writer appends between compactions.
        try log.append(.wordCommitted(word: "annað", previousWord: nil, languageHint: .icelandic))
        try log.append(.wordCommitted(word: "þriðja", previousWord: nil, languageHint: .icelandic))
        let summary = try model.compact(applying: log)
        XCTAssertEqual(summary.eventsApplied, 2)
        XCTAssertEqual(model.commitCount(of: "fyrsta"), 1)
        XCTAssertEqual(model.commitCount(of: "annað"), 1)
    }

    func testCompactAndSaveWithConcurrentAppendSimulation() throws {
        let (model, log) = try makeModelAndLog()
        let modelURL = directory.appendingPathComponent("model.json")

        try log.append(.wordCommitted(word: "gamalt", previousWord: nil, languageHint: .icelandic))
        let summary = try model.compactAndSave(applying: log, to: modelURL)
        XCTAssertEqual(summary.eventsApplied, 1)
        XCTAssertTrue(summary.logTruncated)

        // Concurrent writer lands events; then a fresh model instance (app
        // relaunch) resumes from the persisted marker.
        try log.append(.wordCommitted(word: "nýtt", previousWord: nil, languageHint: .icelandic))
        let reloaded = try PersonalModel(contentsOf: modelURL)
        let resumed = try reloaded.compactAndSave(applying: log, to: modelURL)
        XCTAssertEqual(resumed.eventsApplied, 1, "only the concurrent append is unconsumed")
        XCTAssertEqual(reloaded.commitCount(of: "gamalt"), 1)
        XCTAssertEqual(reloaded.commitCount(of: "nýtt"), 1)
    }

    func testCrashBetweenSaveAndTruncateDoesNotDoubleCount() throws {
        let (model, log) = try makeModelAndLog()
        let modelURL = directory.appendingPathComponent("model.json")

        // Simulate the crash window: compact + save, but NO truncation.
        try log.append(.wordCommitted(word: "hestur", previousWord: nil, languageHint: .icelandic))
        try model.compact(applying: log)
        try model.save(to: modelURL)

        // Relaunch: same log file (old generation), marker persisted.
        let reloaded = try PersonalModel(contentsOf: modelURL)
        let summary = try reloaded.compactAndSave(applying: log, to: modelURL)
        XCTAssertEqual(summary.eventsApplied, 0)
        XCTAssertEqual(reloaded.commitCount(of: "hestur"), 1)
    }

    func testCrashAfterTruncateBeforeSecondSaveSelfHeals() throws {
        let (model, log) = try makeModelAndLog()
        let modelURL = directory.appendingPathComponent("model.json")

        try log.append(.wordCommitted(word: "hestur", previousWord: nil, languageHint: .icelandic))
        // Manual sequence simulating a crash right after truncate: the model
        // file on disk still holds the OLD generation marker.
        try model.compact(applying: log)
        try model.save(to: modelURL)
        try log.append(.wordCommitted(word: "nýtt", previousWord: nil, languageHint: .icelandic))
        _ = try log.truncate(consumedUpTo: try XCTUnwrap(model.consumedLogMarker))
        // (no second save — crash)

        let reloaded = try PersonalModel(contentsOf: modelURL)
        let summary = try reloaded.compactAndSave(applying: log, to: modelURL)
        XCTAssertEqual(summary.eventsApplied, 1, "generation mismatch re-reads only the unconsumed tail")
        XCTAssertEqual(reloaded.commitCount(of: "hestur"), 1)
        XCTAssertEqual(reloaded.commitCount(of: "nýtt"), 1)
    }

    // MARK: - Decay

    func testDecayHalvesCountsAndDropsZeroEntries() throws {
        let config = PersonalModel.Configuration(decayTotalCountCeiling: 10, decayFactor: 0.5)
        let (model, log) = try makeModelAndLog(configuration: config)

        for _ in 0..<10 {
            try log.append(.wordCommitted(word: "algengt", previousWord: "mjög", languageHint: .icelandic))
        }
        try log.append(.wordCommitted(word: "sjaldgæft", previousWord: nil, languageHint: .icelandic))
        let summary = try model.compact(applying: log)
        XCTAssertTrue(summary.decayed, "total count 11 exceeds ceiling 10")
        XCTAssertEqual(model.commitCount(of: "algengt"), 5)
        XCTAssertEqual(model.commitCount(of: "sjaldgæft"), 0)
        XCTAssertNil(model.languageAttribution(of: "sjaldgæft"), "count-0 entries are dropped")
        XCTAssertEqual(model.bigramFrequency("mjög", "algengt"), 5, "bigrams decay alongside words")
    }

    func testDecayDoesNotRunBelowCeiling() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.wordCommitted(word: "orð", previousWord: nil, languageHint: .icelandic))
        let summary = try model.compact(applying: log)
        XCTAssertFalse(summary.decayed)
    }

    func testDecayPreservesExplicitAndUserAddedEntries() throws {
        let config = PersonalModel.Configuration(decayTotalCountCeiling: 10, decayFactor: 0.5)
        let (model, log) = try makeModelAndLog(configuration: config)
        try model.addUserWord("dýrmætt")

        try log.append(.wordTapped(word: "sérstakt"))  // explicit, count 1
        try log.append(.wordCommitted(word: "dýrmætt", previousWord: nil, languageHint: .icelandic))
        for _ in 0..<12 {
            try log.append(.wordCommitted(word: "fyllir", previousWord: nil, languageHint: .icelandic))
        }
        let summary = try model.compact(applying: log)
        XCTAssertTrue(summary.decayed)
        XCTAssertTrue(model.isLearned("sérstakt"), "explicit words survive decay to zero")
        XCTAssertTrue(model.isLearned("dýrmætt"), "user-added words survive decay to zero")
        XCTAssertEqual(model.frequency(of: "dýrmætt"), 1, "floor of 1 for user-added")
    }

    func testTombstonesSurviveDecayAndCompactions() throws {
        let config = PersonalModel.Configuration(decayTotalCountCeiling: 5, decayFactor: 0.5)
        let (model, log) = try makeModelAndLog(configuration: config)
        model.remove(word: "eytt")

        for _ in 0..<10 {
            try log.append(.wordCommitted(word: "fyllir", previousWord: nil, languageHint: .icelandic))
        }
        let summary = try model.compact(applying: log)
        XCTAssertTrue(summary.decayed)
        XCTAssertTrue(model.isTombstoned("eytt"), "decay never touches tombstones")
    }

    func testRelativeRankingPreservedAcrossDecay() throws {
        let config = PersonalModel.Configuration(decayTotalCountCeiling: 20, decayFactor: 0.5)
        let (model, log) = try makeModelAndLog(configuration: config)
        for _ in 0..<16 {
            try log.append(.wordCommitted(word: "efst", previousWord: nil, languageHint: .icelandic))
        }
        for _ in 0..<8 {
            try log.append(.wordCommitted(word: "miðja", previousWord: nil, languageHint: .icelandic))
        }
        try model.compact(applying: log)
        XCTAssertEqual(model.commitCount(of: "efst"), 8)
        XCTAssertEqual(model.commitCount(of: "miðja"), 4)
        XCTAssertGreaterThan(model.commitCount(of: "efst"), model.commitCount(of: "miðja"))
    }

    // MARK: - Caps

    func testBigramCapKeepsTopByCount() throws {
        let config = PersonalModel.Configuration(bigramCap: 3)
        let (model, log) = try makeModelAndLog(configuration: config)
        let followers = ["aa", "bb", "cc", "dd", "ee"]
        for (index, follower) in followers.enumerated() {
            for _ in 0...(index) {  // ee gets 5 commits, aa gets 1
                try log.append(.wordCommitted(word: follower, previousWord: "orð", languageHint: .icelandic))
            }
        }
        try model.compact(applying: log)
        let continuations = model.continuations(of: "orð", limit: 10)
        XCTAssertEqual(continuations.map(\.word), ["ee", "dd", "cc"], "cap keeps highest-count bigrams")
        XCTAssertNil(model.bigramFrequency("orð", "aa"))
    }

    func testWordEntryCapEvictsLowestCountNonProtectedEntries() throws {
        let config = PersonalModel.Configuration(maxWordEntries: 3)
        let (model, log) = try makeModelAndLog(configuration: config)
        try model.addUserWord("varið")
        try log.append(.wordTapped(word: "sérstakt"))
        for _ in 0..<5 {
            try log.append(.wordCommitted(word: "algengt", previousWord: nil, languageHint: .icelandic))
        }
        try log.append(.wordCommitted(word: "sjaldgæft", previousWord: nil, languageHint: .icelandic))
        try log.append(.wordCommitted(word: "varið", previousWord: nil, languageHint: .icelandic))
        try model.compact(applying: log)

        XCTAssertEqual(model.commitCount(of: "sjaldgæft"), 0, "lowest-count unprotected entry evicted")
        XCTAssertEqual(model.commitCount(of: "algengt"), 5)
        XCTAssertTrue(model.isLearned("sérstakt"), "explicit entries never evicted")
        XCTAssertTrue(model.isLearned("varið"), "user-added entries never evicted")
    }

    // MARK: - Skipped lines surface in the summary

    func testCompactionReportsSkippedLines() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.wordCommitted(word: "orð", previousWord: nil, languageHint: .icelandic))
        let handle = try FileHandle(forWritingTo: log.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage line\n".utf8))
        try handle.close()

        let summary = try model.compact(applying: log)
        XCTAssertEqual(summary.eventsApplied, 1)
        XCTAssertEqual(summary.linesSkipped, 1)
    }
}
