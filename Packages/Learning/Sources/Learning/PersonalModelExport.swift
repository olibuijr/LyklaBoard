import Foundation

/// "Export my data" — the symmetric counterpart to `SwiftKeyImport`.
///
/// A privacy-first product owes its users portability: everything the
/// keyboard has learned about them must be extractable in a single,
/// self-describing, human-readable file. This type is that file's shape.
///
/// The document is a faithful, plain-JSON snapshot of the personal-model
/// content the user can see and reason about: their learned words (with
/// commit counts + per-language attribution + the distinct-day history and
/// the explicit-acceptance flag), the words they added by hand, the
/// tombstones (deletions that must stick), the personal bigram counts, and
/// the per-key adaptive touch statistics. It is deliberately more than the
/// flat word list SwiftKey exports — because we hold richer data, and hiding
/// it would undercut the transparency pitch.
///
/// The file documents itself: `$schema` points at the format doc, and
/// `note` is a human-readable one-liner. `formatVersion` versions the export
/// envelope independently of `PersonalModel.schemaVersion` (the on-disk store
/// version), so the two can evolve separately.
///
/// This is an ADDITIVE, read-only projection of `PersonalModel`. There is no
/// re-importer for it in v1 (import already exists, one-directionally, from
/// SwiftKey); the goal here is the user's right to *have* their data, in a
/// form they (or any tool) can read.
public struct PersonalModelExport: Codable, Equatable, Sendable {

    /// One learned/user-added word with its full personal statistics.
    public struct Word: Codable, Equatable, Sendable {
        public var word: String
        /// Total commits (all languages).
        public var count: UInt32
        /// Commits attributed to each language lane at commit time
        /// (attribution only — never merges surface forms).
        public var icelandic: UInt32
        public var english: UInt32
        public var unknown: UInt32
        /// Distinct UTC day buckets the word was committed on (coarsest
        /// temporal data the store keeps — no finer than a day).
        public var daysSeen: [Int32]
        /// Learned immediately via a verbatim tap or import (survives decay).
        public var explicitlyAccepted: Bool
        /// The user added this word by hand in the dictionary editor.
        public var userAdded: Bool

        public init(
            word: String,
            count: UInt32,
            icelandic: UInt32,
            english: UInt32,
            unknown: UInt32,
            daysSeen: [Int32],
            explicitlyAccepted: Bool,
            userAdded: Bool
        ) {
            self.word = word
            self.count = count
            self.icelandic = icelandic
            self.english = english
            self.unknown = unknown
            self.daysSeen = daysSeen
            self.explicitlyAccepted = explicitlyAccepted
            self.userAdded = userAdded
        }
    }

    /// One personal bigram (word pair) count.
    public struct Bigram: Codable, Equatable, Sendable {
        public var first: String
        public var second: String
        public var count: UInt32

        public init(first: String, second: String, count: UInt32) {
            self.first = first
            self.second = second
            self.count = count
        }
    }

    /// Per-key adaptive touch statistics (2D Gaussian aggregates — never
    /// individual taps).
    public struct Touch: Codable, Equatable, Sendable {
        public var key: String
        public var stats: TouchKeyStats

        public init(key: String, stats: TouchKeyStats) {
            self.key = key
            self.stats = stats
        }
    }

    /// URL of the human-readable format documentation (emitted as `$schema`).
    public var schema: String
    /// Stable format identifier, so a tool can recognize the file by content.
    public var format: String
    /// Version of this export envelope (independent of the store schema).
    public var formatVersion: Int
    /// The `PersonalModel.schemaVersion` the data was projected from.
    public var modelSchemaVersion: Int
    /// Human-readable note pointing at the format doc (see `$schema`).
    public var note: String
    /// When the export was produced.
    public var exportedAt: Date
    public var learnedWords: [Word]
    public var userAddedWords: [String]
    public var tombstones: [String]
    public var bigrams: [Bigram]
    public var touchStatistics: [Touch]

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case format
        case formatVersion
        case modelSchemaVersion
        case note
        case exportedAt
        case learnedWords
        case userAddedWords
        case tombstones
        case bigrams
        case touchStatistics
    }

    public init(
        schema: String,
        format: String,
        formatVersion: Int,
        modelSchemaVersion: Int,
        note: String,
        exportedAt: Date,
        learnedWords: [Word],
        userAddedWords: [String],
        tombstones: [String],
        bigrams: [Bigram],
        touchStatistics: [Touch]
    ) {
        self.schema = schema
        self.format = format
        self.formatVersion = formatVersion
        self.modelSchemaVersion = modelSchemaVersion
        self.note = note
        self.exportedAt = exportedAt
        self.learnedWords = learnedWords
        self.userAddedWords = userAddedWords
        self.tombstones = tombstones
        self.bigrams = bigrams
        self.touchStatistics = touchStatistics
    }
}

public extension PersonalModel {

    /// Canonical format identifier written into every export's `format` field.
    static let exportFormatIdentifier = "lyklabord-personal-export"

    /// Current export envelope version (bump on breaking format changes;
    /// independent of `schemaVersion`, the on-disk store version).
    static let exportFormatVersion = 1

    /// Default `$schema` URL — the human-readable format documentation.
    /// The app passes its own (localized) note but reuses this URL, so the
    /// pointer stays in one place.
    static let exportSchemaURL =
        "https://github.com/jokull/LyklabordApp/blob/main/docs/EXPORT_FORMAT.md"

    /// Build a self-describing snapshot of everything in the personal model
    /// the user can see: learned words (with counts/attribution/day-history),
    /// hand-added words, tombstones, personal bigrams, and touch statistics.
    ///
    /// Output is deterministic (all collections sorted) so identical state
    /// yields identical bytes apart from `exportedAt` — nice for diffing and
    /// for the tests. A word is included in `learnedWords` when it is
    /// currently learned (threshold met, explicitly accepted, or user-added);
    /// pending sub-threshold words (one-off commits, often typos) are
    /// deliberately left out — they are not vocabulary the user has, and
    /// surfacing raw typos in a portable file is undesirable.
    ///
    /// - Parameters:
    ///   - note: human-readable one-liner stored in the file (points at the
    ///     format doc). Defaults to a neutral technical string; the app
    ///     overrides it with localized copy.
    ///   - schema: `$schema` URL. Defaults to `exportSchemaURL`.
    ///   - exportedAt: timestamp stamped into the file (injectable for tests).
    func exportDocument(
        note: String = "Lyklaborð personal dictionary export. See $schema for the format.",
        schema: String = PersonalModel.exportSchemaURL,
        exportedAt: Date = Date()
    ) -> PersonalModelExport {
        // Union of commit-backed learned words and hand-added words: a
        // user-added word has no `WordStats` entry until it is also typed, so
        // it would otherwise be missing from `learnedWords` (it lives only in
        // the `userAdded` set). Give those a zeroed stats projection.
        var learnedKeys = Set(self.words.keys.filter { isLearned($0) })
        learnedKeys.formUnion(userAddedWords)
        let words: [PersonalModelExport.Word] = learnedKeys
            .map { key -> PersonalModelExport.Word in
                let stats = self.words[key] ?? WordStats()
                return PersonalModelExport.Word(
                    word: key,
                    count: stats.count,
                    icelandic: stats.icelandicCount,
                    english: stats.englishCount,
                    unknown: stats.unknownCount,
                    daysSeen: stats.daysSeen,
                    explicitlyAccepted: stats.explicitlyAccepted,
                    userAdded: isUserAdded(key)
                )
            }
            .sorted { $0.word < $1.word }

        let exportedBigrams: [PersonalModelExport.Bigram] = bigrams
            .map { key, count -> PersonalModelExport.Bigram in
                // Bigram keys are "first second" (single space, see
                // `PersonalModel.bigramKey`). Split on the FIRST space only —
                // words never contain spaces, so exactly one split is correct.
                if let spaceIndex = key.firstIndex(of: " ") {
                    return PersonalModelExport.Bigram(
                        first: String(key[..<spaceIndex]),
                        second: String(key[key.index(after: spaceIndex)...]),
                        count: count
                    )
                }
                return PersonalModelExport.Bigram(first: key, second: "", count: count)
            }
            .sorted {
                $0.first < $1.first || ($0.first == $1.first && $0.second < $1.second)
            }

        let exportedTouch: [PersonalModelExport.Touch] = touch
            .map { PersonalModelExport.Touch(key: $0.key, stats: $0.value) }
            .sorted { $0.key < $1.key }

        return PersonalModelExport(
            schema: schema,
            format: PersonalModel.exportFormatIdentifier,
            formatVersion: PersonalModel.exportFormatVersion,
            modelSchemaVersion: PersonalModel.schemaVersion,
            note: note,
            exportedAt: exportedAt,
            learnedWords: words,
            userAddedWords: userAddedWords,
            tombstones: tombstones.sorted(),
            bigrams: exportedBigrams,
            touchStatistics: exportedTouch
        )
    }

    /// Encode `exportDocument(...)` as pretty-printed, sorted-key JSON `Data`
    /// suitable for handing straight to a `fileExporter`/`ShareLink`. Dates
    /// are ISO-8601 (human-readable, tool-friendly).
    func exportedJSONData(
        note: String = "Lyklaborð personal dictionary export. See $schema for the format.",
        schema: String = PersonalModel.exportSchemaURL,
        exportedAt: Date = Date()
    ) throws -> Data {
        let document = exportDocument(note: note, schema: schema, exportedAt: exportedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(document)
        } catch {
            throw PersonalModelError.ioError("export encode failed: \(error)")
        }
    }
}
