import Foundation

public struct CorpusMetricSnapshot: Codable, Equatable, Sendable {
    public let n: Int
    public let top1: Int
    public let top3: Int
    public let falseAc: Int

    public init(n: Int, top1: Int, top3: Int, falseAc: Int) {
        self.n = n
        self.top1 = top1
        self.top3 = top3
        self.falseAc = falseAc
    }

    public init(_ tally: CorpusTally) {
        self.init(
            n: tally.total,
            top1: tally.top1,
            top3: tally.top3,
            falseAc: tally.falseAutocorrect)
    }
}

public struct CorpusSuiteSnapshot: Codable, Equatable, Sendable {
    public let overall: CorpusMetricSnapshot
    public let categories: [String: CorpusMetricSnapshot]
    public let byLang: [String: CorpusMetricSnapshot]

    public init(
        overall: CorpusMetricSnapshot,
        categories: [String: CorpusMetricSnapshot],
        byLang: [String: CorpusMetricSnapshot]
    ) {
        self.overall = overall
        self.categories = categories
        self.byLang = byLang
    }

    public init(_ result: CorpusResult) {
        self.init(
            overall: CorpusMetricSnapshot(result.overall),
            categories: result.byCategory.mapValues(CorpusMetricSnapshot.init),
            byLang: result.byLang.mapValues(CorpusMetricSnapshot.init))
    }
}

public struct CorpusBaselineDocument: Codable, Equatable, Sendable {
    public static let currentSchema = "lyklabord.corpus-baseline.v1"

    public let schema: String
    public let suites: [String: CorpusSuiteSnapshot]

    public init(
        schema: String = CorpusBaselineDocument.currentSchema,
        suites: [String: CorpusSuiteSnapshot]
    ) {
        self.schema = schema
        self.suites = suites
    }
}

public enum CorpusBaselineGate {
    public static func failures(
        current: [String: CorpusSuiteSnapshot],
        baseline: CorpusBaselineDocument
    ) -> [String] {
        guard baseline.schema == CorpusBaselineDocument.currentSchema else {
            return ["unsupported corpus baseline schema \(baseline.schema)"]
        }
        var failures: [String] = []
        if Set(current.keys) != Set(baseline.suites.keys) {
            failures.append(
                "suite cohort changed: current=\(current.keys.sorted()) "
                    + "baseline=\(baseline.suites.keys.sorted())")
        }
        for suiteName in baseline.suites.keys.sorted() {
            guard let expected = baseline.suites[suiteName], let actual = current[suiteName] else {
                continue
            }
            compare(
                actual.overall, expected.overall,
                path: "\(suiteName).overall", failures: &failures)
            compareGroup(
                actual.categories, expected.categories,
                path: "\(suiteName).categories", failures: &failures)
            compareGroup(
                actual.byLang, expected.byLang,
                path: "\(suiteName).byLang", failures: &failures)
        }
        return failures
    }

    private static func compareGroup(
        _ actual: [String: CorpusMetricSnapshot],
        _ expected: [String: CorpusMetricSnapshot],
        path: String,
        failures: inout [String]
    ) {
        if Set(actual.keys) != Set(expected.keys) {
            failures.append(
                "\(path) cohort changed: current=\(actual.keys.sorted()) "
                    + "baseline=\(expected.keys.sorted())")
        }
        for name in expected.keys.sorted() {
            guard let lhs = actual[name], let rhs = expected[name] else { continue }
            compare(lhs, rhs, path: "\(path).\(name)", failures: &failures)
        }
    }

    private static func compare(
        _ actual: CorpusMetricSnapshot,
        _ expected: CorpusMetricSnapshot,
        path: String,
        failures: inout [String]
    ) {
        if actual.n != expected.n {
            failures.append("\(path).n changed: \(actual.n) != \(expected.n)")
        }
        if actual.top1 < expected.top1 {
            failures.append("\(path).top1 regressed: \(actual.top1) < \(expected.top1)")
        }
        if actual.top3 < expected.top3 {
            failures.append("\(path).top3 regressed: \(actual.top3) < \(expected.top3)")
        }
        if actual.falseAc > expected.falseAc {
            failures.append("\(path).falseAc regressed: \(actual.falseAc) > \(expected.falseAc)")
        }
    }
}
