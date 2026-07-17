import Foundation
import TypeEngine

// Personal-eval gate (eval-studio v2 phase 2): the hard-gate twin of
// `CorpusEval`, but keyed per-row (not just aggregated) so a wave can name
// EXACTLY which real typed pair regressed — the synthetic dev/heldout splits
// can't catch personal-state bugs (wave 26's learning self-poisoning was
// byte-identical on dev; only a personal snapshot reproduced it). Comparison
// logic here is pure (no TypeEngine calls) so it's unit-testable against a
// fixture baseline/run pair; `PersonalEval.evaluate` is the only piece that
// touches a live engine.

/// One row's outcome, keyed by `PersonalEval.rowKey(typo:intended:)`
/// ("<typo>|<intended>", lowercased) in both the baseline file and a fresh
/// run — dictionary lookup is how the gate matches "the same real pair"
/// across commits without relying on corpus line order.
public struct PersonalRowResult: Codable, Equatable, Sendable {
    public let top1: Bool
    public let autocorrected: Bool
    public let falseAc: Bool

    public init(top1: Bool, autocorrected: Bool, falseAc: Bool) {
        self.top1 = top1
        self.autocorrected = autocorrected
        self.falseAc = falseAc
    }
}

/// Aggregate counts over a personal run — the same shape whether it becomes
/// the stored baseline's summary or a fresh run's report line.
public struct PersonalSummary: Codable, Equatable, Sendable {
    public var n = 0
    public var top1 = 0
    public var autocorrected = 0
    public var falseAc = 0

    public init(n: Int = 0, top1: Int = 0, autocorrected: Int = 0, falseAc: Int = 0) {
        self.n = n
        self.top1 = top1
        self.autocorrected = autocorrected
        self.falseAc = falseAc
    }
}

/// The on-disk shape of `scores/personal-baseline.json` — derived from the
/// user's own typed text (personal-eval.jsonl), so this file is GITIGNORED
/// exactly like the corpus it summarizes; it lives locally only. `--update-
/// baseline` rewrites it after a wave is accepted.
public struct PersonalBaseline: Codable, Equatable, Sendable {
    public let version: String
    public let engineCommit: String
    public let timestamp: String
    public let rows: [String: PersonalRowResult]
    public let summary: PersonalSummary

    public init(
        version: String = "v0", engineCommit: String, timestamp: String,
        rows: [String: PersonalRowResult], summary: PersonalSummary
    ) {
        self.version = version
        self.engineCommit = engineCommit
        self.timestamp = timestamp
        self.rows = rows
        self.summary = summary
    }
}

/// One named finding from a baseline comparison — `key` is the row key,
/// `detail` is a short human-readable reason, used verbatim in gate output
/// so a regression can be traced straight back to a `typo|intended` pair.
public struct PersonalGateFinding: Equatable, Sendable {
    public let key: String
    public let detail: String

    public init(key: String, detail: String) {
        self.key = key
        self.detail = detail
    }
}

/// The result of comparing a fresh personal run against the stored baseline.
/// `pass` is false the moment any regression exists — the gate semantics
/// (personal-eval must never regress) are binary, not a threshold.
public struct PersonalGateReport: Equatable, Sendable {
    public let regressions: [PersonalGateFinding]
    public let improvements: [PersonalGateFinding]
    public var pass: Bool { regressions.isEmpty }
}

public enum PersonalEval {

    /// The stable key a row is tracked under: `typo|intended`, both
    /// lowercased so "Broðir"/"broðir" and "Bróðir"/"bróðir" collapse to one
    /// identity (matching the conservatism-invariant discipline elsewhere in
    /// the engine — case is not part of a word's typo identity here).
    public static func rowKey(typo: String, intended: String) -> String {
        "\(typo.lowercased())|\(intended.lowercased())"
    }

    /// Replay `pairs` (the personal corpus, `CorpusPair`-shaped —
    /// `Corpus.loadCorpus` already ignores the extra provenance keys
    /// personal-eval.jsonl carries: `class`/`source`/`session`/
    /// `engine_commit`) through `engine`, one row result per pair keyed by
    /// `rowKey`. A duplicate key (same typo/intended pair recorded twice,
    /// e.g. from two sessions) collapses to whichever pair is later in the
    /// file — same last-write-wins behaviour a dictionary gives for free;
    /// personal-eval.jsonl is deduped upstream by `aggregate.py` so this is
    /// not expected to matter in practice.
    public static func evaluate(
        engine: TypeEngine, pairs: [CorpusPair]
    ) -> (rows: [String: PersonalRowResult], summary: PersonalSummary) {
        var rows: [String: PersonalRowResult] = [:]
        var summary = PersonalSummary()
        for pair in pairs {
            engine.resetLanguagePosterior()
            for word in pair.context { engine.confirmWord(word) }
            let context = pair.context.joined(separator: " ")
            let suggestions = engine.suggestions(
                context: context, currentWord: pair.typo, limit: 3)
            let texts = suggestions.map(\.text)
            let fired = suggestions.first?.isAutocorrect == true
            let top1 = texts.first == pair.intended
            let falseAc = fired && !top1

            let row = PersonalRowResult(top1: top1, autocorrected: fired, falseAc: falseAc)
            rows[rowKey(typo: pair.typo, intended: pair.intended)] = row

            summary.n += 1
            if top1 { summary.top1 += 1 }
            if fired { summary.autocorrected += 1 }
            if falseAc { summary.falseAc += 1 }
        }
        return (rows, summary)
    }

    /// Pure gate: compare a fresh run's rows against the stored baseline.
    /// Gate semantics (docs/WAVES.md standing doctrine, "personal-eval.jsonl
    /// must never regress"):
    ///
    ///   (a) a row that passed top-1 in the baseline and fails top-1 now
    ///       — REGRESSION, named explicitly.
    ///   (b) a row with `falseAc == true` now that was NOT `falseAc == true`
    ///       in the baseline (including brand-new rows) — REGRESSION. This
    ///       is deliberately stricter than (a): false-autocorrect is the
    ///       metric guarded most jealously, so even a NEW row is held to it.
    ///   (c) new rows (no baseline entry) or newly-passing rows (baseline
    ///       top-1 false, now true) that are not already a (b) regression
    ///       are IMPROVEMENTS, listed for visibility (not gating).
    ///
    /// A baseline row whose key vanished from the current run (corpus edited
    /// by hand) is neither a regression nor an improvement — there is
    /// nothing to compare, so it is silently skipped.
    public static func compare(
        current: [String: PersonalRowResult], baseline: PersonalBaseline
    ) -> PersonalGateReport {
        var regressions: [PersonalGateFinding] = []
        var improvements: [PersonalGateFinding] = []

        for (key, row) in current {
            let base = baseline.rows[key]

            if row.falseAc && !(base?.falseAc ?? false) {
                regressions.append(
                    PersonalGateFinding(
                        key: key,
                        detail: base == nil
                            ? "new false-autocorrect on a new row"
                            : "new false-autocorrect (was clean in baseline)"))
                continue  // a (b) regression is reported once, not double-counted as (a) too
            }

            if let base, base.top1, !row.top1 {
                regressions.append(
                    PersonalGateFinding(
                        key: key, detail: "top-1 regressed (passed in baseline, fails now)"))
                continue
            }

            if base == nil {
                improvements.append(PersonalGateFinding(key: key, detail: "new row"))
            } else if base!.top1 == false && row.top1 {
                improvements.append(
                    PersonalGateFinding(key: key, detail: "newly passing top-1"))
            }
        }

        return PersonalGateReport(
            regressions: regressions.sorted { $0.key < $1.key },
            improvements: improvements.sorted { $0.key < $1.key })
    }
}

// MARK: - Confirmed intents (slangur registry, Feature 2)

/// One row of `confirmed-intents.jsonl`: either `{"typo", "intended"}` (a
/// resolved silent miss, promoted into personal-eval.jsonl upstream) or
/// `{"typo", "intentional": true}` (slangur — the user confirmed the typed
/// form IS the intended word; it must never be force-corrected). Both shapes
/// share one file, so both fields are optional here.
public struct ConfirmedIntentRow: Codable, Equatable, Sendable {
    public let typo: String
    public let intended: String?
    public let intentional: Bool?

    public init(typo: String, intended: String? = nil, intentional: Bool? = nil) {
        self.typo = typo
        self.intended = intended
        self.intentional = intentional
    }
}

/// One intentional word's auto-apply check outcome.
public struct IntentionalCheckResult: Equatable, Sendable {
    public let word: String
    public let pass: Bool
    /// The suggestion text that WOULD have force-replaced `word`, when
    /// `pass == false`. nil when it passed (no auto-apply, or auto-apply
    /// suggested the word itself).
    public let forcedReplacement: String?
}

public enum ConfirmedIntents {

    /// Parse `confirmed-intents.jsonl`, ignoring blank/comment lines (the
    /// file carries a leading `#`-comment header, same convention as
    /// `.gitignore`). Malformed lines are skipped rather than throwing —
    /// this is a small hand-edited file, not a generated corpus.
    public static func loadIntentionalWords(at url: URL) throws -> [String] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var words: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let data = trimmed.data(using: .utf8),
                let row = try? decoder.decode(ConfirmedIntentRow.self, from: data)
            else { continue }
            if row.intentional == true { words.append(row.typo) }
        }
        return words
    }

    /// For each intentional word, run it through `engine` at a NEUTRAL
    /// language posterior (P(IS)=0.5, the resting prior before any word is
    /// typed — `resetLanguagePosterior()`) with no priming context, and
    /// assert no auto-apply would fire a DIFFERENT word in its place. This is
    /// deliberately the most permissive lane the engine ever runs in for a
    /// real keystroke (a saturated IS lane only makes the conservatism
    /// invariant MORE forgiving of Icelandic-shaped slangur, never less), so
    /// a failure here is a genuine false-positive risk, not a context
    /// artifact. Slangur may still appear lower in the bar as a non-
    /// autocorrect suggestion — only a forced top-1 auto-apply is a failure.
    public static func check(engine: TypeEngine, words: [String]) -> [IntentionalCheckResult] {
        words.map { word in
            engine.resetLanguagePosterior()
            let suggestions = engine.suggestions(context: "", currentWord: word, limit: 3)
            let top = suggestions.first
            let forced = top?.isAutocorrect == true && top?.text != word
            return IntentionalCheckResult(
                word: word, pass: !forced, forcedReplacement: forced ? top?.text : nil)
        }
    }
}
