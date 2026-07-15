# Bottom-row design: period key, spacebar cursor control, double-space period, stock emoji picker

Status: Accepted
Date: 2026-07-15

## Context

`research/swiftkey-frustrations.md` identifies specific SwiftKey/Android
muscle-memory affordances that iOS users of third-party keyboards either
never got or actively miss: long-press-for-symbols on letter keys was never
shipped by SwiftKey iOS at all (#5 in the frustrations report, called out
explicitly as a "misuse of dev resources" complaint when Microsoft added
unrelated AI features instead), and a persistent punctuation/period key
next to the spacebar is standard muscle memory this project wanted to match
or exceed. Getting the width/behavior of the bottom row wrong is a
high-visibility, every-keystroke UX cost, so it went through multiple
dogfood-driven fix passes (git: "dogfood wave — period-key space miss,
split tightening, single-letter accents"; "bottom-row widths — wider
spacebar, narrower return and period").

A separate, unrelated decision had to be made about the emoji picker.
KeyboardKit's stock `KeyboardView` renders its own emoji keyboard slot
(`emojiKeyboard: { $0.view }`) by default, and this was found (during the
table-stakes audit, `research/tablestakes-roadmap.md` §4) to be in tension
with an earlier "no emoji search" non-goal, and to carry a known,
Apple/SwiftUI-level unresolved risk: KeyboardKit GH #757 documents that
rendering many emoji cells at large font size spikes memory because
Swift/SwiftUI's font cache doesn't release — a real concern under the
extension's jetsam budget, and one the KeyboardKit maintainer was unable to
fully fix in any version. The alternative — stripping KeyboardKit's emoji
view and relying on the globe key routing to Apple's system emoji keyboard
— was considered, but **no system-emoji fallback actually exists for
third-party keyboards**: removing the built-in picker would force users to
keyboard-switch just to type an emoji, which is exactly the "reversion"
pain this project is designed to eliminate elsewhere (ADR-0001, ADR-0003).

## Decision

- **Period key** (`.`) to the right of the spacebar: tap for `.`,
  long-press for a callout cluster (`. , ! ? @ # : ; -`); slide-left `!` /
  slide-right `?` gestures are a later refinement, not v1.
- **Spacebar long-press → cursor movement**, using KeyboardKit's existing
  `.moveInputCursor` space behavior rather than custom gesture code.
- **Double-space → ". "** (matches Apple's own native keyboard feel;
  explicitly named as something SwiftKey iOS lacked).
- **`123` key left of spacebar; globe key next to it** (globe access is an
  iOS platform requirement for any third-party keyboard, not optional).
- **Long-press accents on letter keys** (á é í ó ú ý, plus ð/þ) — shipped as
  the Icelandic-specific instance of the long-press-for-alternate-character
  affordance SwiftKey iOS never built at all.
- Bottom-row **widths were tuned iteratively from dogfood feedback**: the
  spacebar was widened and the return/period keys narrowed in a dedicated
  fix pass, after the initial static widths didn't feel right in daily use.
- **Keep KeyboardKit's stock emoji picker**, decided explicitly by Jökull
  (2026-07-15) rather than left as an unexamined default: removing it would
  force keyboard-switching for emoji, which is the exact reversion pain
  this project fights everywhere else, and no system fallback exists to
  replace it. The known GH #757 memory-bloat risk is accepted, not ignored
  — the decision comes with an explicit action item to add a memory
  regression test around it (tracked as a testing follow-up, not resolved
  by this ADR).

## Consequences

- The bottom row's tuning (widths, gesture thresholds) is expected to keep
  moving in response to dogfooding — this ADR records the mechanism
  decisions (what affordances exist and why) rather than freezing specific
  pixel widths, which have already changed once and may change again.
- Accepting the stock emoji picker means the extension carries a known,
  upstream-unresolved memory risk (#757) into production; this is a
  deliberate trade-off against forcing a worse UX (keyboard-switching for
  emoji), not an oversight, and it obligates a memory regression test that
  is not yet built as of this writing.
- Slide-left/slide-right gestures on the period key remain a stated future
  refinement, explicitly deferred, not decided against.
- Related: ADR-0003 (the vendored KeyboardKit fork these affordances are
  built on, including the specific GH #757 risk), ADR-0001 (the
  no-keyboard-switching principle this emoji decision serves).
