# Wave ledger

One entry per engine/tooling wave: what triggered it, what was decided and WHY,
what changed, how it was gated. This is the hill-climbing memory — read it
before designing a wave so decisions compound instead of thrashing. Scores live
in `scores/history.jsonl`; behavioral contracts live in
`Packages/TypeEngine/Scenarios/*.scenarios` (scenario comments cite sessions);
architecture in `docs/adr/`. Newest first.

## Standing doctrine (violating these needs an ADR, not a wave)

- **Conservatism invariant**: a word valid in either language is never
  auto-replaced (oblique-only dominance fallback is the one exception). The
  verbatim escape hatch is always in the bar.
- **Surface forms are ground truth**: Icelandic wordform overlap is extreme;
  learned vocabulary is byte-exact. Lemma-level lifting only when unambiguous.
- **Bidirectional tap evidence**: near-miss taps *enable* corrections,
  dead-center taps *veto* them — but restoration pairs (acute folds, d↔ð)
  never veto: the base letter is the only key that exists, so a dead-center
  tap is the lazy-input signal FOR restoration.
- **Lane relaxation**: diacritics are an input method, not errors. Acute
  vowels fold near-free inside a saturated IS lane; apostrophes/lone-i mirror
  in EN. Long-press is an absolute deliberateness veto.
- **Eval discipline**: never tune on a single report; dev corpus for tuning,
  heldout run once per wave and never tuned against; personal-eval.jsonl
  (real confirmed typing) must never regress. False-autocorrect is the metric
  we guard most jealously — uncorrected dogfood under-reports it, so dogfood
  recordings are made WITH manual corrections. Gate command (local only, real
  typing data is gitignored): `type-eval personal` against
  `scores/personal-baseline.json`; `--update-baseline` accepts an accepted
  wave's result as the new floor (scores/README.md "Personal-eval gate").
- **Extension privacy**: the keyboard extension has zero network/iCloud
  entitlements, forever. Sync and export live in the containing app.

## 2026-07-17 — Wave 27: context-ranking (bigram evidence at ranking/margin time)

- **Trigger**: the largest tracked class in the session-analyzer top-gaps
  table (9 real findings): the intended word is GENERATED but outranked or
  under-margined exactly where the previous word's bigram should decide.
  Named targets: gret→grét ("son minn ég gret": grét led on the "ég grét"
  bigram but sat 0.469 nats over the runner-up against the 0.5 restoration
  margin — the blocker was the completion "greta", morph-BOOSTED +1.19 nats
  because "ég" is a governor and greta fits nominative, while grét's EXACT
  bigram evidence earned no extra weight); vli→false "vil" fire (z +1.48,
  margin 2.7 over junk — but "en" does not select vil: contextual lift
  −0.18σ); mew→með absent from the bar; habb→hann (wave 24's fix) to
  protect.
- **Decided — one currency, four seams**: contextual LIFT = z(w|prev) − z(w)
  in the lane language (calibrated σ; sign ≈ PMI — "ég grét" +1.26σ, "en
  vil" −0.18σ, unattested pairs are nil, never negative evidence).
  (1) **Fold-twin bigram context backoff**: a previous word attested in
  neither lexicon reads bigrams through its dominant acute-fold twin
  (eg→ég via the wave-26 `acuteFoldShadowTwin` gates) — diacritics are an
  input method, for the context word too. Dev-inert (synthetic contexts are
  attested); it is what makes the raw-context personal replay of "Eg gret"
  rank grét at all. (2) **Bigram-dominance margin relief**: winner lift ≥
  0.75σ and a lift-less (unattested or ≤ 0) runner-up → required margin
  ×0.7. Junk-tier winners excluded — the junk margin scaling stands.
  Sweeps: minLift 0.5 leaked 2 false fires, relief at 0.7 adds 6 correct /
  1 false on dev (~86%, the historical margin-band precision). (3)
  **Context-backed 3-char discipline**: an error-class rewrite of a
  3-letter token WITH a present previous word needs winner z ≥ 1.5 unless
  lift ≥ 0.25 vouches (vil +1.48/−0.18 blocked; eru +2.51, það +2.82, vel
  +1.97 fire; "krakkarnir eru" lift +1.16 would fire even sub-floor).
  Floor-off leaked 3 false of 6 fires (50% — bad band); 1.75 removed 3
  correct fires. No-context tokens (sentence-initial, fixtures) keep the
  pre-wave rules — the rule is "the context was consulted and declined to
  vouch". Restoration-only winners exempt (own gate stack). (4)
  **Bigram-continuation proposals** (3-4 char unknown tokens only):
  followers of the fold-backed previous word, shape-prefiltered (same
  first letter or restoration twin, length ±1), z ≥ 1.0 (the double-sub
  context tier), channel cost ≤ 5.5 — context proposes, the typed keys
  verify. The only path to a word outside every short edit budget ("en
  vli" → væri = insert-r + l→æ; væri sits rank 300–450 in "en"'s fan-out,
  hence pool 500). Follower scan memoized per context word
  (ContinuationProposalCache) — warm cost ~0, one cold 20k-row scan can
  spike (measured 40 ms once; warmUp + scorecard cold-retry absorb it).
  UNRESTRICTED the pass cost dev top-1 −0.17pp (bigram-supported
  near-followers outranked honest repairs on long tokens) — short-only +
  z floor brought the whole wave to −0.03pp.
- **Honesty**: mew→með stays a bar miss — w→ð is 9 keys apart (spatial 8
  nats); pricing a w→ð confusion from ONE observation is a point fix,
  declined (and mew is en.lex-attested, so it commits as typed under the
  invariant regardless). vli: the false fire is dead (the REQUIRED half),
  væri surfaces in the bar. gret: fires in the typed line (lane 0.88);
  the raw-context eval replay ranks grét top-1 unforced (lane barely
  primed — offering, not forcing, is right there). Corrected the
  pipeline's mis-guessed personal row gret|gert → gret|grét ("Eg gret og
  gret." = grét, the next sentence's "get gert" had leaked into the
  guess) and registered the confirmed intent.
- **Gates**: dev 2340 top-1 / 122 false-ac vs 2341/123 (−0.03pp top-1,
  within the 0.2pp gate; false-ac DOWN 1); heldout (once) 2288/162 vs
  2289/162 (false-ac flat, top-3 +4); personal gate 29 rows top1 16
  falseAc 4 (was 15/28, falseAc 5) — the vli row flipped falseAc→safe,
  zero regressions, baseline updated; scenarios 199/199 ×3 (7 new dogfood:
  both fixed targets, the habb guard, the mew honesty contract, and 3
  counters — vrl→vel mid-tier 3-char still fires, gwrt→gert wins after ég
  despite grét's bigram, greta verbatim untouched); swift test 402 green;
  bench warm max ~3.5 ms (category worst ~4.5 ms, gate 30). Tooling: repl
  `:bigram <prev> <w>` probe + `TypeEngine.bigramDiagnostics`.

## 2026-07-17 — Wave 29 phase 2: personal gate, slangur registry, pIS recording

- **Trigger**: wave 29's phase-2 queue — personal-eval as a hard wave gate
  (wave 26's learning self-poisoning was byte-identical on the synthetic dev
  corpus; only a personal snapshot reproduced it), a registry check for
  confirmed-intentional slangur (kozy-class), and recording the engine's own
  lane posterior alongside real typing sessions.
- **Decided**: `type-eval personal` (EvalKit `PersonalEval.swift` +
  type-eval `Personal.swift`) replays `tools/session-analyzer/
  personal-eval.jsonl` (gitignored, real confirmed typing) keyed per-row by
  `typo|intended` (lowercased) against `scores/personal-baseline.json`
  (also gitignored — derived from personal text). Gate: (a) a baseline
  top-1 pass that fails now is a REGRESSION; (b) any NEW false-autocorrect —
  including on a brand-new row — is a REGRESSION (false-ac stays the most-
  guarded metric, held even for rows with no baseline history); (c) new or
  newly-passing rows are improvements, listed but non-gating.
  `--update-baseline` rewrites the baseline after a wave is accepted. A
  missing personal-eval.jsonl (fresh checkout, CI) is a clean no-op, exit 0
  — the gate is only as available as the local personal data, by design.
  Same command additionally loads `confirmed-intents.jsonl`'s
  `intentional: true` rows and replays each at a NEUTRAL lane posterior (no
  priming context — the most permissive the engine ever runs a keystroke
  in), asserting no forced auto-apply; a failure is its own regression
  (false-positive class), independent of the baseline.
- **pIS recording**: `SessionRecorder.recordPass` gained an optional
  `pIcelandic` parameter; `BetterKeyboardAutocompleteService` threads
  `session.probabilityIcelandic` (the same accessor `type-repl`'s `P(IS)`
  prints) through on every pass. Encoded as `pIS` (3 decimals) in
  `kb.jsonl`, omitted (not `null`) when absent — Swift's synthesized
  `Encodable` calls `encodeIfPresent` for `Optional` properties, verified
  with a throwaway encode. `analyze.py`'s `KBRecord` construction reads
  fields via `dict.get(...)` one at a time (no `**r` splat) — confirmed by
  reading it (read-only; the analyzer itself is another agent's scope this
  wave) — so the new key is additive and silently ignored until the
  analyzer opts in.
- **Gates**: established the initial baseline against commit `24d7ec0e`:
  25 personal rows, top-1 13/25, autocorrected 14, falseAc 4 — matches the
  discipline note above (these rows are drawn FROM real corrector misses,
  so a lower top-1 rate than the synthetic corpus is expected, not a
  regression). Slangur check 1/1 (kozy survives unforced). 13 new unit
  tests (EvalKitTests/PersonalEvalTests.swift) against a fixture baseline
  and a DictLexicon fixture engine — never the real personal file. Dev
  corpus byte-identical to wave 22 (no Corrector/LanguageModel touched);
  192/192 scenarios; swift test green (402 tests); simulator build green
  (xcodegen + Debug/iOS-Simulator).

## 2026-07-17 — Wave 29: eval-studio v2 (tooling, in flight)

- **Trigger**: process review — iteration loop is dogfood recordings; needed
  context-efficient triage, compounding evaluations, roadmap from data.
- **Decided**: findings are pre-triaged against a class taxonomy (known vs
  NOVEL); lane posterior timelines rendered per session (Love-Island
  whiplash signature); AGGREGATE.md leads with a top-gaps table = the
  next-wave queue. Phase 2 after wave 22: personal-eval as hard wave gate,
  slangur registry, pIcelandic recorded per pass.

## 2026-07-17 — Wave 22: compound acceptance

- **Trigger**: stökklrikanum→stökkleikanum UNRESOLVABLE (session
  2026-07-16T14-59-28); Icelandic compounding is productive, no lexicon holds
  it all. Symmetric hazard: valid OOV compounds get no conservatism shield.
- **Decided**: port the BinPackage/Greynir decomposition RULES
  (TypeEngine/Compounds.swift): head = longest BÍN suffix in an OPEN class
  (no/so/lo — their `_OPEN_CATS`), carrying the inflection; modifier = noun
  genitive (indefinite — the -s-/-ar-/-a-/-u- linking letters ARE genitive
  endings, no separate machinery), noun stem slot (kk þf.et / kvk nf.et /
  hk nf|þf.et), or strong-positive adjective genitive; ≤ 2 modifiers.
  Modifier legality reads paradigms.bin (only artifact with the
  DEFINITENESS bit — rule precision vs Miðeind's shipped prefix list is
  0.83 with it, 0.43 without; its lemma-freq≥10 floor stands in for their
  curation). BÍN's 358 bound suffix forms (ord.suffix.csv utg=-1:
  -leikanum, -menningur…) embedded as a static set — "leikanum" exists in
  no other artifact. Deviations, all tightening: min part lengths 4/4
  (dev sweep: 3/3 protects 2.7% of typo rows, 4/4 → 1.2%, positives kept),
  no adjective stems, no suffix-removals port, no tantum demotion.
- **Wiring — protection ≠ generation**: compound validity feeds ONLY the
  auto-apply veto (`isProtectedTypedWord`) + the restoration branch (lazy
  skeletons like "tungumal"=tungu+mal still restore via the triple gate);
  generation passes still gate on raw validity, so suggestions/splits for
  compound-shaped tokens are unchanged (protecting the split OFFERS was
  worth −1.3pp top-1 in the naive wiring). Repair pass 5b holds a legal
  modifier prefix fixed and single-edits the head — ERROR-class subs only
  (fold-priced twins walked junk compounds over honest repairs:
  prentletu→"prent+létu"), no strict-prefix extensions (completion pricing
  0.5/char structurally beats splits: "fimmtabókin"→"fimmtabókina"),
  generated heads need z ≥ −1.6 (junk tier "legan"/"legs" flooded the
  faralega bar), gate 4.5 (an honest single-insert repair at 4.0 —
  eldsnyti→eldsneyti — must shut the pass). Compounds score at frequency
  floor 1, STRICTLY below the BÍN floor 2: a whole word BÍN attests
  outranks any hypothesized decomposition at equal cost, mirroring
  Miðeind's whole-word-lookup-first order. Compound completions
  (stökklei→stökkleikur) built but DEFAULT OFF pending completion-specific
  pricing (wave 23 with the Kirkjubæjarklaustur split-case class).
- **Gates**: dev A/B compound on-vs-off: top-1 +0.13pp, false-ac ±0.00pp,
  ac-fired −0.60pp (protection veto); 192/192 scenarios ×3 (new
  compounds.scenarios: flagship offer, 4 typed-valid compounds protected,
  linking-letter case, dlmk/habb/eotthbap unharmed); swift test green both
  packages; bench max 3.2–6.1 ms (gate 30).

## 2026-07-17 — Small wave: sync staging leak + analyzer junk-tier gap (87b4b73, f4e7686)

- **Trigger**: 21×1.6MB lyklabord-sync-*.bin leaked in app tmp; analyzer
  missed "lss"→las because is.lex attests web junk.
- **Decided**: staging file deleted on success AND failure + day-old sweep at
  sync start. Analyzer: an is.lex attestation only counts when BÍN knows the
  word or z ≥ −1.0 — **BÍN validity is the signal separating junk from rare
  real words**, a pure z floor cannot (gil/snefil sit at lss's z).

## 2026-07-17 — Wave 28: stale-autocorrect apply guard (da3ed4d, 1f3b627)

- **Trigger**: "Lovr"+space applied the PREVIOUS word's autocorrect
  ("Þátturinn Þátturinn", Love destroyed), session 2026-07-17T08-30-35 —
  async race between engine queue and autocompleteContext at delimiter time.
  Collateral: mangled word flipped lane posterior, blocking a→á downstream.
- **Decided**: every bridged suggestion already carries its pending token
  (pendingTokenInfoKey); auto-apply refuses on token mismatch
  (AutocorrectApplyGuard, pure + unit-tested, fail-closed on missing stamp);
  delivery side drops results superseded by a newer request for different
  text. Ledger unaffected (snapshots actual before→after, nothing pre-armed).
  Skipped applies recorded as kind "stale-skip" — recurrence = regression.
- **Note**: 1f3b627 restored the CloudDocuments entitlement the wave's cleanup
  had mistakenly reverted (generated file lagged the committed spec).

## 2026-07-17 — CloudDocuments entitlement (dead70b)

- **Trigger**: OTA session export never reached the Mac; ubiquity folder
  never materialized.
- **Root cause**: icloud-services listed only CloudKit — CloudDocuments is
  the service that actually runs iCloud Drive document sync. Bundle version
  bumped 1→2 (iCloud Drive re-reads NSUbiquitousContainers only on version
  change). App-only; extension keeps zero iCloud.

## 2026-07-16 — Wave 26: learning self-poisoning (b458efe)

- **Trigger**: session 2026-07-16T22-45-30 — mid-sentence Title Case
  (furir→Fyrir, frabær→Frábær, nyju→Nýju, syba→Sýna) and dead restoration
  (þvi/þer/gret/eg/sa silent, bar ranked accented form 0.8–0.99 but ac=false).
  Device-only; harness reproduced ONLY with PERSONAL seeds → root cause was
  in-memory learned vocabulary, not code/data drift.
- **Decided**: (1) leading-cap learned surface folds to pipeline casing when
  lowercase is common base vocab (typicality test, NOT BÍN casing —
  lemma-is.bin lowercases everything); sentence-initial commits strip autocap
  at capture. Miðeind-class OOV caps preserved. (2) implicitly-learned pure
  acute-fold twins of ≥10×-dominant base words lose the conservatism veto;
  their personal counts TRANSFER to the twin (the lazy commits were commits
  of the twin — this transfer is what made grét clear the margin). Explicit
  adds, verbatim taps, tombstones keep full veto.
- **Gate note**: dev corpus byte-identical (machinery inert without personal
  snapshot) — personal-state bugs are invisible to the synthetic corpus,
  hence phase-2 requirement that personal-eval gates waves.

## 2026-07-16 — Wave 24: session-findings precision wave (08f4ae1)

- **Trigger**: first four real recordings (kozy→jozy false fire, læt.hann
  dotted-escape, sivan→síðan v↔ð, MEÐ/NEW all-caps bar junk, hega→geta).
- **Decided**: junk-tier margin scaling (winner z < −1.0 → margin ×3) instead
  of a blunt z floor — A/B showed 88% of blunt-floor removals were CORRECT
  fires; v→ð directional confusion priced; all-caps learned-surface guard
  (precursor of wave 26's full fix); determinism: childList byte-sorted.
- **Also**: context-vouched short-double-sub admission (20a5ab1): edit-cost
  cap 1.2→1.4 (g→t vertical-diagonal ≈1.25 nats) + admission requires
  attested bigram with previous word + calibrated z ≥ 1.0 — blunt z lowering
  regressed corpus top-1 by 0.10pp, context vouching didn't.

## 2026-07-16 — Session pipeline (ab8d3a8, dda3396, 6007645, ed2fb78)

- Recorder (dev-mode pad only, dual JSONL + tap coordinates + bar snapshots),
  analyzer v2 (silent-miss scan via type-repl attestation, alignment fix),
  proxy-edit ledger (azooKey pattern — exact self-edit attribution so user
  edits aren't misread as engine corrections), OTA via user's own iCloud
  ubiquity container, build stamping (engineCommit; "+dirty" is a false
  positive — the stamp script dirties its own tracked file), aggregates.
- **Decided**: recordings are personal data — sessions/, personal-eval.jsonl,
  confirmed-intents.jsonl gitignored forever.

## 2026-07-16 — Confirmed-intents (27b9e54)

- **Trigger**: analyzer pending-review queue had no way to absorb the user's
  answers ("dlmk = dæmi").
- **Decided**: confirmed-intents.jsonl maps typo→intended (or intentional:
  true for slangur like "kozy") and promotes contested/UNRESOLVABLE silent
  misses into personal-eval.jsonl with source=user-confirmed. Intentional
  marks are the seed of the slangur registry.

## Pre-ledger foundation (2026-07-15 and earlier, see ADRs + git log)

Beam decoder over lexicon prefix ranges; two-lane HMM (switch 0.08, calibrated
z emissions, sletta absorption); lane relaxation (FoldPricing, skeleton-
collision triple gate); per-tap 2D Gaussians (TSI-seeded σ); inflection
paradigms + statistical governors (P(þgf|frá)=0.675); learning/EventLog with
2-distinct-day promotion + tombstones; AES-GCM sync with roaming keychain key;
KeyboardKit vendored at 9.9.1 (last MIT tag); verbatim/URL protection layers;
spacebar 3 modes; eval studio v1 (dev/heldout 3000 pairs, disjoint; scorecard
hard gates: false-ac=0 on micro-set, <30ms, all scenarios).
