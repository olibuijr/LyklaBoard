import Foundation
import TypeEngine

/// Aggregate counts for a slice of corpus pairs (a category, a language, or
/// the whole split). All integers — deterministic given commit + data +
/// engine, so a scorecard line is reproducible (no floating-point drift in
/// the committed history).
public struct CorpusTally: Sendable, Equatable {
    public var total = 0
    public var top1 = 0
    public var top3 = 0
    public var autocorrectFired = 0
    public var falseAutocorrect = 0

    public init() {}

    public mutating func add(_ other: CorpusTally) {
        total += other.total
        top1 += other.top1
        top3 += other.top3
        autocorrectFired += other.autocorrectFired
        falseAutocorrect += other.falseAutocorrect
    }

    public func percent(_ n: Int) -> Double {
        total == 0 ? 0 : 100.0 * Double(n) / Double(total)
    }
}

public struct CorpusResult: Sendable {
    public let split: String
    public let byCategory: [String: CorpusTally]
    public let byLang: [String: CorpusTally]
    public let overall: CorpusTally
    public let stagesByCategory: [String: CorpusStageTally]
    public let stagesByLang: [String: CorpusStageTally]
    public let stagesOverall: CorpusStageTally
    public let runtimeSeconds: Double
}

/// The first engine boundary at which a corpus row stopped succeeding.
/// `sessionProxyFailure` is part of the shared contract but cannot be emitted
/// by this stateless corpus replay; Wave 41's timed embedder owns that stage.
public enum CorpusOutcomeStage: String, CaseIterable, Codable, Sendable {
    case success
    case discoveryMiss
    case rankingLoss
    case actionPolicyAbstention
    case actionPolicyError
    case sessionProxyFailure
}

public struct CorpusStageTally: Sendable, Equatable {
    public private(set) var counts: [CorpusOutcomeStage: Int] = [:]

    public init() {}

    public mutating func add(_ stage: CorpusOutcomeStage) {
        counts[stage, default: 0] += 1
    }

    public mutating func add(_ other: CorpusStageTally) {
        for (stage, count) in other.counts { counts[stage, default: 0] += count }
    }

    public subscript(_ stage: CorpusOutcomeStage) -> Int { counts[stage, default: 0] }
}

public enum CorpusEval {

    /// Replay each pair through `engine` and tally top-1 / top-3 /
    /// autocorrect-fired / false-autocorrect per category, per language, and
    /// overall. The engine is REUSED across all pairs (one artifact load);
    /// the lane posterior is reset per pair and re-primed by committing the
    /// pair's context words (the harness twin of "the user typed that context
    /// first"). Suggestion output mirrors the micro-eval exactly: no
    /// TypingSession verbatim slot is involved (the raw corrector/predictor
    /// bar), and leading capitalization is preserved by the engine.
    public static func run(
        engine: TypeEngine, pairs: [CorpusPair], split: String = "", limit: Int = 3
    ) -> CorpusResult {
        var byCategory: [String: CorpusTally] = [:]
        var byLang: [String: CorpusTally] = [:]
        var overall = CorpusTally()
        var stagesByCategory: [String: CorpusStageTally] = [:]
        var stagesByLang: [String: CorpusStageTally] = [:]
        var stagesOverall = CorpusStageTally()

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for pair in pairs {
                engine.resetLanguagePosterior()
                for word in pair.context { engine.confirmWord(word) }

                let context = pair.context.joined(separator: " ")
                let trace = CorrectionTrace()
                let suggestions = engine.suggestions(
                    context: context, currentWord: pair.typo, limit: limit, trace: trace)
                let texts = suggestions.map(\.text)
                let fired = suggestions.first?.isAutocorrect == true
                let target = pair.expectation == .preserve ? pair.typo : pair.intended
                let stage = classifyOutcome(
                    pair: pair,
                    suggestions: suggestions,
                    discoveredCandidates: trace.candidates.map(\.word)
                )

                var tally = CorpusTally()
                tally.total = 1
                if texts.first == target { tally.top1 = 1 }
                if texts.contains(target) { tally.top3 = 1 }
                if fired {
                    tally.autocorrectFired = 1
                    if texts.first != target { tally.falseAutocorrect = 1 }
                }

                byCategory[pair.category, default: CorpusTally()].add(tally)
                byLang[pair.lang, default: CorpusTally()].add(tally)
                overall.add(tally)
                stagesByCategory[pair.category, default: CorpusStageTally()].add(stage)
                stagesByLang[pair.lang, default: CorpusStageTally()].add(stage)
                stagesOverall.add(stage)
            }
        }

        return CorpusResult(
            split: split,
            byCategory: byCategory,
            byLang: byLang,
            overall: overall,
            stagesByCategory: stagesByCategory,
            stagesByLang: stagesByLang,
            stagesOverall: stagesOverall,
            runtimeSeconds: elapsed.evalMilliseconds / 1000
        )
    }

    /// Pure outcome classifier used by both the replay and focused tests.
    /// Candidate discovery is inspected before ranking, and the action policy
    /// is evaluated separately from bar order so roadmap work routes to the
    /// stage that actually lost the row.
    public static func classifyOutcome(
        pair: CorpusPair,
        suggestions: [Suggestion],
        discoveredCandidates: [String]
    ) -> CorpusOutcomeStage {
        let texts = suggestions.map(\.text)
        let first = suggestions.first
        let fired = first?.isAutocorrect == true

        if pair.expectation == .preserve {
            return fired && first?.text != pair.typo ? .actionPolicyError : .success
        }

        if fired && first?.text != pair.intended { return .actionPolicyError }
        if first?.text == pair.intended {
            return fired ? .success : .actionPolicyAbstention
        }
        if texts.contains(pair.intended) || discoveredCandidates.contains(pair.intended) {
            return .rankingLoss
        }
        return .discoveryMiss
    }
}
