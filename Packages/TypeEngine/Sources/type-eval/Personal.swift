import EvalKit
import Foundation
import TypeEngine

// `type-eval personal [--update-baseline] [--corpus <path>] [--baseline
// <path>] [--confirmed-intents <path>]` — the personal-eval hard wave gate
// (eval-studio v2 phase 2, docs/WAVES.md standing doctrine "Eval discipline":
// personal-eval.jsonl, real confirmed typing, must never regress).
//
// Unlike `corpus`/`scorecard`, this command's input is PERSONAL DATA
// (tools/session-analyzer/personal-eval.jsonl, gitignored) — absent on a
// fresh checkout or CI by design, so its unavailability is a clean, silent
// no-op (exit 0), never a failure.
//
// Gate semantics (see EvalKit/PersonalEval.swift for the pure comparison
// logic):
//   (a) a row that passed top-1 in the baseline and fails now       → REGRESSION
//   (b) a row with a NEW false-autocorrect (incl. brand-new rows)   → REGRESSION
//   (c) new rows / newly-passing rows                               → improvement (listed, non-gating)
// Plus (Feature 2, slangur registry): every confirmed-intentional word
// (tools/session-analyzer/confirmed-intents.jsonl, `intentional: true`) must
// not auto-apply a replacement at a neutral lane posterior — a failure here
// is its own REGRESSION (false-positive class), independent of the baseline.
//
// `--update-baseline` rewrites scores/personal-baseline.json (gitignored —
// derived from personal text) with the current run, for the next wave to
// compare against.
func runPersonalCommand(_ args: [String]) {
    var corpusPathOverride: String?
    var baselinePathOverride: String?
    var confirmedIntentsOverride: String?
    var updateBaseline = false
    var rest = args
    while let flag = rest.first {
        rest.removeFirst()
        switch flag {
        case "--update-baseline": updateBaseline = true
        case "--corpus":
            guard !rest.isEmpty else { stderr("--corpus requires a path"); exit(2) }
            corpusPathOverride = rest.removeFirst()
        case "--baseline":
            guard !rest.isEmpty else { stderr("--baseline requires a path"); exit(2) }
            baselinePathOverride = rest.removeFirst()
        case "--confirmed-intents":
            guard !rest.isEmpty else { stderr("--confirmed-intents requires a path"); exit(2) }
            confirmedIntentsOverride = rest.removeFirst()
        default:
            stderr("unknown flag \(flag)")
            exit(2)
        }
    }

    guard let repoRoot = ArtifactLoader.repoRoot() else {
        stderr("cannot locate repo root")
        exit(2)
    }

    let corpusURL =
        corpusPathOverride.map { URL(fileURLWithPath: $0) }
        ?? repoRoot.appendingPathComponent("tools/session-analyzer/personal-eval.jsonl")

    // The gate is only as available as the local personal data, by design:
    // a fresh checkout (or CI, which never has this file) is a clean no-op.
    guard FileManager.default.fileExists(atPath: corpusURL.path) else {
        print(
            "[type-eval personal] no personal-eval.jsonl at \(corpusURL.path) — "
                + "personal gate skipped (real typing data is local-only and gitignored; "
                + "this is expected on a fresh checkout or in CI).")
        exit(0)
    }

    let pairs: [CorpusPair]
    do {
        pairs = try Corpus.loadCorpus(at: corpusURL)
    } catch {
        stderr("failed to load personal corpus: \(error)")
        exit(2)
    }
    guard !pairs.isEmpty else {
        print("[type-eval personal] \(corpusURL.path) is empty — nothing to gate.")
        exit(0)
    }

    let confirmedIntentsURL =
        confirmedIntentsOverride.map { URL(fileURLWithPath: $0) }
        ?? corpusURL.deletingLastPathComponent().appendingPathComponent("confirmed-intents.jsonl")
    var intentionalWords: [String] = []
    if FileManager.default.fileExists(atPath: confirmedIntentsURL.path) {
        do {
            intentionalWords = try ConfirmedIntents.loadIntentionalWords(at: confirmedIntentsURL)
        } catch {
            stderr("failed to load confirmed-intents: \(error)")
            exit(2)
        }
    } else {
        stderr("no confirmed-intents.jsonl at \(confirmedIntentsURL.path) — slangur check skipped")
    }

    stderr("loading engine…")
    let engine: TypeEngine
    do {
        engine = try ArtifactLoader.loadEngine(
            config: ArtifactLoader.deterministicConfig(), log: { stderr($0) })
    } catch {
        stderr("\(error)")
        exit(2)
    }
    engine.warmUp()

    let (currentRows, summary) = PersonalEval.evaluate(engine: engine, pairs: pairs)
    let intentionalResults = ConfirmedIntents.check(engine: engine, words: intentionalWords)
    let commit = git(["-C", repoRoot.path, "rev-parse", "HEAD"], default: "unknown")

    print(
        "[type-eval personal] \(summary.n) rows — top1 \(summary.top1)/\(summary.n), "
            + "autocorrected \(summary.autocorrected), falseAc \(summary.falseAc) "
            + "(commit \(commit))")

    let intentionalFailures = intentionalResults.filter { !$0.pass }
    if !intentionalWords.isEmpty {
        print(
            "[type-eval personal] intentional (slangur) check: "
                + "\(intentionalWords.count - intentionalFailures.count)/\(intentionalWords.count) survive unforced")
        for failure in intentionalFailures {
            print(
                "  REGRESSION (false-positive): \"\(failure.word)\" was force-autocorrected to "
                    + "\"\(failure.forcedReplacement ?? "?")\" despite confirmed-intentional")
        }
    }

    let baselinePathURL =
        baselinePathOverride.map { URL(fileURLWithPath: $0) }
        ?? repoRoot.appendingPathComponent("scores/personal-baseline.json")

    var gatePass = intentionalFailures.isEmpty
    if FileManager.default.fileExists(atPath: baselinePathURL.path) {
        guard let baseline = loadPersonalBaseline(at: baselinePathURL) else {
            stderr("failed to parse baseline at \(baselinePathURL.path)")
            exit(2)
        }
        let report = PersonalEval.compare(current: currentRows, baseline: baseline)
        gatePass = gatePass && report.pass

        if report.regressions.isEmpty {
            print("[type-eval personal] no regressions vs baseline (\(baseline.engineCommit)).")
        } else {
            print(
                "[type-eval personal] \(report.regressions.count) REGRESSION(S) vs baseline "
                    + "(\(baseline.engineCommit)):")
            for finding in report.regressions {
                print("  REGRESSION \"\(finding.key)\": \(finding.detail)")
            }
        }
        if !report.improvements.isEmpty {
            print("[type-eval personal] \(report.improvements.count) improvement(s):")
            for finding in report.improvements {
                print("  + \"\(finding.key)\": \(finding.detail)")
            }
        }
    } else {
        print(
            "[type-eval personal] no baseline at \(baselinePathURL.path) yet — "
                + "nothing to compare against. Run with --update-baseline to establish one.")
    }

    if updateBaseline {
        let baseline = PersonalBaseline(
            engineCommit: commit,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            rows: currentRows,
            summary: summary)
        do {
            try writePersonalBaseline(baseline, to: baselinePathURL)
            print("[type-eval personal] baseline written to \(baselinePathURL.path)")
        } catch {
            stderr("failed to write baseline: \(error)")
            exit(2)
        }
    }

    exit(gatePass ? 0 : 1)
}

func loadPersonalBaseline(at url: URL) -> PersonalBaseline? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(PersonalBaseline.self, from: data)
}

func writePersonalBaseline(_ baseline: PersonalBaseline, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(baseline)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
