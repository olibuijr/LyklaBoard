# Eval studio — scorecard & history

The anti-overfitting scoreboard for the TypeEngine autocorrect stack
(PLAN.md "Eval studio", testing-pyramid tier 1). One command per commit
produces a JSON scorecard with hard gates; the reproducible core of that
scorecard is appended, one line, to `history.jsonl` (this directory).

Everything here is driven by `type-eval` (macOS tooling in
`Packages/TypeEngine/Sources/type-eval`, with the reusable corpus/config
logic in `Sources/EvalKit`). Data lives in `data/eval/` (read-only:
`dev.jsonl` / `heldout.jsonl`, 3,000 pairs each — see that dir's README).

## The discipline (read this first)

1. **Dev is for tuning. Heldout is report-only.** All threshold sweeps,
   weight fitting, and error analysis run against `dev.jsonl`. `heldout.jsonl`
   is **never** tuned against — no "just checking heldout" mid-iteration.
   It produces the one honest number reported at the end of a work wave /
   pre-release. `dev` and `heldout` are built from **disjoint** sentences,
   so heldout vocabulary/context/typos were never visible during dev
   generation. If heldout is ever burned, regenerate both splits with a new
   seed (see `data/eval/README.md`) and note the burn there.

2. **A tunable/ranking change is accepted only if the heldout scorecard does
   not regress.** Bug reports become scenarios (behavioral contracts in
   `Packages/TypeEngine/Scenarios/*.scenarios`), not one-off tuning.

3. **Hard gates block a release.** The scorecard exits non-zero when any hard
   gate fails:

   | gate | requirement | source |
   |---|---|---|
   | `falseAutocorrect` | **0** | micro-eval overall false-autocorrect count |
   | `validWordSafety` | pass | micro-eval: no expected word auto-replaces when typed verbatim |
   | `benchWorstLineMs` | **< 30 ms** | `type-repl bench` worst keystroke |
   | `scenarioPass` | **100%** | every scenario in every suite passes |

## Commands

```bash
# from repo root (all run against the REAL data/ artifacts unless noted)

# Replay a corpus split → per-category / per-language / overall table.
swift run -c release --package-path Packages/TypeEngine type-eval corpus dev
swift run -c release --package-path Packages/TypeEngine type-eval corpus heldout   # REPORT-ONLY

# Full scorecard: micro-eval + corpus dev + scenario suites + bench → one
# JSON, appended to scores/history.jsonl. Non-zero exit on a failed gate.
swift run -c release --package-path Packages/TypeEngine type-eval scorecard
swift run -c release --package-path Packages/TypeEngine type-eval scorecard --heldout  # adds a REPORT-ONLY heldout section

# A/B: baseline vs an EngineConfig override set, on corpus dev + micro-eval.
swift run -c release --package-path Packages/TypeEngine type-eval ab --config overrides.json

# Legacy micro-eval (DictLexicon fixture doubles, no corpus).
swift run -c release --package-path Packages/TypeEngine type-eval

# Personal-eval hard gate (LOCAL ONLY — real confirmed typing, gitignored;
# a fresh checkout / CI has no personal-eval.jsonl and this is a clean no-op,
# exit 0). Compares against scores/personal-baseline.json (also gitignored)
# and asserts every tools/session-analyzer/confirmed-intents.jsonl
# `intentional: true` word (slangur, e.g. "kozy") does not force-autocorrect.
swift run -c release --package-path Packages/TypeEngine type-eval personal
# Accept the current run as the new floor (run once a wave is accepted):
swift run -c release --package-path Packages/TypeEngine type-eval personal --update-baseline
```

### Personal-eval gate (eval-studio v2 phase 2)

`type-eval personal` is the hard-gate twin of `corpus`/`scorecard`, but over
`tools/session-analyzer/personal-eval.jsonl` — real confirmed typo→intended
pairs from the developer's own device recordings (see that tool's README).
It is **not** part of the committed `scorecard` JSON (the input is gitignored
personal data, so the line would not be reproducible for anyone else), and it
is not run in CI — it is a **local pre-commit discipline**: run it before
accepting a wave, exactly like a manual heldout check.

- Each row is tracked by a stable key, `typo|intended` (lowercased), against
  `scores/personal-baseline.json` (gitignored — derived from personal text).
- **Regression** (nonzero exit, named explicitly): (a) a row that passed
  top-1 in the baseline and fails now, or (b) any row with a NEW
  false-autocorrect, including brand-new rows — false-autocorrect is the
  metric guarded most jealously, so even a first-time row is held to it.
- **Improvement** (listed, non-gating): a brand-new row, or a row that now
  passes top-1 when the baseline didn't.
- **Slangur check** (Feature 2, the false-positive class): every
  `confirmed-intents.jsonl` word marked `"intentional": true` is replayed at
  a neutral lane posterior (`resetLanguagePosterior()`, no priming context —
  the most permissive the engine ever runs) and must not auto-apply a
  different word. A failure here is its own regression, independent of the
  baseline.
- `--update-baseline` rewrites `scores/personal-baseline.json` with the
  current run — do this once a wave's personal-gate result is accepted, so
  the next wave compares against it.
- Missing `personal-eval.jsonl` (fresh checkout, CI, no local recordings
  yet): prints a note and exits 0 — the gate is only as available as the
  local personal data, by design.

The **micro-eval** uses small curated `DictLexicon` doubles (the
`eval-fixture.tsv` + hand-assembled wordlists) — a fast conservatism control.
The **corpus** eval uses the real `data/{is,en}` lexicons + BÍN morphology +
Stage-B inflection artifacts: 3,000 pairs replayed through one reused engine
(posterior reset + context primed per pair), ~12 s for a split.

### A/B override files

An overrides file is a JSON object of `EngineConfig` knob → value. Swift has
no runtime reflection, so the A/B-tunable knobs are an **explicit** allowlist
(`EvalKit/ConfigOverrides.swift`); an unknown key is a hard error. The set
covers the corrector core & conservatism margins, the beam decoder, the
space-miss split, lane relaxation (accent restoration), the two-lane
switching model, and inflection intelligence — e.g.
`autocorrectMargin`, `autocorrectMinZ`, `beamMaxEdits`, `foldBaseCost`,
`restorationDominanceRatio`, `laneSwitchProbability`, `morphBackoffWeight`,
`minAutocorrectLength`, `foldProfileISEnabled`. Run any A/B command with a bad
key to print the full supported list. Example:

```json
{ "autocorrectMargin": 2.0, "beamMaxEdits": 2 }
```

## Reproducibility & determinism

- **Timestamp/commit come from git HEAD** (`%cI` commit time + hash), never
  `Date.now`, so re-running the scorecard on the same commit reproduces the
  same line.
- **Corpus & micro-eval run with the two wall-clock decode budgets
  (`beamTimeBudget`, `splitTimeBudget`) lifted**, so the deterministic
  expansion/position caps are the sole limiter. Without this a handful of
  hard pairs per 3,000 flip between runs on decode timing alone. Accuracy is
  what the corpus measures; latency-under-budget is measured separately by the
  bench (which keeps the shipping 6 ms budgets).
- **The committed history line records only the deterministic content**
  (commit, timestamp, corpus + micro counts, and the falseAutocorrect /
  validWordSafety / scenarioPass gates). The **latency gate is wall-clock
  volatile** (a cold first run can spike; measured 48 ms once, ~4 ms steady),
  so its measured value is logged to stderr and enforced on the **exit code**
  (with a one-shot retry to absorb cold-cache blips) — it is deliberately
  **not** written into the line. `benchWorstLineMs` appears in the JSON as its
  threshold spec only. The line's top-level `pass` therefore reflects the
  deterministic gates.

## history.jsonl format

One JSON object per line, keys sorted (deterministic bytes). Shape:

```json
{
  "version": "v0",
  "commit": "<HEAD hash>",
  "timestamp": "<HEAD commit time, ISO 8601>",
  "corpus": {
    "split": "dev",
    "overall":   { "n": 3000, "top1": ..., "top3": ..., "acFired": ..., "falseAc": ... },
    "categories": { "<category>": { "n": ..., "top1": ..., "top3": ..., "acFired": ..., "falseAc": ... }, ... },
    "byLang":     { "is": { ... }, "en": { ... } }
  },
  "heldout": { ...same shape..., "reportOnly": true },   // only with --scorecard --heldout
  "microEval": { "n": 166, "top1": ..., "top3": ..., "falseAutocorrect": 0, "validWordSafety": true },
  "hardGates": {
    "falseAutocorrect": { "required": 0, "actual": 0, "pass": true },
    "validWordSafety":  { "pass": true },
    "benchWorstLineMs": { "threshold": 30 },
    "scenarioPass":     { "required": "100%", "passed": 137, "total": 137, "pass": true }
  },
  "pass": true
}
```

Counts are integers (not rates) so re-derivation is exact. `v0` is the first
corpus-derived baseline (2026-07-16).
