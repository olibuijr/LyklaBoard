# iOS 18 deployment floor, iPhone-first

Status: Accepted
Date: 2026-07-15

## Context

The project initially targeted iOS 17.0 in `project.yml`. `research/keyboardkit-v10-delta.md`
(researched while deciding whether to vendor KeyboardKit 9.9.1, see ADR-0003)
found that:

- Vendored KeyboardKit 9.9.1's own `Package.swift` floor is `.iOS(.v15)` — the
  project was already two major versions above KeyboardKit's own minimum, so
  KeyboardKit itself gives no forcing function either way.
- A scan of `@available` annotations across `Sources/KeyboardKit` found only
  21 hits, clustered in the vendored `EmojiKit` dependency and a couple of
  button-modifier branches — there is no large "iOS 13/14 UIKit fallback tax"
  to delete by raising the floor. The leverage is entirely in *our own* code:
  an iOS 18 floor gets unconditional use of the `Observation` framework and a
  mature `NavigationStack` in the containing app's SwiftUI code, without
  version branches.
- iOS 26 was current at research time (mid-2026); an iOS 18 floor excludes a
  vanishingly small, aging device population, while iOS 26 as a floor would
  buy nothing (Liquid Glass support in KeyboardKit 9.9.1 is a runtime
  `ProcessInfo` check, not a compile-time gate; Apple's Foundation Models
  on-device prediction is Pro-gated in KeyboardKit v10 and irrelevant to a
  9.9.1 fork regardless of floor).

iPad support was separately scoped: KeyboardKit's layout engine renders a
functional iPad keyboard for free, but iPad-specific polish (dedicated
layout tuning, one-handed mode, number row) was out of scope for v1.

## Decision

Raise the deployment target to **iOS 18.0** across the project
(`project.yml`), iPhone-first. iPad remains functional via KeyboardKit's
stock layout engine but unoptimized — no custom iPad layout work planned for
v1.

## Consequences

- The containing app's SwiftUI code can use `Observation` and modern
  navigation APIs unconditionally, with no pre-18 fallback branches to
  write or maintain.
- iPad users get a working keyboard (KeyboardKit handles device-based
  layout sizing) but not a tuned one; one-handed mode and a persistent
  number row (neither present in vendored KeyboardKit 9.9.1) remain
  post-v1 items if iPad investment is ever prioritized.
- Related: ADR-0003 (the KeyboardKit vendoring decision this floor change
  was researched alongside).
