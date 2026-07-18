# KeyboardKit v10 delta — what changed, what we do about it

Context: we're pinned to KeyboardKit **9.9.1** (last full-MIT-source tag; v10 merged
KeyboardKit + KeyboardKit Pro into one closed-ish SDK gated by `LicenseKit` —
"no binary licenses encoded... you need a license file or a subscription license
key"). PLAN.md already locked "never upgrade to 10.x." This doc is the map for
treating 9.9.1 as *ours*: what to backport, what pattern to copy freely (it's
just API shape, MIT has nothing to do with it), and what to ignore.

Sources: local checkout at
`~/Library/Developer/Xcode/DerivedData/Lyklabord-*/SourcePackages/checkouts/KeyboardKit`
(`_Deprecated/`, `RELEASE_NOTES.md`), `gh api`/`gh release view` against
`KeyboardKit/KeyboardKit` for the 10.0–10.7 release notes, `gh issue` search on
the same repo for the risk scan.

## Verdict up front

- **Fork strategy: vendor 9.9.1 into this repo now**, not later. Stop resolving
  it via SPM against the upstream tag.
- **iOS deployment floor: raise to iOS 18.0** (from 17.0). Cheap, buys real
  simplification headroom, costs ~nothing in device coverage in mid-2026.
- **Migrate off the two deprecated services we already use** —
  `KeyboardLayout.BaseLayoutService` and `Callouts.BaseCalloutService` — onto
  the free, non-deprecated 9.9.1 value/modifier APIs (`layout:` init param on
  `KeyboardView`, `.keyboardCalloutActions(_:)`). This is a same-day change,
  zero new dependencies, and it's the *only* piece of "adopt the v10 pattern"
  that's actually urgent, because we're currently building on code the
  upstream project itself calls dead.
- Everything else in v10.0–10.7 is either Pro-gated (irrelevant — Pro is
  permanently off the table per PLAN.md decision #4), a pure rename
  (irrelevant — we're never upgrading, so their churn doesn't touch us), or a
  feature we've explicitly scoped out (dictation, swipe, themes). Two
  exceptions worth *porting* in spirit: the launch-flicker mitigation and the
  "postpone autocomplete until the keyboard has appeared" pattern from 10.4/10.6.

## 1. Local source: `_Deprecated/` inventory (v10 API map)

27 files, ~2,200 lines. Every deprecation message either renames a symbol
(9.x-internal churn, ignore) or points at the real v10 story: **the
callout/layout/style *service* protocols are dead; v10 replaces them with
plain value types + SwiftUI environment view-modifiers.**

| Deprecated (9.9.1) | Message | v10 replacement | Are we using it? |
|---|---|---|---|
| `CalloutService` protocol + `Callouts.BaseCalloutService` / `StandardCalloutService` | "These services will be removed in 10.0. Use the new `.keyboardCalloutActions` modifier instead." | `View.keyboardCalloutActions(_:)` + `Callouts.Actions` value type | **Yes** — `IcelandicCalloutService: Callouts.BaseCalloutService` in `KeyboardViewController.swift` |
| `KeyboardLayoutService` protocol + `KeyboardLayout.BaseLayoutService` / `DeviceBasedLayoutService` / `iPadLayoutService` / `iPhoneLayoutService` / `StandardLayoutService` + `KeyboardLayoutServiceProxy` | "Will be removed in 10.0. Use the new `.keyboardLayout` view modifier instead." | `KeyboardView(layout:)` init param + `KeyboardLayout.standard(for:)` builder | **Yes** — `IcelandicKeyboardLayoutService: KeyboardLayout.BaseLayoutService` |
| `KeyboardStyleService` protocol + `KeyboardStyle.StandardStyleService` | "Will be removed in 10.0. Use the new `.keyboardButtonStyle` builder modifier instead." | `View.keyboardButtonStyle(builder:)` | No — we don't set `services.styleService`, we ride the internal default |
| `Color+Standard`, `Font+Standard`, `Keyboard.ButtonStyle+Standard` (9.6/9.7 vintage) | "Use `KeyboardAction` extensions instead." | `KeyboardAction.standardButtonStyle/Font/...` | No |
| `KeyboardLayoutServiceProxy` | same v10.0 removal note | n/a (pattern folded into layout builders) | No |
| Everything else (`Actions+Deprecated`, `Gestures+Deprecated`, `Image+Deprecated`, `KeyboardInput+Deprecated`, `Keyboard+Deprecated`, `Settings+Deprecated`, `Dictation+Deprecated`, `Localization+Deprecated`, `Color+Deprecated`, `KeyboardFont+Deprecated`) | pure `renamed:` typealias shims from 9.x internal refactors (`KeyboardCallout`→`Callouts`, `Keyboard.Accent`→`Keyboard.Diacritic`, etc.) | n/a | No — none of these are load-bearing for us |

Confirmed by reading the actual (non-deprecated) 9.9.1 source, not just the
messages:

- `KeyboardView`'s real (non-deprecated) initializers in
  `_Keyboard/KeyboardView+Init.swift` already accept `layout: KeyboardLayout?`
  directly — the v10 replacement mechanism is *already present and free* in
  9.9.1, it's just that our code doesn't use it yet.
- `Callouts/Callouts+Actions.swift` and `Callouts/View+KeyboardCallout.swift`
  contain the real, non-deprecated, non-Pro `Callouts.Actions` value type and
  `View.keyboardCalloutActions(_:)` modifier. No license/Pro gating anywhere
  in that directory (`grep -rl "License\|isPro"` → nothing). This is the same
  API shape v10 keeps — it isn't a v10 feature we'd be "backporting", it's a
  9.9.1 feature we're simply not using yet.
- `KeyboardContext.isLiquidGlassAvailable` / `setIsLiquidGlassEnabled` (added
  9.9, per `RELEASE_NOTES.md`) is a **runtime** `ProcessInfo` check
  (`version.majorVersion > 18`), not an `@available` compile-time gate — so
  our deployment target has zero effect on Liquid Glass support. 9.9.1
  already renders correctly on iOS 26.

### Action: migrate `KeyboardViewController.swift` off the deprecated surface now

Concretely: replace `services.calloutService = IcelandicCalloutService()` with
a `Callouts.Actions` value (or `.keyboardCalloutActions { params in ... }`
modifier on `KeyboardView`), and replace `services.layoutService =
IcelandicKeyboardLayoutService()` with a plain `func icelandicLayout(for
context: KeyboardContext) -> KeyboardLayout` passed as `KeyboardView(layout:
...)`. The logic inside `KeyboardLayout.BaseLayoutService` (row-building,
item sizing) is not Pro-gated — it's fine to copy its body into a free
function. This is low-effort (a few hours) and removes our only current
dependency on code the upstream project has already marked for deletion,
which matters once we're maintaining a fork with no upstream diffs to lean on.

## 2. What's actually new in 10.0 → 10.7 (not renames)

Full picture pulled from `gh api repos/KeyboardKit/KeyboardKit/releases/tags/*`
for 10.0.0, 10.1.0, 10.2.0, 10.3.0, 10.4.0, 10.5.0, 10.6.0, 10.7.0.

| Version | New capability | Free/core or Pro-only (post-merge, "Pro" = license-gated) | Relevance to us | Verdict |
|---|---|---|---|---|
| 10.0 | Unified SDK, merges KK + KK Pro; **requires license file/key, no more binary-embedded free tier** | N/A — licensing model itself | This *is* the reason we're pinned. Confirms the fork decision was correct. | **ignore** (already the premise) |
| 10.0 | Callout/layout/style services removed; replaced by values + env modifiers, `KeyboardView` "easier to create with far fewer initializers" | Core | Confirms the migration in §1 is the whole story, no more, no less | **adopt-pattern** (see §1) |
| 10.0 | 📋 Clipboard feature (system clipboard + user clips, dedicated keyboard type) | Pro | Not in v1 scope; plausible future nicety (paste last-copied word) | **ignore** for v1 |
| 10.0 | 𝓐 Unicode fonts (type in fancy Unicode glyphs) | Pro | Explicitly out of scope ("themes beyond light/dark", no decorative features) | **ignore** |
| 10.0 | Remote LLM-based next-word prediction (`RemotePredictionRequest.claude`/`.openAI`) | Pro | **Directly conflicts** with "extension ships zero network code" | **ignore**, and a useful negative-confirmation: v10's flagship autocomplete story is the opposite of our privacy stance |
| 10.0 | iPad Pro layout applied to *all* iPad devices | Core layout builder | iPad is "functional via KeyboardKit, unoptimized" per PLAN — low priority | **ignore** for v1, revisit if iPad gets real investment |
| 10.1 | iPad secondary swipe-down actions on 3-row input sets | Core | iPad low-priority | **ignore** for v1 |
| 10.1 | Layout caching (perf) | Core, opt-in via `Experiments` | Real perf lever; our layout is static (one locale, no per-keystroke layout recompute) so upside is smaller than for multi-locale apps | **ignore** — not worth the complexity for a single fixed layout |
| 10.2 | **In-keyboard dictation** (no app roundtrip) | Core/Pro mixed | PLAN.md non-goal: "voice dictation" explicitly excluded | **ignore** |
| 10.2 | `LicenseKit` split out as its own package dependency | N/A | Reinforces: v10 architecturally *requires* a network-validated license dependency at the package level, not just a runtime check. Not something you can "just not call" — it's baked into the build graph. | **ignore**, but strengthens the case for never touching 10.x even experimentally |
| 10.3 | On-device next-word prediction via Apple **Foundation Models** (iPhone 15 Pro+, iOS 26.1+) | Pro | We're building our own BÍN-aware IS/EN predictor — this is the exact space we differentiate in. Apple's Foundation Models framework itself (not KK's wrapper) could be a *future* on-device idea for English boosting, but that's a v2+ conversation, unrelated to KeyboardKit | **ignore** (not KK's to give us; if ever pursued, it's a direct FoundationModels integration, no KK needed) |
| 10.3 | Faster license validation → "less flickering when setting up the keyboard extension" | N/A | We have no license validation at all (no network), so this specific flicker source doesn't apply to us | **ignore** |
| 10.4 | **Fixes random slow keyboard launches by postponing costly operations until the keyboard has appeared** | Core | Real, generically-applicable pattern: don't do expensive work in `viewDidLoad`/early lifecycle, defer to `viewDidAppear`/first render. Directly actionable for us — our M0 code already does `Bundle(...).url(...)` + `BinaryLemmatizer(contentsOf:)` mmap load in `viewDidLoad`. Once M1 wires this into `autocompleteService`, launch-time cost is real. | **adopt-pattern**: defer the mmap load and any first-run corrector/predictor construction until after the keyboard view has appeared, not in `viewDidLoad` |
| 10.4/10.6 | `hostApplicationBundleId` returns `nil` on iOS 26.4+/27 (private XPC API broken by Apple, not fixable) | N/A | We don't use `hostApplicationBundleId` anywhere currently. Good — nothing to fix, but flag it as permanently unreliable if a future feature (e.g., per-app autocorrect behavior) wants it | **ignore**, note as a landmine to avoid building on |
| 10.5 | Accessibility settings (font weight, key height) | Core | Real accessibility gap in 9.9.1; not in v1 scope but cheap to adopt-pattern later (two `KeyboardSettings` toggles + style multipliers) | **adopt-pattern**, post-v1 |
| 10.5 | Duplicate-suggestion filtering, autocomplete toolbar hide/show setting | Core | Our own `AutocompleteContext`/suggestion bar is custom (not KK's), so this doesn't transfer, but "filter duplicate suggestions" is an obvious note for our own suggestion-bar logic | **adopt-pattern** (design note for our own code, not KK's) |
| 10.6 | **Minimizes on-launch redraws** by reducing unnecessary observable-context re-renders during keyboard launch | Core | Same family as 10.4: real, OS-adjacent flicker mitigation (see GH #1041/#945 below). Generic SwiftUI-on-launch lesson: avoid `@Published`/environment churn before first paint. | **adopt-pattern**: audit our `state.setup(for:)`/`KeyboardSettings.setupStore` sequencing in `viewDidLoad` for redundant state writes before first render |
| 10.6 | Spacebar vertical drag → move cursor in larger steps | Core | Nice muscle-memory feature (SwiftKey/Gboard parity), cheap gesture addition | **adopt-pattern**, post-v1 polish |
| 10.6/10.7 | Massive namespace flattening (`Callouts.Actions`→`KeyboardCalloutActions`, `Dictation.*`→bare names, etc.) | Core | Irrelevant — we never upgrade, so their internal renames don't touch our code at all | **ignore** |
| 10.7 | Undo manager for text insertions/deletions/autocorrections (opt-in experiment) | Core | Real quality-of-life feature (one-tap revert is already a PLAN.md requirement — "autocorrect discipline... one-tap revert"). KK's version is generic document-undo; ours is more specific (revert *this* autocorrection). Worth reading their `TextDocumentUndoManager` design for inspiration but our revert logic is bespoke anyway (BÍN-aware, per-word) | **adopt-pattern** (design reference only) for the one-tap-revert requirement already in PLAN.md |
| 10.7 | More settings-screen picker components | Pro/settings-UI | We're building our own settings UI (containing app) | **ignore** |
| 10.0–10.7 | Arabic (PC), Turkish Q/F layouts, more locales | Core | Single Icelandic layout, no locale switching per PLAN.md decision #2 | **ignore** |

### Summary of verdicts

- **adopt-pattern** (reimplement the *idea* ourselves, no code borrowed): callout/layout as values+modifiers (already free in 9.9.1, just unused by us — do this one now); defer expensive `viewDidLoad` work to post-appearance; minimize observable-context churn before first paint; duplicate-suggestion filtering in our own suggestion bar; spacebar-drag cursor movement (post-v1 polish); accessibility font-weight/key-height settings (post-v1); undo-manager design reference for one-tap revert.
- **port** (nothing qualifies): every genuinely new *capability* in v10 (clipboard, Unicode fonts, remote LLM autocomplete, in-keyboard dictation, Foundation Models prediction, iPad Pro layouts, new locales) is either Pro-gated, conflicts with the zero-network/no-monetization constraints, or is explicitly out of v1 scope. There's no "missing functionality worth rebuilding" — v10's real feature growth is aimed at a product shape (Pro subscriptions, cloud LLM autocomplete, iPad polish) we've deliberately opted out of.
- **paper over**: everything else — once we vendor 9.9.1 (see §4), the entire service-protocol surface (layout/callout/style) becomes internal implementation detail behind our own two call sites in `KeyboardViewController.swift`. We stop tracking KeyboardKit's API evolution entirely; there's no upstream to diff against once vendored.
- **ignore**: licensing/LicenseKit machinery, all renames, all Pro-only screens, all locale/dictation/theme features outside v1 scope.

## 3. iOS version leverage

- `Package.swift` in 9.9.1: `.iOS(.v15)` (also macOS 12, tvOS 15, watchOS 8,
  visionOS 1). Our `project.yml` already sets `deploymentTarget: "17.0"`
  everywhere — we're already 2 major versions above KeyboardKit's own floor.
- v10.0 raises KeyboardKit's own floor to iOS 16. Not a forcing function for
  us since we're already above it.
- `@available(iOS 1[5-9]|26, ...)` scan across `Sources/KeyboardKit`: only 21
  hits, and they cluster in the vendored `EmojiKit` dependency (`iOS 16.0` for
  `Emoji`/`EmojiCategory`, `iOS 16.4` for a popover fallback, `iOS 18.4` for
  the newest emoji set) plus a couple of `Keyboard+ButtonModifier.swift`
  branches. There is no large "iOS 13/14 UIKit fallback" tax to remove —
  9.9.1 is already a fairly modern codebase. **Raising our target does not
  unlock big deletions inside KeyboardKit itself.**
- The leverage is entirely on *our own* code, not KeyboardKit's: iOS 18+ gets
  us unconditional `Observation` framework, mature `NavigationStack`, and
  removes the need to branch our own SwiftUI code for pre-18 behavior in the
  containing app. Given the current date is mid-2026 and the OS is on iOS 26,
  an iOS 18 floor excludes a vanishingly small, aging device population.
- Recommendation: **iOS 18.0**. Not 26 — nothing in KeyboardKit or our own
  plan needs 26 as a *compile-time* floor (Liquid Glass is a runtime check,
  Foundation Models prediction is Pro-only and unused). Not 17 — no reason to
  stay put once forking; 18 is free simplification for our own SwiftUI code
  with negligible device-coverage cost this late in 2026.

## 4. Risk scan: known 9.x issues, GitHub Issues search on `KeyboardKit/KeyboardKit`

| Issue | What | Fixed by KK version | Is it actually a KeyboardKit bug, or Apple's? | Does it affect us on 9.9.1? |
|---|---|---|---|---|
| [#1041](https://github.com/KeyboardKit/KeyboardKit/issues/1041) "iOS keyboard extensions launch with height flickering" | `UIInputViewController` launches at wrong height, resizes twice before settling | Mitigated (not eliminated) in 10.6 by reducing observable-context re-renders during launch | **Apple's bug**, confirmed by maintainer: "not a KeyboardKit-related bug... can be observed by creating a new iOS project with a custom sized keyboard extension" ([Apple dev forum thread](https://developer.apple.com/forums/thread/813579)) | Yes, affects us regardless of KK version — it's OS-level. **adopt-pattern**: apply the same "minimize state churn before first paint" discipline in our own `viewDidLoad`/`viewWillSetupKeyboardView` |
| [#945](https://github.com/KeyboardKit/KeyboardKit/issues/945) "Minimize the keyboard flicker when launching" | Same root cause as #1041 | Partial mitigation 10.6 | Apple-caused | Same as above |
| [#1033](https://github.com/KeyboardKit/KeyboardKit/issues/1033) "Some launch lag still remains" | iPad keyboard-switching lag | "Fixed in 10.6" per maintainer | KK-side optimization | iPad is low-priority per PLAN — low risk |
| [#1014](https://github.com/KeyboardKit/KeyboardKit/issues/1014) "Host Application Bundle ID check crashes in 26.4 beta" | XPC bundle-ID lookup returns `nil` starting iOS 26.4, **crashed** KK ≤10.2.1 | Crash fixed 10.2.2; `nil` return itself never fixed ("may not be doable... involves private APIs") | Apple changed private API behavior; KK had a force-unwrap-style bug that crashed on the new `nil` | We don't call `hostApplicationBundleId` anywhere in `KeyboardViewController.swift` today, so no crash surface. **Do not add code that assumes this property is non-nil** if a future feature wants it. |
| [#963](https://github.com/KeyboardKit/KeyboardKit/issues/963) "iOS 26 Keyboard layout issue" (top area not covered) | Apple added a top safe-area to the keyboard area in iOS 26 | Addressed by KK's iOS 26/Liquid Glass rounding, live in **9.9.0** | Apple OS change; KK visual workaround | **Already covered** — 9.9.1 postdates 9.9.0's fix, confirmed by `RELEASE_NOTES.md`'s "9.9: adds support for Liquid Glass" entry and `KeyboardContext.setIsLiquidGlassEnabled` in the actual 9.9.1 source (§1). No action needed. |
| [#757](https://github.com/KeyboardKit/KeyboardKit/issues/757) "HIGH PRIO: Emoji keyboard allocates too much memory" | Rendering many emoji cells at large font size before scaling spikes memory; SwiftUI/Swift itself doesn't release the font cache | Mitigated (not solved) via smaller base font + `itemScale`, deployed across 9.x/10.x — root cause is a Swift/SwiftUI font-cache issue the maintainer couldn't fully fix | Real, unresolved upstream (framework-level, not version-specific) | **Relevant given our tight jetsam budget.** Default `KeyboardView`'s emoji keyboard is still in our view hierarchy (`emojiKeyboard: { $0.view }` in `KeyboardViewController.swift`). Worth a memory profile pass on the emoji picker specifically during M0/M1, independent of KeyboardKit version — this is a live, only-partially-mitigated risk in the exact code we're shipping. |
| [#971](https://github.com/KeyboardKit/KeyboardKit/issues/971) "Incorrect Keyboard Height iOS 26" | Same flicker/height family as #1041, reported against 9.9.0 beta | Never fully fixed, same as #1041 | Apple's `UIInputViewController` behavior; SwiftKey and Grammarly show the identical pattern per maintainer's own repro | Confirms this is universal across all custom-keyboard frameworks, not a reason to chase KK versions |

No 9.x-only "keyboard randomly gets removed / switches back to system
keyboard" bug was found in the currently open/closed issue set that was
subsequently fixed only in 10.x — the one historical instance
([#697](https://github.com/KeyboardKit/KeyboardKit/issues/697), "Keyboard
switches back to default on its own") is closed with no version-specific fix
noted and predates 9.9. No evidence of a 9.9.1-specific regression that 10.x
uniquely resolves.

## 5. Fork strategy recommendation

**Vendor 9.9.1 into this repo now** (copy `Sources/KeyboardKit` into e.g.
`Packages/KeyboardKit/`, drop the SPM remote pin), rather than keeping the SPM
tag pin indefinitely. Reasoning:

1. The whole point of "own it" is to stop being at the mercy of upstream
   force-pushing tags, yanking the release, or (worse) the GitHub repo
   changing what `9.9.1` points to. SPM pins are only as durable as the
   remote. A vendored copy is durable by construction and matches this repo's
   own "extension ships zero network code" ethos applied to the build
   pipeline too — no dependency resolution against a third party at all.
2. It makes the `_Deprecated/` migration in §1 low-stakes: once vendored, we
   can delete the deprecated `CalloutService`/`KeyboardLayoutService`
   protocol machinery outright after migrating our two call sites, rather
   than carrying dead code forward "just in case."
3. It documents intent for future contributors: there is no `swift package
   update` in this project's future for KeyboardKit. A vendored directory
   with a `README` noting "forked from KeyboardKit 9.9.1 (MIT), see
   research/keyboardkit-v10-delta.md for what we didn't take" is a much
   clearer signal than a pin that looks like any other dependency.
4. Migrate off the deprecated surface (§1) *before* vendoring, or as the
   first commit after vendoring — either order is fine, but do it, since
   otherwise the vendored copy ships ~2,200 lines of code the fork will never
   need (27 files in `_Deprecated/`, of which only the callout/layout
   service classes are load-bearing for us today).
5. Do **not** attempt to cherry-pick individual v10 commits/PRs into the
   vendored 9.9.1 — the license/Pro-merge restructuring in 10.0 touches the
   same files as the free-tier code (e.g., `KeyboardView` initializers,
   `KeyboardApp`), so partial backports would fight the license-gating
   refactor at every step for zero benefit (per §2, nothing in v10 is worth
   porting wholesale). Treat 9.9.1 as a clean base, not a diff target.

Practical migration surface once vendored: just the two service subclasses in
`KeyboardExt/KeyboardViewController.swift` (§1) — everything else in
`_Deprecated/` is either unused by us or fine to keep as-is (deleting it is
housekeeping, not urgent).
