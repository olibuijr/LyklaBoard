import Foundation
import XCTest

@testable import EvalKit
@testable import TypeEngine

final class PersonalEvalTests: XCTestCase {

    // MARK: - rowKey

    func testRowKeyLowercases() {
        XCTAssertEqual(PersonalEval.rowKey(typo: "Fair", intended: "Fáir"), "fair|fáir")
        XCTAssertEqual(
            PersonalEval.rowKey(typo: "Fair", intended: "Fáir"),
            PersonalEval.rowKey(typo: "fair", intended: "fáir"))
    }

    // MARK: - compare: regressions

    func testCompareFlagsTop1Regression() {
        let baseline = makeBaseline(rows: [
            "typo|intended": PersonalRowResult(top1: true, autocorrected: true, falseAc: false)
        ])
        let current: [String: PersonalRowResult] = [
            "typo|intended": PersonalRowResult(top1: false, autocorrected: true, falseAc: false)
        ]
        let report = PersonalEval.compare(current: current, baseline: baseline)
        XCTAssertFalse(report.pass)
        XCTAssertEqual(report.regressions.map(\.key), ["typo|intended"])
        XCTAssertTrue(report.regressions[0].detail.contains("top-1"))
    }

    func testCompareFlagsNewFalseAutocorrectOnExistingRow() {
        let baseline = makeBaseline(rows: [
            "typo|intended": PersonalRowResult(top1: true, autocorrected: false, falseAc: false)
        ])
        let current: [String: PersonalRowResult] = [
            "typo|intended": PersonalRowResult(top1: true, autocorrected: true, falseAc: true)
        ]
        let report = PersonalEval.compare(current: current, baseline: baseline)
        XCTAssertFalse(report.pass)
        XCTAssertEqual(report.regressions.map(\.key), ["typo|intended"])
    }

    func testCompareFlagsNewFalseAutocorrectOnBrandNewRow() {
        // A row with no baseline entry at all still gates on false-ac — this
        // is the "even new rows are held to it" clause (false-autocorrect is
        // the most-guarded metric).
        let baseline = makeBaseline(rows: [:])
        let current: [String: PersonalRowResult] = [
            "brandnew|word": PersonalRowResult(top1: false, autocorrected: true, falseAc: true)
        ]
        let report = PersonalEval.compare(current: current, baseline: baseline)
        XCTAssertFalse(report.pass)
        XCTAssertEqual(report.regressions.map(\.key), ["brandnew|word"])
        XCTAssertTrue(report.improvements.isEmpty, "a false-ac regression must not double as an improvement")
    }

    func testCompareDoesNotFlagPersistentFalseAc() {
        // A row that was ALREADY false-ac in the baseline is not a NEW
        // regression if it stays false-ac (no worse, no better).
        let baseline = makeBaseline(rows: [
            "typo|intended": PersonalRowResult(top1: false, autocorrected: true, falseAc: true)
        ])
        let current: [String: PersonalRowResult] = [
            "typo|intended": PersonalRowResult(top1: false, autocorrected: true, falseAc: true)
        ]
        let report = PersonalEval.compare(current: current, baseline: baseline)
        XCTAssertTrue(report.pass)
        XCTAssertTrue(report.regressions.isEmpty)
    }

    // MARK: - compare: improvements

    func testCompareListsNewRowAsImprovement() {
        let baseline = makeBaseline(rows: [:])
        let current: [String: PersonalRowResult] = [
            "typo|intended": PersonalRowResult(top1: true, autocorrected: true, falseAc: false)
        ]
        let report = PersonalEval.compare(current: current, baseline: baseline)
        XCTAssertTrue(report.pass)
        XCTAssertEqual(report.improvements.map(\.key), ["typo|intended"])
    }

    func testCompareListsNewlyPassingRowAsImprovement() {
        let baseline = makeBaseline(rows: [
            "typo|intended": PersonalRowResult(top1: false, autocorrected: false, falseAc: false)
        ])
        let current: [String: PersonalRowResult] = [
            "typo|intended": PersonalRowResult(top1: true, autocorrected: true, falseAc: false)
        ]
        let report = PersonalEval.compare(current: current, baseline: baseline)
        XCTAssertTrue(report.pass)
        XCTAssertEqual(report.improvements.map(\.key), ["typo|intended"])
    }

    func testCompareSkipsRowRemovedFromCurrentRun() {
        // A key present in the baseline but absent from the current run
        // (corpus hand-edited) is neither a regression nor an improvement —
        // nothing to compare.
        let baseline = makeBaseline(rows: [
            "gone|word": PersonalRowResult(top1: true, autocorrected: true, falseAc: false)
        ])
        let report = PersonalEval.compare(current: [:], baseline: baseline)
        XCTAssertTrue(report.pass)
        XCTAssertTrue(report.regressions.isEmpty)
        XCTAssertTrue(report.improvements.isEmpty)
    }

    // MARK: - PersonalBaseline Codable round-trip

    func testBaselineRoundTripsThroughJSON() throws {
        let baseline = makeBaseline(rows: [
            "typo|intended": PersonalRowResult(top1: true, autocorrected: false, falseAc: false)
        ])
        let data = try JSONEncoder().encode(baseline)
        let decoded = try JSONDecoder().decode(PersonalBaseline.self, from: data)
        XCTAssertEqual(decoded, baseline)
    }

    private func makeBaseline(rows: [String: PersonalRowResult]) -> PersonalBaseline {
        PersonalBaseline(
            engineCommit: "test-commit", timestamp: "2026-01-01T00:00:00Z", rows: rows,
            summary: PersonalSummary(n: rows.count))
    }

    // MARK: - ConfirmedIntents.loadIntentionalWords

    func testLoadIntentionalWordsFiltersToIntentionalRows() throws {
        let body = """
            # a comment header, same convention as .gitignore
            {"typo": "sivan", "intended": "síðan"}
            {"typo": "kozy", "intentional": true}

            {"typo": "notreally", "intentional": false}
            {"typo": "habb", "intended": "hann"}
            not even json
            """
        let url = tempFile(body)
        defer { try? FileManager.default.removeItem(at: url) }

        let words = try ConfirmedIntents.loadIntentionalWords(at: url)
        XCTAssertEqual(words, ["kozy"])
    }

    func testLoadIntentionalWordsEmptyFileReturnsEmpty() throws {
        let url = tempFile("# just a header\n")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try ConfirmedIntents.loadIntentionalWords(at: url), [])
    }

    // MARK: - ConfirmedIntents.check (intentional-assertion runner, fixture engine)

    func testCheckPassesForAWordAlreadyInTheLexicon() {
        // Fixture engine (DictLexicon doubles — never the real data/
        // artifacts or the real confirmed-intents.jsonl): a word that is
        // ALREADY the top valid entry can't plausibly be force-replaced by
        // itself, so the runner must report it as passing, unforced.
        let icelandic = DictLexicon(unigrams: ["kaffi": 500, "takk": 300, "og": 900])
        let english = DictLexicon(unigrams: ["the": 900, "and": 500])
        let engine = TypeEngine(icelandic: icelandic, english: english, morphologyProvider: nil)

        let results = ConfirmedIntents.check(engine: engine, words: ["kaffi"])
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].pass)
        XCTAssertNil(results[0].forcedReplacement)
    }

    func testCheckRunsOverMultipleWordsIndependently() {
        let icelandic = DictLexicon(unigrams: ["kaffi": 500, "og": 900])
        let english = DictLexicon(unigrams: ["the": 900])
        let engine = TypeEngine(icelandic: icelandic, english: english, morphologyProvider: nil)

        let results = ConfirmedIntents.check(engine: engine, words: ["kaffi", "the"])
        XCTAssertEqual(results.map(\.word), ["kaffi", "the"])
        XCTAssertTrue(results.allSatisfy(\.pass))
    }

    private func tempFile(_ contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("confirmed-intents-\(UUID().uuidString).jsonl")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
