# Vendor KeyboardKit 9.9.1 permanently; never track upstream

Status: Accepted
Date: 2026-07-15

## Context

`research/foundation-options.md` surveyed the open-source iOS keyboard
landscape and found KeyboardKit to be the only actively maintained,
production-grade option — covering keyboard views, the layout engine,
action handling, feedback, and localization for free. No complete
open-source iOS autocomplete/autocorrect engine exists anywhere (KeyboardKit's
own autocomplete is Pro-gated; Fleksy is proprietary; Android engines like
FlorisBoard/HeliBoard/FUTO are tightly coupled to `InputMethodService` and
not portable), so the plan from the start was: KeyboardKit for UI/layout
only, fully custom autocorrect/prediction (see ADR-0005, ADR-0006).

At v10.0, KeyboardKit merged the free core and the paid Pro tier into one
SDK gated by a separate `LicenseKit` package that requires a license file or
subscription key to validate — confirmed by diffing `Package.swift` across
tags in `research/keyboardkit-v10-delta.md`: v10.7.2 ships no `Sources/`
directory at all, only a closed binary XCFramework. `LicenseKit` is a
build-graph-level dependency ("no binary licenses encoded... you need a
license file or a subscription license key"), not something that can be
selectively avoided while still using v10.

This directly conflicts with two locked decisions: KeyboardKit Pro is
permanently off the table (ADR-0001, no monetization), and the extension
ships zero networking code — a license-validated dependency implies network
calls the project cannot audit away. **9.9.1 is the last tag with full
MIT-licensed Swift source and no license machinery.**

A line-by-line read of 9.9.1's own `_Deprecated/` directory (27 files, ~2,200
lines) showed the project's two existing call sites —
`Callouts.BaseCalloutService` and `KeyboardLayout.BaseLayoutService` — were
already marked for removal in 10.0, with the non-deprecated replacement
(`Callouts.Actions` value type, `KeyboardView(layout:)` init param) already
present and unused in 9.9.1 itself. Everything else new in 10.0–10.7
(clipboard, Unicode fonts, remote LLM-based prediction, in-keyboard
dictation, iPad Pro layout, new locales) is either Pro-gated, conflicts with
the zero-network stance, or explicitly out of v1 scope — there is no
"missing capability" in 9.9.1 worth chasing 10.x for.

## Decision

**Vendor KeyboardKit 9.9.1 into `Packages/KeyboardKit/` and treat it as ours
permanently** — no SPM remote pin, no `swift package update`, no tracking of
10.x ever, even experimentally (partial cherry-picks would fight the
license-gating restructuring in every touched file for zero benefit).

Concretely:
- Migrated the two existing call sites off the deprecated
  `CalloutService`/`KeyboardLayoutService` protocol subclasses onto the
  free, non-deprecated 9.9.1 value/modifier APIs, so the fork carries no
  dependency on code upstream itself calls dead.
- Adopted two launch-flicker mitigation *patterns* from 10.4/10.6 (defer
  costly work — the mmap model load — past `viewDidLoad`; minimize
  observable-context churn before first paint) without importing any 10.x
  code; the underlying bug (`UIInputViewController` launch-height
  flickering, KeyboardKit GH #1041/#945) is Apple's, confirmed by the
  maintainer and reproducible in a blank custom-keyboard project, and
  affects every third-party keyboard on iOS regardless of framework version.
- Left `#757` (emoji keyboard font-cache memory bloat, unresolved upstream
  across all KK versions) as a known, tracked risk rather than a blocker —
  see ADR-0012 for the resulting emoji-picker decision.

## Consequences

- The project stops tracking KeyboardKit's API evolution entirely; there is
  no upstream to diff against once vendored. Future contributors should
  read `research/keyboardkit-v10-delta.md` before assuming any v10 pattern
  is portable.
- MIT license is preserved and carried forward (see ADR-0011) — vendoring a
  fork is explicitly permitted and matches the "own the whole build
  pipeline, no third-party dependency resolution at all" ethos applied
  elsewhere (BÍN data ADR-0004, sync ADR-0009).
- The project inherits real, unearned baseline behavior for free from
  9.9.1: caps lock, autocapitalization, dark/light appearance-following,
  VoiceOver labels for standard actions, and device-based landscape
  layout sizing — verified present in the vendored source
  (`research/tablestakes-roadmap.md` §4), not rebuilt.
- Two known upstream risks are carried forward and must be watched, not
  re-litigated: the emoji font-cache bloat (#757) and the platform-level
  (not KeyboardKit-level) launch-height flicker.
- Related: ADR-0002 (iOS floor raised alongside this decision), ADR-0012
  (emoji picker / bottom-row decisions built on the vendored fork).
