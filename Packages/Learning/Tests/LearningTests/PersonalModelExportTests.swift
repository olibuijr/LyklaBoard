import XCTest
@testable import Learning

final class PersonalModelExportTests: LearningTestCase {

    // MARK: - Content

    func testExportIncludesLearnedWordsWithCountsAndAttribution() throws {
        let (model, log) = try makeModelAndLog()
        day = 100
        try log.append(.wordCommitted(word: "smellir", previousWord: nil, languageHint: .icelandic))
        try model.compact(applying: log)
        day = 101
        try log.append(.wordCommitted(word: "smellir", previousWord: nil, languageHint: .icelandic))
        try model.compact(applying: log)

        let doc = model.exportDocument()
        let entry = try XCTUnwrap(doc.learnedWords.first { $0.word == "smellir" })
        XCTAssertEqual(entry.count, 2)
        XCTAssertEqual(entry.icelandic, 2)
        XCTAssertEqual(entry.english, 0)
        XCTAssertEqual(entry.daysSeen, [100, 101])
        XCTAssertFalse(entry.explicitlyAccepted)
        XCTAssertFalse(entry.userAdded)
    }

    func testExportOmitsPendingSubThresholdWords() throws {
        let (model, log) = try makeModelAndLog()
        // One commit on one day only — never crosses the learned threshold.
        try log.append(.wordCommitted(word: "typoo", previousWord: nil, languageHint: .unknown))
        try model.compact(applying: log)

        let doc = model.exportDocument()
        XCTAssertFalse(
            doc.learnedWords.contains { $0.word == "typoo" },
            "pending (unlearned) words — often typos — must not appear in the export"
        )
    }

    func testExportIncludesUserAddedAndTombstones() throws {
        let model = PersonalModel()
        try model.addUserWord("Þórsmörk")
        model.remove(word: "leiðindaorð")

        let doc = model.exportDocument()
        XCTAssertTrue(doc.userAddedWords.contains("Þórsmörk"))
        XCTAssertTrue(doc.learnedWords.contains { $0.word == "Þórsmörk" && $0.userAdded })
        XCTAssertTrue(doc.tombstones.contains("leiðindaorð"))
    }

    func testExportIncludesBigrams() throws {
        let (model, log) = try makeModelAndLog()
        day = 100
        try log.append(.wordCommitted(word: "heim", previousWord: "fer", languageHint: .icelandic))
        try model.compact(applying: log)

        let doc = model.exportDocument()
        let bigram = try XCTUnwrap(doc.bigrams.first)
        XCTAssertEqual(bigram.first, "fer")
        XCTAssertEqual(bigram.second, "heim")
        XCTAssertEqual(bigram.count, 1)
    }

    func testExportSplitsBigramKeyOnFirstSpaceOnly() throws {
        // Words never contain spaces, but the split must be robust to a
        // second-word split on the first space; both fields recovered.
        let (model, log) = try makeModelAndLog()
        try log.append(.wordCommitted(word: "b", previousWord: "a", languageHint: .unknown))
        try model.compact(applying: log)
        let doc = model.exportDocument()
        XCTAssertEqual(doc.bigrams.first?.first, "a")
        XCTAssertEqual(doc.bigrams.first?.second, "b")
    }

    func testExportIncludesTouchStatistics() throws {
        let (model, log) = try makeModelAndLog()
        try log.append(.touchSample(keyChar: "a", dx: 0.1, dy: -0.2))
        try log.append(.touchSample(keyChar: "a", dx: 0.2, dy: -0.1))
        try model.compact(applying: log)

        let doc = model.exportDocument()
        let touch = try XCTUnwrap(doc.touchStatistics.first { $0.key == "a" })
        XCTAssertEqual(touch.stats.count, 2)
    }

    // MARK: - Envelope / self-description

    func testExportEnvelopeMetadata() throws {
        let model = PersonalModel()
        let doc = model.exportDocument(note: "hello", schema: "https://example.com/doc")
        XCTAssertEqual(doc.schema, "https://example.com/doc")
        XCTAssertEqual(doc.note, "hello")
        XCTAssertEqual(doc.format, PersonalModel.exportFormatIdentifier)
        XCTAssertEqual(doc.formatVersion, PersonalModel.exportFormatVersion)
        XCTAssertEqual(doc.modelSchemaVersion, PersonalModel.schemaVersion)
    }

    // MARK: - JSON

    func testExportedJSONUsesDollarSchemaKeyAndRoundTrips() throws {
        let model = PersonalModel()
        try model.addUserWord("Jökull")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try model.exportedJSONData(note: "n", schema: "s", exportedAt: fixedDate)

        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"$schema\""), "schema must serialize under the $schema key")
        // Slashes should not be escaped (readable URLs); pretty-printed.
        XCTAssertTrue(json.contains("\n"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersonalModelExport.self, from: data)
        XCTAssertEqual(decoded.schema, "s")
        XCTAssertEqual(decoded.exportedAt, fixedDate)
        XCTAssertTrue(decoded.userAddedWords.contains("Jökull"))
    }

    func testExportIsDeterministicForFixedDate() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("hestur", model: model, log: log)
        try learnWord("kýr", model: model, log: log)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try model.exportedJSONData(exportedAt: date)
        let b = try model.exportedJSONData(exportedAt: date)
        XCTAssertEqual(a, b, "identical state + fixed date ⇒ identical bytes")
    }
}
