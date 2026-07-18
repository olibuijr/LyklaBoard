import XCTest

@testable import TypeEngine

final class CalibrationProfileTests: XCTestCase {
    func testPrecomputedProfilesPreserveMeasuredCalibrationAndSuggestions() {
        let isLex = DictLexicon(unigrams: [
            "hús": 1_000, "hus": 2, "hestur": 800, "hundur": 700,
            "halló": 600, "heimur": 500,
        ])
        let enLex = DictLexicon(unigrams: [
            "house": 1_000, "his": 900, "hello": 800, "home": 700,
            "horse": 600, "hound": 500,
        ])
        let measured = TypeEngine(icelandic: isLex, english: enLex)
        let d = measured.calibrationDiagnostics
        let isProfile = LexiconCalibrationProfile(
            languageDataGeneration: "test-is", addK: measured.config.addK,
            meanLogFrequency: d.icelandicMean, stdLogFrequency: d.icelandicSigma,
            warmupWords: d.icelandicWarmupWords)
        let enProfile = LexiconCalibrationProfile(
            languageDataGeneration: "test-en", addK: measured.config.addK,
            meanLogFrequency: d.englishMean, stdLogFrequency: d.englishSigma,
            warmupWords: d.englishWarmupWords)
        let precomputed = TypeEngine(
            icelandic: isLex, english: enLex,
            icelandicCalibration: isProfile, englishCalibration: enProfile)

        let p = precomputed.calibrationDiagnostics
        XCTAssertEqual(p.icelandicMean, d.icelandicMean)
        XCTAssertEqual(p.icelandicSigma, d.icelandicSigma)
        XCTAssertEqual(p.englishMean, d.englishMean)
        XCTAssertEqual(p.englishSigma, d.englishSigma)
        XCTAssertEqual(
            precomputed.suggestions(context: "", currentWord: "hus", limit: 3),
            measured.suggestions(context: "", currentWord: "hus", limit: 3))
    }

    func testInvalidProfileFallsBackToRuntimeMeasurement() throws {
        let lex = DictLexicon(unigrams: ["aa": 10, "ab": 8, "ac": 6, "ad": 4])
        let invalidJSON = """
        {"schema":"wrong","languageDataGeneration":"x","addK":0.5,
         "meanLogFrequency":99,"stdLogFrequency":1,"warmupWords":["aa"]}
        """
        let invalid = try JSONDecoder().decode(
            LexiconCalibrationProfile.self, from: Data(invalidJSON.utf8))
        let baseline = TypeEngine(icelandic: lex, english: lex).calibrationDiagnostics
        let fallback = TypeEngine(
            icelandic: lex, english: lex,
            icelandicCalibration: invalid, englishCalibration: invalid
        ).calibrationDiagnostics
        XCTAssertEqual(fallback.icelandicMean, baseline.icelandicMean)
        XCTAssertNotEqual(fallback.icelandicMean, 99)
    }
}
