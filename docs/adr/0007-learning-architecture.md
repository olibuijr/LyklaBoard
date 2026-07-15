# Learning architecture: App Group event log, privacy invariants, surface forms as ground truth

Status: Accepted
Date: 2026-07-15

## Context

SwiftKey's learning is a documented failure mode on two axes
(`research/swiftkey-frustrations.md`): the "learns your typing style" claim
doesn't materialize in practice (words forgotten, unrelated words
suggested), and — the more severe trust problem — there is **no way to
permanently remove a learned word**; Microsoft's own support confirms this
and offers only a full data wipe as a workaround (#8 in the frustrations
report). A privacy-first keyboard also cannot let raw keystrokes leave the
extension process: only the extension ever sees what the user actually
types, so any learning pipeline must draw its privacy boundary at the
extension/app process split, not inside a single trusted component.

Separately, Icelandic morphology creates a data problem specific to this
project: surface forms overlap heavily across lemmas (lemma-is measures an
average of 1.57 candidate lemmas per surface form — e.g. "á" is
simultaneously a preposition, the noun "river," and a form of the verb
"eiga"). Naively lifting a learned surface-form count up to its lemma (so
that learning "Jökull" also boosts "Jökuls," "Jökli," etc.) risks leaking
credit across unrelated lemmas whenever the form is ambiguous.

## Decision

- **Boundary**: the keyboard extension appends `(word/bigram, count)`
  events to an append-only log in the App Group container
  (`Packages/Learning/Sources/Learning/EventLog.swift`); the containing app
  compacts the log into a personal model overlay
  (`PersonalModel.swift`) that outranks the base language model. Raw
  keystrokes never leave the extension — only compacted counts cross the
  process boundary via the shared container.
- **Privacy invariants, enforced in code, not just policy**:
  - Only single words are logged — `EventLog.isLearnableWord` rejects
    anything containing whitespace/control characters (a "word" is one
    token by definition), anything over 64 characters, anything with no
    letter at all, and anything containing emoji/pictographic scalars
    (emoji are never vocabulary).
  - Content from secure text-entry fields or URL/email/web-search
    keyboard types must never reach the log at all.
    `LearningPrivacy.assertLoggableFieldContext` is the single choke point
    call sites must invoke before `EventLog.append`; it traps in debug
    builds (`assertionFailure`) if the guard upstream is missing, and is
    observable via an injectable `violationHandler` in release builds —
    explicitly documented as never wired to transmit anything, since that
    would defeat its purpose.
  - Events are bucketed by **day** (`Int32` day index), not by timestamp,
    limiting temporal precision of what's retained.
- **Learned threshold**: a word or bigram counts as *learned* (and starts
  influencing ranking) only once it has been seen on **at least 2 distinct
  days**, or the user **explicitly accepted** it (e.g. tapped the verbatim
  suggestion) — `PersonalModel.Configuration.learnedDayThreshold`, checked
  in `isLearned` as `stats.explicitlyAccepted || stats.daysSeen.count >=
  configuration.learnedDayThreshold`. This prevents a single one-off typo
  or rare token from immediately polluting the personal model, while still
  allowing instant, deliberate learning via explicit acceptance.
- **Tombstones stick, permanently, by design** — this is the direct fix for
  SwiftKey's #8 complaint: `remove(word:)` deletes the word's stats, any
  bigram touching it, and inserts a tombstone; `learnCommit` refuses to
  re-learn a tombstoned word ("tombstones never auto-relearn"); only an
  explicit `addUserWord` (an intentional re-add) clears the tombstone.
  Tombstones are also respected across sync merges (ADR-0009).
- **Surface forms are the ground truth for learned counts.** Given the
  1.57-lemmas-per-form ambiguity rate, counts are recorded and ranked at
  the surface-form level, never merged into a shared lemma bucket by
  default. Lemma-level generalization (so that learning "Jökull" also lifts
  related inflected forms) is applied only as an additive ranking *boost*,
  never a merge of counts, and only when either (a) the form is
  lemma-unambiguous, or (b) context (bigram/POS) disambiguates it;
  otherwise credit is either fractionally distributed or not lifted at all.
  Homograph credit must never leak across lemmas.

## Consequences

- A user can always achieve "never suggest this again" with a guarantee
  that survives app restarts, model compaction, and (per ADR-0009) iCloud
  sync — closing SwiftKey's most-cited unresolved trust gap.
- The privacy invariants are runtime-checkable, not just documented: a
  missing guard at a call site fails loudly in debug and is observable (not
  silently correct-by-accident) in release.
- The 2-distinct-day threshold trades a little responsiveness (a word typed
  many times in one sitting still isn't "learned" until a second day, unless
  explicitly accepted) for resistance to single-session noise — consistent
  with the project's general under-correct/conservative bias (ADR-0006).
- The lemma-ambiguity constraint means personalization is deliberately
  slower to generalize than a naive implementation would be; this is an
  accepted cost of correctness for a morphologically rich language, and is
  the same constraint ADR-0008's personal ranking boost is built to respect.
- **Future direction (not yet built):** "inflection intelligence" — using
  BÍN's case-government statistics to suggest the grammatically correct
  wordform (e.g. after a preposition governing dative case) — is designed
  as a later, separate engine milestone and explicitly reuses this
  surface-form/lemma-lift constraint. Not implemented as of this writing;
  out of scope here.
- Related: ADR-0004 (BÍN provides the lemma/morphology data this constraint
  depends on), ADR-0008 (personal ranking boost consumes learned counts),
  ADR-0009 (tombstones and learned state are synced, not just local).
