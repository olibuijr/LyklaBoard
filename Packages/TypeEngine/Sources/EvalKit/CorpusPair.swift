import Foundation

/// One corpus-derived typo→intended evaluation pair, the JSONL record shape
/// produced by `scripts/generate-eval-pairs.py` and shipped in
/// `data/eval/{dev,heldout}.jsonl`. See `data/eval/README.md`.
///
///   {"typo": "fra", "intended": "frá", "context": ["Þessi", "rúnaröð"],
///    "lang": "is", "category": "accent_drop", "seed": 20260715}
///
/// `context` is the up-to-8 real word tokens immediately preceding the target
/// (punctuation/digits stripped — a token list, not a verbatim substring).
/// For `space_miss`, `intended` is the two-word `"word1 word2"` string; for
/// every other category it is a single word. `seed` (and any other extra
/// key) is ignored by the decoder.
public enum CorpusExpectation: String, Codable, Sendable {
    /// The typed token is an error and `intended` is the desired replacement.
    case repair
    /// The typed token is valid and must be preserved even when context makes
    /// `intended` tempting. Used by clean-identity and valid-word hard negatives.
    case preserve
}

public struct CorpusPair: Codable, Equatable, Sendable {
    public let typo: String
    public let intended: String
    public let context: [String]
    public let lang: String
    public let category: String
    public let expectation: CorpusExpectation

    public init(
        typo: String, intended: String, context: [String], lang: String, category: String,
        expectation: CorpusExpectation = .repair
    ) {
        self.typo = typo
        self.intended = intended
        self.context = context
        self.lang = lang
        self.category = category
        self.expectation = expectation
    }

    enum CodingKeys: String, CodingKey {
        case typo, intended, context, lang, category, expectation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        typo = try values.decode(String.self, forKey: .typo)
        intended = try values.decode(String.self, forKey: .intended)
        context = try values.decode([String].self, forKey: .context)
        lang = try values.decode(String.self, forKey: .lang)
        category = try values.decode(String.self, forKey: .category)
        expectation = try values.decodeIfPresent(CorpusExpectation.self, forKey: .expectation)
            ?? .repair
    }
}

public enum CorpusParseError: Error, CustomStringConvertible, Equatable {
    case malformedJSON(line: Int, underlying: String)

    public var description: String {
        switch self {
        case let .malformedJSON(line, underlying):
            return "corpus line \(line): malformed JSON (\(underlying))"
        }
    }
}

public enum Corpus {

    private static let decoder = JSONDecoder()

    /// Parse a single JSONL line into a `CorpusPair`. Returns nil for a blank
    /// line (so `loadCorpus` can skip trailing newlines); throws
    /// `CorpusParseError.malformedJSON` for a non-empty line that is not a
    /// valid pair record. `lineNumber` is 1-based, for diagnostics.
    public static func parseLine(_ line: String, lineNumber: Int = 0) throws -> CorpusPair? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let data = trimmed.data(using: .utf8) else {
            throw CorpusParseError.malformedJSON(line: lineNumber, underlying: "not UTF-8")
        }
        do {
            return try decoder.decode(CorpusPair.self, from: data)
        } catch {
            throw CorpusParseError.malformedJSON(line: lineNumber, underlying: "\(error)")
        }
    }

    /// Load and parse a whole `.jsonl` corpus file. Blank lines are skipped;
    /// a malformed non-blank line aborts with `CorpusParseError`.
    public static func loadCorpus(at url: URL) throws -> [CorpusPair] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var pairs: [CorpusPair] = []
        pairs.reserveCapacity(3000)
        for (index, line) in raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if let pair = try parseLine(String(line), lineNumber: index + 1) {
                pairs.append(pair)
            }
        }
        return pairs
    }
}
