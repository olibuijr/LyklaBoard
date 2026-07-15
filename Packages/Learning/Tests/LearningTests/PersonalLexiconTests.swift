import XCTest
import Lexicon
@testable import Learning

final class PersonalLexiconTests: LearningTestCase {

    func testExposesOnlyLearnedWords() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("hestur", model: model, log: log)  // learned (2 days)
        try log.append(.wordCommitted(word: "einskiptis", previousWord: nil, languageHint: .icelandic))
        try model.compact(applying: log)  // pending (1 day)
        try model.addUserWord("Þórsmörk")
        try learnWord("eytt", model: model, log: log)
        model.remove(word: "eytt")

        let lexicon = PersonalLexicon(model: model)
        XCTAssertEqual(lexicon.frequency(of: "hestur"), 2)
        XCTAssertNil(lexicon.frequency(of: "einskiptis"), "pending words stay out of ranking")
        XCTAssertEqual(lexicon.frequency(of: "Þórsmörk"), 1)
        XCTAssertNil(lexicon.frequency(of: "eytt"), "tombstoned words are gone")
        XCTAssertEqual(lexicon.totalUnigramTokens, 3)
    }

    func testCompletionsSortedByFrequencyThenWord() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("hestur", model: model, log: log, days: [1, 2, 3])
        try learnWord("hestar", model: model, log: log, days: [1, 2, 3])
        try learnWord("hesti", model: model, log: log, days: [1, 2, 3, 4])
        try learnWord("annar", model: model, log: log)

        let lexicon = PersonalLexicon(model: model)
        let completions = lexicon.completions(of: "hest", limit: 10)
        XCTAssertEqual(completions.map(\.word), ["hesti", "hestar", "hestur"])
        XCTAssertEqual(lexicon.completions(of: "hest", limit: 1).map(\.word), ["hesti"])
        XCTAssertTrue(lexicon.completions(of: "zzz", limit: 5).isEmpty)
    }

    func testContinuationsMatchLexiconProtocolSemantics() throws {
        let (model, log) = try makeModelAndLog()
        for _ in 0..<3 {
            try log.append(.wordCommitted(word: "morgun", previousWord: "góðan", languageHint: .icelandic))
        }
        try log.append(.wordCommitted(word: "daginn", previousWord: "góðan", languageHint: .icelandic))
        try model.compact(applying: log)

        let lexicon = PersonalLexicon(model: model)
        XCTAssertEqual(lexicon.bigramFrequency("góðan", "morgun"), 3)
        XCTAssertEqual(lexicon.continuations(of: "góðan", limit: 5).map(\.word), ["morgun", "daginn"])
    }

    func testUsableThroughLexiconProtocolExistential() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("hestur", model: model, log: log)
        let lexicon: any Lexicon = PersonalLexicon(model: model)
        XCTAssertEqual(lexicon.frequency(of: "hestur"), 2)
        XCTAssertNil(lexicon.frequency(of: "óþekkt"))
    }

    func testSnapshotIsImmuneToLaterModelMutation() throws {
        let (model, log) = try makeModelAndLog()
        try learnWord("hestur", model: model, log: log)
        let lexicon = PersonalLexicon(model: model)
        model.remove(word: "hestur")
        XCTAssertEqual(lexicon.frequency(of: "hestur"), 2, "snapshot semantics: taken at init")
        XCTAssertNil(PersonalLexicon(model: model).frequency(of: "hestur"))
    }
}
