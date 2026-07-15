# Personal ranking integration: additive boost, not probability renormalization

Status: Accepted
Date: 2026-07-15

## Context

Once a word is learned (ADR-0007), it needs to outrank the base language
model without breaking the rest of the ranking system. Two integration
strategies were available: fold personal counts into the base unigram/
bigram probability mass (renormalizing the distribution), or treat personal
attestation as an independent additive signal layered on top of the
existing score. Renormalizing is the more "principled" probabilistic
choice on paper, but personal token totals are tiny relative to the base
lexicons (a few hundred to a few thousand observations per user versus
hundreds of thousands to millions of corpus tokens per lexicon) — folding
them into the same probability mass would require either inflating personal
counts to compete (undermining the probabilistic meaning of the base
model) or accepting that they'd almost never move the ranking at all
(defeating the point of learning). The two-lane language model (ADR-0005)
also depends on lexicon-level frequency evidence staying clean and
calibrated across languages; mixing in personal counts at that layer would
reintroduce exactly the cross-scale calibration problem ADR-0005 had to fix
for IS/EN blending.

## Decision

Personal attestation is an **additive score bonus**, computed once per
word/bigram and added on top of the calibrated base-model score — never a
probability renormalization. Implemented in
`Packages/TypeEngine/Sources/TypeEngine/LanguageModel.swift` /
`PersonalVocabulary.swift`:

- `personalBoost(of:previous:)` returns
  `min(personalBoostCap, personalBoostBase + personalBoostScale ×
  log(1 + count))` for any word attested in the personal vocabulary — a
  flat base bonus (ensuring even a lightly-seen personal word gets *some*
  lift) plus a log-scaled term (so heavily-typed words get more, with
  diminishing returns), capped so no personal word can dominate scoring
  unboundedly (`personalBoostBase = 2.0`, `personalBoostScale = 0.75`,
  `personalBoostCap = 6.0` nats, in `LanguageModel.swift`).
- **Personal words are excluded from lane evidence** (ADR-0005): a
  personal-vocabulary hit contributes zero signal to the Icelandic/English
  lane posterior, even though it does raise the word's own ranking score.
  This keeps language identification driven purely by calibrated base-lexicon
  attestation — a user's personal English proper nouns, for instance, must
  not be able to drag the lane posterior toward English.
- Personal boosts apply immediately within a typing session as words are
  learned — this is "session-immediate learning": a word does not need to
  survive to the next app launch or sync cycle to start influencing
  ranking; the in-session personal vocabulary state feeds the boost as
  soon as `PersonalModel` records it as learned (ADR-0007's 2-day/explicit
  threshold still gates whether a word is "learned" at all, but once
  learned, its boost applies immediately, not on next app launch).

## Consequences

- Personal ranking cannot corrupt the base model's calibrated
  cross-language scoring (ADR-0005) — the two concerns are architecturally
  separated (lane evidence vs. score boost), so tuning one never risks
  destabilizing the other.
- The additive-with-cap design bounds how much a single learned word can
  ever dominate a suggestion, keeping the system's autocorrect
  conservatism (ADR-0006) intact even for heavily-typed personal words.
- The boost formula's constants (`personalBoostBase/Scale/Cap`) are tunable
  parameters, evaluated the same way as any other engine constant — via the
  eval studio's dev/heldout discipline (ADR-0010), not ad hoc.
- Related: ADR-0005 (lane evidence exclusion), ADR-0007 (defines what
  "learned" means and supplies the counts this boost consumes).
