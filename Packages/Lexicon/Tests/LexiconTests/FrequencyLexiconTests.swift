import XCTest

@testable import Lexicon

final class FrequencyLexiconTests: XCTestCase {

    static var lexicon: FrequencyLexicon!

    override class func setUp() {
        super.setUp()
        let url = Bundle.module.url(forResource: "fixture.lex", withExtension: nil)!
        lexicon = try! FrequencyLexicon(contentsOf: url)
    }

    var lexicon: FrequencyLexicon { Self.lexicon }

    // MARK: - Header / metadata

    func testHeaderMetadata() {
        XCTAssertEqual(lexicon.version, 1)
        XCTAssertEqual(lexicon.unigramCount, 20)
        XCTAssertEqual(lexicon.bigramCount, 10)
        XCTAssertEqual(lexicon.totalUnigramTokens, 12660)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try FrequencyLexicon(data: Data(repeating: 0xAB, count: 64)))
        XCTAssertThrowsError(try FrequencyLexicon(data: Data()))
    }

    // MARK: - frequency(of:)

    func testKnownWordFrequencies() {
        XCTAssertEqual(lexicon.frequency(of: "the"), 5000)
        XCTAssertEqual(lexicon.frequency(of: "quick"), 300)
        XCTAssertEqual(lexicon.frequency(of: "dog"), 350)
        XCTAssertEqual(lexicon.frequency(of: "og"), 1200)
    }

    func testUnknownWordReturnsNil() {
        XCTAssertNil(lexicon.frequency(of: "xyzzyquux"))
        // "það" was dropped from the fixture bigram source because it never
        // appears in the unigram list — confirms bigrams never grow the
        // unigram vocabulary.
        XCTAssertNil(lexicon.frequency(of: "það"))
    }

    func testCaseInsensitiveLookup() {
        XCTAssertEqual(lexicon.frequency(of: "THE"), lexicon.frequency(of: "the"))
        XCTAssertEqual(lexicon.frequency(of: "ÞETTA"), lexicon.frequency(of: "þetta"))
    }

    func testEmptyStringIsUnknown() {
        XCTAssertNil(lexicon.frequency(of: ""))
    }

    // MARK: - Icelandic non-ASCII round-trip

    func testIcelandicNonASCIIWords() {
        XCTAssertEqual(lexicon.frequency(of: "börnin"), 42)
        XCTAssertEqual(lexicon.frequency(of: "þetta"), 900)
        XCTAssertEqual(lexicon.frequency(of: "þeirra"), 87)
        XCTAssertEqual(lexicon.frequency(of: "æðislegur"), 12)
        XCTAssertEqual(lexicon.frequency(of: "öðruvísi"), 9)
        XCTAssertEqual(lexicon.frequency(of: "ánægður"), 33)
        XCTAssertEqual(lexicon.frequency(of: "morguninn"), 77)
    }

    // MARK: - bigramFrequency

    func testKnownBigramFrequencies() {
        XCTAssertEqual(lexicon.bigramFrequency("the", "quick"), 40)
        XCTAssertEqual(lexicon.bigramFrequency("quick", "brown"), 35)
        XCTAssertEqual(lexicon.bigramFrequency("þetta", "er"), 60)
        XCTAssertEqual(lexicon.bigramFrequency("og", "þetta"), 8)
    }

    func testUnseenBigramReturnsNil() {
        // Both words known, pair never co-occurred in the fixture.
        XCTAssertNil(lexicon.bigramFrequency("the", "dog"))
    }

    func testBigramWithUnknownWordReturnsNil() {
        // "það" never made it into the unigram table, so the bigram "það og"
        // (present in the raw fixture bigram source) was dropped by the
        // builder; both directions must be nil.
        XCTAssertNil(lexicon.bigramFrequency("það", "og"))
        XCTAssertNil(lexicon.bigramFrequency("og", "það"))
    }

    // MARK: - completions(of:)

    func testCompletionsOrderedByDescendingFrequency() {
        let results = lexicon.completions(of: "þ", limit: 10)
        XCTAssertEqual(results.map(\.word), ["þetta", "þeirra"])
        XCTAssertEqual(results.map(\.frequency), [900, 87])
    }

    func testCompletionsRespectsLimit() {
        let results = lexicon.completions(of: "þ", limit: 1)
        XCTAssertEqual(results.map(\.word), ["þetta"])
    }

    func testCompletionsUnknownPrefixIsEmpty() {
        XCTAssertEqual(lexicon.completions(of: "zzz", limit: 10).count, 0)
    }

    func testCompletionsExactWordIncluded() {
        // "og" is itself a complete word and a prefix of nothing else.
        let results = lexicon.completions(of: "og", limit: 10)
        XCTAssertEqual(results.map(\.word), ["og"])
    }

    func testCompletionsZeroLimitIsEmpty() {
        XCTAssertTrue(lexicon.completions(of: "þ", limit: 0).isEmpty)
    }

    func testCompletionsAsciiPrefixExcludesAccentedLookalikes() {
        // "á" (U+00E1) is a different byte sequence than ASCII "a" (U+0061),
        // so prefix "a" must match only "að", not "á"/"ánægður"/"æðislegur".
        let results = lexicon.completions(of: "a", limit: 10)
        XCTAssertEqual(results.map(\.word), ["að"])
    }

    // MARK: - Cross-check against real built artifacts

    /// Climbs from this test file up to the repo root
    /// (Packages/Lexicon/Tests/LexiconTests/<file> -> repo root).
    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    func testCrossCheckEnglishArtifact() throws {
        let url = Self.repoRoot().appendingPathComponent("data/en/en.lex")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "data/en/en.lex not built — run scripts/build-lexicon.py")
        let en = try FrequencyLexicon(contentsOf: url)

        // 20 random words sampled from data/en/en-80k.txt (seed 42), with
        // frequency scaled by the same divisor build-lexicon.py computed
        // for this artifact (divisor=7 at build time — see build log).
        let samples: [(String, UInt32)] = [
            ("fabulous", 210_486),
            ("volumes", 1_715_321),
            ("veined", 36_016),
            ("honorably", 47_578),
            ("malfunction", 58_482),
            ("filler", 143_517),
            ("benson", 240_022),
            ("countersinking", 1_984),
            ("originality", 310_966),
            ("largehearted", 874),
            ("agitates", 9_019),
            ("designated", 1_261_664),
            ("muslim", 1_371_270),
            ("devout", 276_872),
            ("turnaround", 61_244),
            ("croats", 53_420),
            ("polymerizes", 3_510),
            ("underachieves", 662),
            ("stomach", 1_596_984),
            ("soporifics", 1_537),
        ]
        for (word, expected) in samples {
            XCTAssertEqual(en.frequency(of: word), expected, "mismatch for \(word)")
        }
    }

    func testCrossCheckIcelandicArtifact() throws {
        let url = Self.repoRoot().appendingPathComponent("data/is/is.lex")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "data/is/is.lex not built — run scripts/build-lexicon.py")
        let is_ = try FrequencyLexicon(contentsOf: url)

        // 20 random words sampled from data/is/unigrams.json.gz (seed 42).
        // Icelandic counts fit UInt32 directly (scale divisor=1), so these
        // are exact source counts.
        let samples: [(String, UInt32)] = [
            ("buttner", 56),
            ("páskastemning", 6),
            ("hverven", 12),
            ("meðfædda", 45),
            ("viðskiptafræðimenntun", 10),
            ("stjórnskipaninni", 28),
            ("meðtöldum", 14_393),
            ("múslima", 88),
            ("fjárfestið", 12),
            ("flugatriði", 18),
            ("stjörnulaga", 28),
            ("flysjið", 93),
            ("íþróttamiðstöðin", 48),
            ("fkbl", 18),
            ("staðráðnar", 210),
            ("verklokum", 251),
            ("lewisham", 14),
            ("neysluvara", 232),
            ("transportir", 16),
            ("fiskveiðiauðlindin", 18),
        ]
        for (word, expected) in samples {
            XCTAssertEqual(is_.frequency(of: word), expected, "mismatch for \(word)")
        }
    }
}
