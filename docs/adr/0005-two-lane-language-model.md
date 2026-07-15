# Two-lane language model for blended Icelandic/English typing

Status: Accepted
Date: 2026-07-15

## Context

Icelandic typists routinely blend in one-off English words (*slettur*)
mid-sentence without switching languages or keyboards. Both incumbents
handle this badly: Apple's per-word language identification can hijack the
whole keyboard mid-sentence when it misreads a loanword; SwiftKey caps
users at 2 simultaneous language packs and has a long-running, still-active
complaint thread (`research/swiftkey-frustrations.md` #4/#5) about the
keyboard switching languages or inserting unwanted spaces on multilingual
input. Neither treats "one foreign word" and "the user actually switched
languages" as different situations.

A naive approach — a flat exponential moving average (EMA) over recent
per-word language evidence — was considered and rejected: a single
attested-English word would drag the running average toward English by the
same amount whether it's one *sletta* in an Icelandic sentence or the start
of an actual English sentence, and it has no notion of "stickiness" (a
confident lane shouldn't be knocked over by one word) versus "decisiveness"
(a real language switch should be recognized quickly, not averaged away
over many words).

## Decision

Model bilingual typing as a **two-lane switching model** (an HMM-shaped
sticky-lane design), not a flat EMA:

- Typing is assumed to be in one of two lanes: **Icelandic-with-slettur**
  or **English**. Lanes are sticky but not strict — the other language's
  candidates are never blocked, only discounted.
- Per-word language evidence is a **calibrated z-margin**, not a binary
  in/out-of-lexicon flag, and this evidence **decays with distance** from
  the current position (recent words count more).
- A **low lane-switch prior** absorbs a single *sletta*: one off-lane word
  barely moves the posterior. **2–3 consecutive** other-language words are
  what actually flips the lane.
- Next-word prediction after a single *sletta* reverts to predicting in the
  current lane's language — a one-off loanword doesn't retarget prediction.
- The posterior decays toward a neutral prior across sentence boundaries
  and long typing gaps, so a lane doesn't stay artificially locked forever.
- Personal (learned) words contribute **no lane evidence** in v1 — see
  ADR-0008 — to keep the language-identification signal clean and
  independent of what the ranking boost is doing.

Implemented in `Packages/TypeEngine/Sources/TypeEngine/LanguageModel.swift`
and exercised end-to-end in `TypingSession.swift`; shipped per git history
as "two-lane HMM language model (slettur-aware blending)."

A real calibration bug was found and fixed during this work, worth
recording because it shapes how lane evidence must be read going forward:
cross-language probabilities are **not directly comparable** — `his` was
observed to outrank `hús` even at a strong P(IS)=0.79 posterior, because
IS and EN lexicon frequencies come from differently-scaled corpora
("apples to oranges" — see PLAN.md "Engine follow-ups"). The fix is
per-lexicon calibration of the z-margin, not further posterior tuning; this
is why lane evidence is expressed as a calibrated z-margin rather than a raw
frequency ratio.

## Consequences

- A single *sletta* never flips the keyboard's effective language, directly
  fixing the incumbents' worst-documented multilingual complaint; a real
  language switch (2–3 consecutive words) is still recognized promptly.
- The lane posterior is a first-class signal other engine components read:
  autocorrect margins, next-word prediction targeting, and (planned, not
  yet shipped — see "future direction" below) accent-restoration cost all
  key off it.
- Correct behavior depends on keeping cross-lexicon frequency scales
  calibrated against each other; this is an ongoing engineering discipline,
  not a one-time fix, and any new lexicon added to a lane must be
  calibrated before it can safely contribute z-margin evidence.
- **Future direction (not yet built):** "lane relaxation" — using the lane
  posterior to make accent restoration and other language-specific
  orthographic normalizations cheaper inside a confident lane (e.g. folding
  `a`→`á` for free once P(IS) is high) — is a planned extension of this
  model, designed but not implemented as of this writing. It is out of
  scope for this ADR.
- Related: ADR-0006 (autocorrect discipline consumes lane evidence for
  margins), ADR-0008 (personal words are explicitly excluded from lane
  evidence).
