# Product scope: privacy-first Icelandic+English keyboard

Status: Accepted
Date: 2026-07-15

## Context

Apple's stock Icelandic keyboard has effectively no working autocorrect
(common Icelandic words get "corrected" into rare ones — documented in
Apple Community threads). SwiftKey has offered Icelandic since 2015, but
treats iOS as a second-class platform: it phones home to Microsoft, caps
users at 2 simultaneous languages, and has multi-year unresolved complaints
(spontaneous reversion to the system keyboard ~5% of the time, autocorrect
that "learns" nothing, no way to permanently delete a learned word). See
`research/swiftkey-frustrations.md` for the full, source-cited pain-point
survey (120k aggregated App Store reviews, Reddit, Microsoft's own support
admissions) and `research/foundation-options.md` for the market scan
confirming nobody ships morphology-aware Icelandic autocorrect.

Icelandic speakers routinely type a blend of Icelandic and English
mid-sentence (*slettur* — one-off loanwords) without wanting to switch
keyboards or layouts for it. Neither incumbent handles this gracefully:
Apple's language-ID hijacks the keyboard mid-sentence, SwiftKey's 2-language
cap and per-word switching are a persistent complaint.

## Decision

Build **Lyklaborð**, a privacy-first iOS keyboard scoped narrowly and
permanently:

- **One Icelandic QWERTY layout** (ð þ æ ö native, long-press accents for
  á é í ó ú ý) used for blended Icelandic+English typing — no standalone
  English layout, no language-switching UI. See ADR-0005 for the mechanism
  that makes blended typing work.
- **No swipe typing** — not v1, not planned, ever. Swipe is out of scope
  permanently, not deferred.
- **Free (as in beer) and open source, no paid tier.** KeyboardKit Pro is
  permanently off the table (see ADR-0003) — no monetization pressure means
  no feature-bloat drift, which is exactly the failure mode documented
  against SwiftKey (Copilot/Bing injection, AI news feed nobody asked for).
- **Zero telemetry, zero analytics, no AI/LLM feature.** The keyboard
  extension ships zero networking code — this is a physical, auditable
  property of the shipped binary, not a policy promise. The containing app
  owns all networking (CloudKit sync only, see ADR-0009); the extension
  process never calls out.
- **Morphology-aware autocorrect** built on BÍN (Beygingarlýsing íslensks
  nútímamáls) via the `lemma-is` data pipeline — see ADR-0004.
- **On-device learning with a personal dictionary the user fully owns**:
  editable, individually deletable, deletions stick — a direct fix for
  SwiftKey's documented failure to permanently remove a learned word (see
  ADR-0007).
- Non-goals, permanent: voice dictation, themes beyond light/dark,
  iPad-optimized layout, more than two languages, any AI/LLM feature,
  monetization.

## Consequences

- Depth on one underserved language pair (Icelandic+English) is the
  differentiation strategy, not breadth. Generic multilingual support is
  explicitly SwiftKey's game and not one this project tries to win — but the
  architecture keeps per-language artifacts separable (ADR-0004, ADR-0005)
  in case that changes later.
- No monetization means no infrastructure budget either — CloudKit sync
  rides the user's own iCloud rather than a project-run server (ADR-0009),
  and there is no support obligation beyond the open-source repo.
- Every claim in this scope ("zero network code," "no telemetry") is
  falsifiable by reading the extension's source, which is the entire trust
  pitch — see the self-grill section of PLAN.md: "trust is verifiable, not
  claimed."
- Related: ADR-0002 (iOS floor), ADR-0003 (KeyboardKit vendoring),
  ADR-0011 (naming/licensing), ADR-0012 (bottom-row parity features).
