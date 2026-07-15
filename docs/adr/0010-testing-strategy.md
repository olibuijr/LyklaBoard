# Testing strategy: pyramid, headless harness, eval-studio discipline

Status: Accepted
Date: 2026-07-15

## Context

An autocorrect/prediction engine has no simulator or UI-automation path
that catches ranking regressions — a single bad tuning change can silently
make suggestions worse without any test failing, and iOS keyboard
extensions add real device constraints (memory cap, the
`UITextDocumentProxy` contract's quirks) that a plain unit test can't
exercise. The project needed both a fast, deterministic, headless
development loop (the engine has to run and be testable outside Xcode/the
simulator entirely) and a way to guard against overfitting the engine to
whatever bug report was most recently filed.

Two concrete problems drove the design:

- The harness itself found real bugs invisible to naive unit testing: the
  proxy-contract simulation surfaced that candidate generation cost
  300–935ms/keystroke in the worst case (not the estimated 15–30ms),
  contractions were silently destroyed by the English lexicon's build
  filter (`don't` → `dont` → autocorrected to `Ibm`), next-word prediction
  was returning empty completions, and sentence-truncation was erasing
  bigram context — none of these were caught until an actual
  `UITextDocumentProxy`-shaped simulator exercised the real typing session
  path (git: "quirk wave" commit fixing these).
- Tuning against bug reports alone risks overfitting: a threshold change
  that fixes today's reported typo can silently regress accuracy on typing
  patterns nobody happened to report. The project needed a held-out
  measurement that is never touched by tuning, to catch that.

## Decision

A four-tier pyramid, from fastest/most-isolated to slowest/most-realistic:

1. **Package unit tests** (`LemmaCore`/`Lexicon`/`TypeEngine`, via `swift
   test`) plus a **micro-eval** command (`type-eval`) for fast
   spot-checking of ranking behavior.
2. **Headless harness** (`type-repl`): an interactive REPL plus a
   **scenario regression file** format (`Scenarios/core.scenarios`,
   `Scenarios/dogfood.scenarios` — 81 behavioral scenarios per the current
   suite, run via `swift run -c release type-repl run Scenarios/core.scenarios`)
   and a latency bench, all driving the extension's *exact*
   `TypingSession` code path through a `ProxySimulator`
   (`Packages/TypeEngine/Sources/TypeEngine/ProxySimulator.swift`) that
   models the real `UITextDocumentProxy` contract: truncated context
   windows, cursor jumps, host-side mutations, and stale reads — the same
   surface that produced the real bugs listed above. Scenario files are
   written as **behavioral contracts derived from real bug reports** (e.g.
   the dogfood-found "profilmynd." verbatim/URL bug, the "smelirna"
   space-miss case) — a regression in a previously-fixed bug is a scenario
   failure, not a rediscovery.
3. **Last-mile replay rig (planned, not yet built)**: an XCUITest host app
   that replays *timed*, per-keystroke human typing traces — real touch
   x/y and timestamps from public datasets (Google TSI, CC-BY-4.0, 43,735
   touch taps with pixel-level coordinates; Aalto ITE, CC-BY-4.0, tens of
   thousands of participants with autocorrect-interaction events) — as
   accessibility-layer taps, since no Icelandic timed-touch dataset exists;
   Icelandic traces would be synthesized from corpora plus dataset timing
   distributions plus the engine's own spatial-model noise, and clearly
   labeled synthetic, never mixed into human-trace metrics
   (`research/typing-datasets.md`). This tier is designed but not
   implemented as of this writing — recorded here as planned scope, not a
   completed decision.
4. **Device dogfooding** for host-app variance and feel that no simulation
   captures.

**Eval-studio anti-overfitting discipline**, layered across tiers 1–2:

- **Corpus-derived eval, disjoint dev/heldout split.** Thousands of
  typo→intended pairs are generated from Icelandic and English Wikipedia
  sentences (CC BY-SA 4.0; 7,183 IS / 7,598 EN sentences from 631/403
  articles respectively) via a deterministic error model covering
  adjacency on the Icelandic layout, accent-drop, space-miss, and
  contraction damage. Sentences are split into disjoint pools **before**
  pair generation, so no heldout sentence's vocabulary or context was
  visible during dev-pair generation. Current corpus produces 3,000 dev
  pairs and 3,000 heldout pairs (1,500 IS + 1,500 EN each).
  `data/eval/heldout.jsonl` **is never tuned against** — no threshold
  sweeps, no weight fitting, no exploratory error analysis feeding back
  into engine changes against it; if it is ever burned, both splits are
  regenerated from a new seed and fresh corpora, and the burn is recorded.
  (The IFD corpus, `lemma-is`'s sibling gold-tagged dataset, was
  considered and rejected for this purpose: its CLARIN license is
  research-only and explicitly forbids giving third parties access to any
  part of the corpus — incompatible with a public repo.)
- **Unified scorecard**: a single command combining eval-category
  accuracy, a **false-autocorrect ceiling** (hard gate), **valid-word-
  replacement = 0** (hard gate — the invariant named in ADR-0006), scenario
  pass rate, and latency percentiles, written per-commit to
  `data/eval/scores/history.jsonl`, with a config A/B diff mode. (Wiring of
  this scorecard into `type-eval` is queued behind other engine work as of
  this writing — the data half, `data/eval/`, already exists and is
  described above.)
- **Process rule**: real bug reports become tier-2 scenarios (behavioral
  contracts); any tunable or ranking change is accepted **only if** the
  held-out scorecard does not regress. A change that fixes a scenario but
  regresses heldout is not an acceptable trade.

## Consequences

- The engine is fully testable without Xcode, the iOS Simulator, or any
  device — a deliberate choice that makes the fast dev loop (tiers 1–2)
  cheap enough to run on every change, while device dogfooding (tier 4)
  is reserved for what genuinely can't be simulated.
- Bug reports strengthen the regression suite permanently instead of being
  fixed once and forgotten — but this only works because scenario files are
  treated as contracts, not disposable debugging aids.
- The heldout/dev split is only as trustworthy as the discipline around it;
  this ADR records the rule, not an automated enforcement mechanism — the
  scorecard wiring that would make a heldout regression a hard CI gate is
  not yet built.
- The last-mile replay rig remains explicitly aspirational; no touch-
  coordinate plumbing exists in the engine yet (see ADR-0005's "future
  direction" note on lane relaxation and the separate, unimplemented
  "touch decoding" work in PLAN.md) — this ADR does not claim that tier is
  complete.
- Related: ADR-0006 (the hard gates the scorecard enforces), ADR-0005 (lane
  relaxation and lane-scaling scenarios are a stated future eval category,
  not yet built).
