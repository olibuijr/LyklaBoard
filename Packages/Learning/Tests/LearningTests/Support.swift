import XCTest
@testable import Learning

/// Shared fixture: a temp directory, an injectable day bucket, and helpers
/// for building a model+log pair and learning words across distinct days.
class LearningTestCase: XCTestCase {

    var directory: URL!
    /// Mutable day bucket fed to `EventLog.dayProvider` — tests advance this
    /// to simulate distinct-day commits.
    var day: Int32 = 20_000

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LearningTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        day = 20_000
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeModelAndLog(
        configuration: PersonalModel.Configuration = PersonalModel.Configuration(),
        logName: String = "events.log"
    ) throws -> (PersonalModel, EventLog) {
        let model = PersonalModel(configuration: configuration)
        let log = EventLog(
            url: directory.appendingPathComponent(logName),
            dayProvider: { [weak self] in self?.day ?? 0 }
        )
        return (model, log)
    }

    /// Commit `word` on the given distinct days (default two) and compact —
    /// enough to cross the default learned threshold.
    func learnWord(
        _ word: String,
        model: PersonalModel,
        log: EventLog,
        days: [Int32] = [20_000, 20_001]
    ) throws {
        for d in days {
            day = d
            try log.append(.wordCommitted(word: word, previousWord: nil, languageHint: .icelandic))
            try model.compact(applying: log)
        }
    }
}
