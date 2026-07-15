# Autocorrect conservatism: under-correct by design

Status: Accepted
Date: 2026-07-15

## Context

`research/swiftkey-frustrations.md` ranks "autocorrect & word prediction
failure" as the #2 complaint theme against SwiftKey iOS (2022–2026,
unresolved): it overwrites correctly-typed words with unrelated ones and
fails to learn from correction, and Apple's own Icelandic autocorrect is
documented as replacing common words with rare ones. The shared root cause
in both cases is a system willing to auto-replace a token the user may have
typed deliberately. The project's guiding philosophy, stated repeatedly in
PLAN.md, is the inverse of both incumbents: **under-correct rather than
over-correct**.

A concrete dogfood bug crystallized the escape-hatch requirement: typing
"profilmynd." was auto-corrected mid-word, and the correction did not
gracefully undo when the user kept typing past the trigger point
("prófílmynd." → user types "t" → wrong state). This is the origin of the
"verbatim escape hatch" and dotted-token rules below (git: "verbatim
escape hatch + URL/email handling").

A related discovery from the eval harness (git: "quirk wave — data,
ranking, latency, and robustness fixes"): the naive candidate-generation
approach (generate-and-test edit-distance-2 candidates) cost 15–30ms/word in
estimation but 300–935ms/keystroke in worst-case measurement — a latency
problem that interacts with correctness, since a slow corrector under
typing pressure creates exactly the race conditions (stale reads, cursor
jumps) that produce bad corrections.

## Decision

Layer several independent, conservative rules rather than relying on one
confidence threshold:

1. **Never auto-replace a word that is valid** in either language (the
   "attested-winner" rule) — a word in the user's dictionary or either base
   lexicon is never silently overwritten.
2. **Verbatim escape hatch**: the literal typed token, quoted, always
   occupies one suggestion-bar slot (KeyboardKit's `.unknown` suggestion
   type renders quoted). Tapping it commits verbatim and suppresses
   correction for that token. This is the universal fallback underneath
   every other rule.
3. **Field-kind gating**: autocorrect is fully off when the keyboard type
   is URL, email, or web search (suggestions may still appear).
4. **Dotted-token rule**: a pending token containing an internal dot (the
   shape of a URL, domain, `e.g.`, or `file.ext`) is verbatim-class — no
   autocorrect, and no correction of subsequent dot-segments either.
5. **Revert-on-continuation**: if a letter arrives immediately after a
   dot-triggered auto-replace with no intervening space, the correction
   auto-reverts. This is what makes rule 4 self-healing for the
   "profilmynd." case: the correction fires at the dot (sentences always
   have a space after the period), but a domain/filename continuing past
   the dot un-does it.
6. **One-tap revert** for any applied autocorrection.
7. **Margin rule**: replacement is suppressed when two inflected forms of
   the same lemma tie (e.g. `hestur`/`hestar`) — a known-imperfect
   heuristic, flagged in PLAN.md as a candidate for refinement (margin
   against the *typed* word rather than between candidates) but not yet
   changed.

Rules 3–5 together prevent the URL/dotted-token failure mode; rule 2 is the
universal escape hatch for everything else. This is deliberately layered,
not a single global confidence knob — each rule targets a distinct known
failure mode found either in research or in dogfooding.

## Consequences

- The system provably cannot silently destroy a deliberately-typed valid
  word — this is the single hard invariant the eval studio (ADR-0010)
  gates on as a hard failure (`valid-word-replacement=0`), not just a
  metric to improve.
- Under-correction has a real cost: some genuine typos go uncorrected that
  a more aggressive system would catch. This is an accepted trade-off,
  consistent with ADR-0001's positioning against both incumbents' documented
  failure mode of over-confident wrong corrections.
- Candidate-generation latency is now a correctness-adjacent concern, not
  purely a performance one — the 300–935ms worst case discovered by the
  harness is flagged as an open engineering item (replace generate-and-test
  edit-distance-2 with a SymSpell delete-index plus a Bloom prefilter before
  BÍN lookups) rather than resolved; this ADR records the conservatism
  design, not that follow-up fix.
- **Future direction (not yet built):** "lane relaxation" reframes
  accent-dropping as a fast input method rather than a typo inside a
  confident Icelandic lane, with its own dominance/context/deliberateness
  gates layered on top of the rules above. This is designed in PLAN.md but
  not implemented, and intentionally excluded from this ADR's scope.
- Related: ADR-0005 (lane posterior informs correction context), ADR-0010
  (eval studio enforces the hard invariants named here as scorecard gates).
