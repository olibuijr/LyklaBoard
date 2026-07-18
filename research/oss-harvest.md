# OSS harvest — double-space bug hunt + fine-tuning fixes from other keyboards

Context: dogfood reports "occasional DOUBLE SPACES" on device. This doc harvests
applicable fixes/patterns from (1) KeyboardKit upstream after our vendored 9.9.1,
(2) azooKey (active MIT Japanese IME), (3) other OSS iOS keyboards — then uses
what's found, plus a direct read of our own vendored KeyboardKit source and
`KeyboardExt/`, to produce a diagnosis brief for the double-space bug. No fixes
were applied here — diagnosis + harvest only, per the requesting agent's scope.

Sources: `gh api`/`gh issue` against `KeyboardKit/KeyboardKit`, `gh api
repos/.../contents` against `azooKey/azooKey`, `gh search repos`/`gh repo view`
for trust screening, one WebSearch, and direct reads of
`Packages/KeyboardKit/Sources/KeyboardKit/{_Keyboard,Proxy,Actions}/*.swift`
(our vendored copy) + `KeyboardExt/*.swift`.

## Trust assessment per source

| Source | License | Activity | Real usage | Verdict |
|---|---|---|---|---|
| KeyboardKit/KeyboardKit | MIT (9.x tags), proprietary "Other" license from 10.0 | Actively maintained (10.7.2 latest, pushed 2026-07-09) | 1850★, the library we vendor | **Trust, primary source** — but see caveat below: only the 9.x MIT *source* is usable; 10.x is diagnostic-reading-only (closed binary) |
| azooKey/azooKey | MIT | Pushed 2026-06-24, updated today | 746★, real shipping Japanese keyboard (App Store) | **Trust** — exactly the "same UITextDocumentProxy quirks" target the brief asked for |
| imfuxiao/Hamster (Rime iOS) | MIT | **Last pushed 2025-05-13** — 14+ months stale | 1611★ | **Reject on recency** — no evidence of active maintenance in the trailing year; code may reflect long-abandoned iOS SDK assumptions |
| openboard-team/openboard | GPL-3.0 | Last pushed 2024-05-16 | 2728★ | **Reject** — Android (AOSP keyboard fork), not iOS; also stale |
| paescebu/CustomKeyboardKit | MIT | Active (2026-06-15) | 290★ | **Reject on applicability** — in-app SwiftUI keyboard replacement, never touches `UITextDocumentProxy`/system keyboard-extension APIs at all |
| `gh search repos "ios keyboard extension"` long tail (SessionPort, MyCuKey, TinyKeyboard, WhisperBoard, NovaKeyboardAI, LaTeXBoard, etc.) | mixed | Recent commits, but | 0-15★, single-author, generic AI-tool-shaped descriptions | **Reject on trust bar** — no evidence of real users, unreadable/unreviewed churn, several look vibe-coded; not worth auditing for edge-case fixes |
| NoerNova/KeyboardKit (fork) | MIT | Active-ish (2026-03) | 1★ | **Reject** — personal fork, no independent engineering to harvest |

Net: two sources cleared the bar — **KeyboardKit upstream** (our own dependency,
read for description-only diagnosis past 9.9.1) and **azooKey** (independent
engineering, directly applicable pattern). Everything else in the "other active
iOS OSS keyboards" search either wasn't iOS, wasn't a system keyboard extension,
or didn't clear real-usage/recency.

## 1. KeyboardKit upstream post-9.9.1

**Critical finding: there is no post-9.9.1 MIT source to harvest.** Checked via
`gh api repos/KeyboardKit/KeyboardKit/git/tags/<9.9.1 sha>`: the `9.9.1` tag and
the `9.9.0` tag point at the **exact same commit** (`a7e33ac2e6f47e16288ce09ec8d765cd329f918c`).
The `9.9.1` tag object itself was created `2026-05-25`, i.e. **8 months after**
`10.0.0` shipped (`2025-09-29`) — it's a retroactive re-tag of the last MIT
commit for downstream users like us, not a patch release. `gh api
repos/KeyboardKit/KeyboardKit/compare/9.9.1...10.0.0` shows the only commits in
between are version-bump/readme/demo churn plus two literal "Remove legacy
source code" / "Remove GitHub files" commits — confirming 9.9.1 is the tip of
the MIT line and PLAN.md's "vendor 9.9.1 permanently" call is correct: there is
nothing more of ours to pull forward.

That means every "fix" beyond this point lives only in the closed-source 10.x
binary. We can't diff it, but `RELEASE_NOTES.md` (still public) and GitHub
Issues describe *what* changed in plain English, which is enough to (a) confirm
whether a described bug class still exists in our vendored source (it does —
we have the file, we can read it) and (b) reason out our own fix rather than
port one.

Full scan of `RELEASE_NOTES.md` 10.0→10.7.1 bug-fix sections found exactly one
entry in our target categories (space/delimiter sequencing, autocomplete apply,
double-space/sentence-ender, proxy handling):

> **10.1**: "`Keyboard.StandardBehavior`'s double tap on space logic is more robust."

Traced to **issue #978**, "Period insertions destructively modifying previous
word" (opened 2025-10-23, closed): *"when I select a word and press space, it
inserts a period before the word... there are many cases where pressing space
after selecting a word causes the last character of the previous word to be
replaced too. This results in malformed words."* Maintainer (danielsaidi):
*"This logic has been rewritten to be more robust. It will be updated in 10.1."*

This is the single most load-bearing finding of the harvest: **the exact
sentence-ending code path this bug report is about is the code we currently
ship**, verbatim, in `Packages/KeyboardKit/Sources/KeyboardKit/_Keyboard/Keyboard+StandardKeyboardBehavior.swift`
(`shouldEndCurrentSentence`) and `Packages/KeyboardKit/Sources/KeyboardKit/Proxy/UITextDocumentProxy+Sentences.swift`
(`endSentence(withText:)`). See the diagnosis brief (§4, Hypothesis A) for how
this maps onto our double-space report — the *symptom* upstream reported
(destructive character eating) and the *symptom* we're seeing (leftover raw
double space) are two different failure modes of the same underlying race,
which is consistent with a genuinely fragile piece of logic rather than two
unrelated bugs.

Other issues checked, for completeness:

- **#712**, "Only a space is added if I try to apply auto suggestions when
  context is empty" (2024, `currentWord == nil` on empty-context guard bailing
  early) — fixed in **8.7**, well before our 9.9.1. Already inherited, no
  action.
- **#787**, "Auto-correction behaviour with space button" (space-commit not
  firing) — reporter couldn't reproduce after reinstall; maintainer's own
  comment ("perhaps some other internal state in the SDK caused this?") is a
  soft, unconfirmed data point for our Hypothesis-B category (stateful
  cross-request staleness) but not citable as a fix.
- **#936**, "Add a setting to disable tapping double space to close the
  current sentence" — a feature request (users wanted an off-switch), not a
  defect report; landed as a v10 setting. Doesn't apply to us directly (we
  don't have a settings surface exposing this), but is a data point that the
  double-space→period feature is itself considered surprising/unwanted often
  enough that KeyboardKit added an escape hatch for it.
- Line "`StandardAutocompleteService` will now filter out duplicate
  suggestions" (10.x, exact version un-pinpointed in the notes) — describes a
  *display* dedup bug (same suggestion shown twice in the bar), not a text
  double-insertion bug. Not applicable; noted for completeness only.
- Checked `insertAutocompleteSuggestion` specifically (the brief's suspicion
  it "appends a space"): confirmed in our own vendored source, not just from
  release notes — see diagnosis §4, Hypothesis C.

## 2. azooKey

Confirmed active (MIT, 746★, pushed within the last month, real shipping app).
Its keyboard-extension layer has almost exactly the workaround-with-comments
shape the brief predicted, centered on two files:

- `AzooKeyCore/Sources/KeyboardExtensionUtils/DisplayedTextManager.swift`
- `AzooKeyCore/Sources/KeyboardExtensionUtils/ExpectedEditTracker.swift`
  (plus its own test file, `ExpectedEditTrackerTests.swift` — a good sign this
  isn't an ad hoc hack, it's treated as load-bearing logic worth unit-testing)

**The pattern — "expected-edit ledger" for distinguishing self-caused proxy
mutations from host-caused ones.** Every proxy mutation azooKey performs
(`insertText`, `deleteBackward`, `adjustTextPosition`, `setMarkedText`) is
wrapped in `observeExpectedEdit`, which snapshots `ObservedTextState` (left /
selected / right text) immediately before and after the call and records the
`(before, after)` pair into a bounded ring buffer (`ExpectedEditTracker`, cap 32
entries). Separately, `KeyboardViewController.textWillChange`/`textDidChange`
(azooKey's own overrides, `Keyboard/Display/KeyboardViewController.swift:464-490`)
snapshot the SAME `ObservedTextState` on every host-driven change notification
and hand `(before, after)` to `InputManager.consumeExpectedEdit`, which calls
`ExpectedEditTracker.consume(before:after:)`. `consume` walks the recorded
chain of expected edits (handling the case where several of the extension's
own edits happened back-to-back before the host callback fired) and returns
either `.matched(hasMoreEdits:)` — this change was exactly what we did
ourselves, no resync needed — or `.noMatch` — an edit landed that we didn't
originate (autofill, undo, programmatic host mutation, or a stale/duplicate
notification), so composing state must be dropped/resynced.

**Why this is directly applicable to us**: `KeyboardViewController.swift`
already documents the exact problem this solves, in its own words (see
`selectionDidChange`/`textDidChange` comment, lines ~172-189): *"Both callbacks
ALSO fire after our own insertions; the session's window-aware note is
idempotent for windows that are valid typing evolutions of its own last-seen
state... this forwarding is the belt-and-braces layer for cases internal
detection cannot see."* That's a **heuristic** version of exactly what azooKey
built as an **exact ledger**. `TypeEngine.TypingSession.noteExternalTextChange`
(not read here — package boundary — but described in the same comment)
apparently infers "is this a valid evolution of my own last state" rather than
matching against a recorded list of edits it actually issued. The
azooKey pattern is strictly stronger: it can't be fooled by a coincidental
window that *happens* to look like a valid evolution but isn't (e.g., the host
autocorrect silently replacing a word with another word of the same length —
a heuristic "was this an append?" check can misclassify this, an exact
before/after ledger cannot). This is the single most concrete, engineering
(not just descriptive) harvest item from this research pass.

Also checked and confirmed present but less novel (azooKey needs it far more
than we do, since Japanese input relies heavily on marked text / live
conversion which we don't use): `updateMarkedText`, `getActualOffset` (cursor
math around `documentContextAfterInput`/`documentContextBeforeInput` when
moving by a signed character count — handles the "newline at the right edge"
proxy quirk by special-casing offset `1` when `documentContextAfterInput` is
empty). Not directly harvestable (we don't do marked-text composition), but
confirms the general "the proxy lies at boundaries, code defensively" theme.

No azooKey-specific *double-space* handling was found — expected, since
Japanese text doesn't use inter-word spaces the way Icelandic/English do; their
space key is IME-conversion-triggering, not a delimiter in our sense. The value
harvested here is the **general robustness pattern**, not a space-specific fix.

## 3. Other active iOS OSS keyboards — rejected

See the trust table above. Summary of what was checked and why each failed the
bar: Hamster/Rime-iOS (stale 14+ months), OpenBoard (Android/GPL, stale),
CustomKeyboardKit (in-app keyboard, never touches `UITextDocumentProxy`), and
roughly a dozen single-author `gh search repos "ios keyboard extension"` hits
from the last few months (SessionPort, MyCuKey, TinyKeyboard, WhisperBoard,
NovaKeyboardAI, LaTeXBoard, LingoKey, etc.) — all 0-15★, single-author,
generic/AI-tool-shaped descriptions, no evidence of a real user base or of
edge-case hardening worth auditing. None cleared "real stars/users, readable
code, recent *and sustained* activity."

## 4. Double-space diagnosis brief

Grounded entirely in our own vendored source
(`Packages/KeyboardKit/Sources/KeyboardKit/_Keyboard/Keyboard+StandardKeyboardBehavior.swift`,
`.../Actions/Services/KeyboardAction+StandardActionHandler.swift`,
`.../Proxy/UITextDocumentProxy+{Sentences,Autocomplete,Words}.swift`) plus
`KeyboardExt/{KeyboardViewController,LyklabordAutocompleteService,SpacebarMode}.swift`,
cross-referenced against the harvest above. Not fixed here — diagnosis only.

### The pipeline (mode 1, default — `completeCurrentWord`)

`StandardActionHandler.handle(gesture:on:replaced:)` on a `.space` release runs,
in order:
1. `tryApplyAutocorrectSuggestion(before:)` — if mid-word, inserts the
   `.autocorrect` suggestion with `tryInsertSpace: false` (our
   `LyklabordActionHandler.shouldApplyAutocorrectSuggestion` override
   layers the '.'-deferral rule on top of this, unrelated to spaces).
2. `gestureAction(keyboardController)` — the actual space keystroke inserts the
   literal `" "`.
3. `tryEndCurrentSentence(after:)` → `shouldEndCurrentSentence` (behavior) →
   if true, `textDocumentProxy.endSentence(withText: ". ")`.

`shouldEndCurrentSentence` computes `isClosable = documentContextBeforeInput
.hasSuffix("  ")` (two trailing spaces) **after** step 2 has already inserted
the real space — so on an honest double-space-tap this reads two spaces and
fires. `endSentence(withText:)` then has **its own, separate** guard:
`isCursorAtTheEndOfTheCurrentWord` (from `UITextDocumentProxy+Words.swift`:
requires `currentWordPostCursorPart` to be empty/whitespace-only AND the
pre-cursor part to not itself end in a delimiter). Only if *both* guards pass
does it `while (before).hasSuffix(" ") { deleteBackward() }` then `insertText(".
")`.

### Hypothesis A — the double-guard race (highest confidence; upstream-corroborated)

**This is the exact code path KeyboardKit's own maintainer called fragile and
rewrote for 10.1**, per issue #978 (§1 above): tap a bar suggestion → KeyboardKit's
own `insertAutocompleteSuggestion(_:tryInsertSpace: true)` (the default used by
`StandardActionHandler.handle(_ suggestion:)`, i.e. **every** bar tap, not just
autocorrect) inserts the word THEN calls `tryInsertSpaceAfterAutocomplete()`,
which auto-inserts a space and sets a **global, cross-instance static**
`ProxyState.spaceState = .autoInserted` (private singleton in
`UITextDocumentProxy+Autocomplete.swift` — not scoped to a text field, not
reset on field/context change, only self-resets the next time a
space-adjacent/punctuation action runs `tryRemoveAutocompleteInsertedSpace`/
`tryReinsertAutocompleteRemovedSpace`). If the user's very next keystroke is
their own literal spacebar tap (a common motor pattern: tap a suggestion right
as the thumb was already moving toward space, or double-tap-like timing when a
suggestion pops in mid-gesture), `shouldEndCurrentSentence`'s two-guard system
now has to correctly reconcile "one space I auto-inserted + one space the user
just typed" against "is the cursor really at the end of a word." Issue #978's
reporter saw the FAILURE MODE where the wrong character got eaten (guard passed
when it shouldn't have, deleted one too many). **The inverse failure mode —
guard 2 (`isCursorAtTheEndOfTheCurrentWord`) bails out when guard 1
(`isClosable`) already said yes — would leave the raw, untouched "  " (two
literal spaces) sitting in the document, which is precisely our dogfood
symptom.** Both are the same underlying fragility (the two guards can
disagree, because they read the proxy independently and at slightly different
points, with `ProxyState.spaceState` state hanging off the side); which
concrete failure a user sees just depends on which app/field's proxy behavior
diverges from the assumption.

**Applicability**: direct — same code, same version, no upstream fix
available to us (10.1's rewrite is inside the closed binary). Actionable
harvest: don't wait for a v10 port (permanently off the table per PLAN.md);
reason out and scenario-test our own hardening of `shouldEndCurrentSentence` +
`endSentence(withText:)` for exactly the "suggestion tap immediately followed
by a real space" sequence, informed by azooKey's expected-edit pattern
(Hypothesis-A fix should probably route through an exact ledger rather than
`ProxyState`'s bare tri-state singleton, so the "did *I* just auto-insert this
space" question stops depending on global mutable state that isn't reset per
field).

### Hypothesis B — iOS proxy stale reads

`shouldEndCurrentSentence` and `endSentence` both read
`documentContextBeforeInput` fresh, synchronously, in-process — reads of an
extension's OWN just-issued `insertText`/`deleteBackward` calls are not
generally stale (UITextDocumentProxy updates its own cache synchronously for
self-issued edits; the well-known staleness class is proxy-vs-*host-view*
divergence, e.g. custom text views/WKWebView contenteditable/React Native
inputs that echo edits back to the extension on a delay). Our own
`KeyboardViewController` comment already names this exact risk class ("cursor
jumps or host-app mutations never masquerade as word commits") and built the
window-aware idempotent check in `TypingSession.noteExternalTextChange` as a
defense. No upstream evidence (KeyboardKit issues, azooKey code) pointed at a
stale-read bug *specifically inside* `shouldEndCurrentSentence`/`endSentence`
— azooKey's entire `ExpectedEditTracker` machinery exists to guard the
*general* version of this class, not a space-specific instance of it.
**Ranked below Hypothesis A**: plausible as a contributing factor in
non-native text fields, but no direct evidence found; the mechanism in
Hypothesis A doesn't need a host-proxy staleness assumption to fail, so it's
the simpler (Occam) explanation.

### Hypothesis C — suggestion-tap word+space vs. autocorrect-on-space race

Confirmed real mechanism (not hypothetical) in our own vendored source:
`StandardActionHandler.handle(_ suggestion:)` calls
`keyboardContext.insertAutocompleteSuggestion(suggestion)` with the **default**
`tryInsertSpace: true` for every bar tap — this is the same
`tryInsertSpaceAfterAutocomplete()` call implicated in Hypothesis A. This
confirms the brief's suspicion ("KK's insertAutocompleteSuggestion appending a
space") is accurate, but on inspection it **collapses into Hypothesis A**
rather than being a separate mechanism: the auto-inserted space plus a
following user space is exactly the sequence issue #978 is about. Not ranking
this separately to avoid double-counting; folded into A above.

Distinct residual risk worth flagging separately: our own mode-2
(`alwaysInsertPrediction`, `LyklabordActionHandler.handle(gesture:on:
replaced:)`) calls `keyboardContext.textDocumentProxy.insertText(prediction)`
**directly**, bypassing `insertAutocompleteSuggestion` entirely — so it does
NOT hit `tryInsertSpaceAfterAutocomplete`/`ProxyState`, and the real space
keystroke follows immediately after via `super.handle(...)`'s own gesture
action. Read closely, this path looks single-space-safe by construction (one
manual insert with no trailing space, one real space insert) — but it does
insert the prediction word AFTER `shouldApplyAutocorrectSuggestion`'s guards
would have already run once (mode-2 code runs before `super.handle(...)`,
which does its own `tryApplyAutocorrectSuggestion` pass). Because the buffer at
that point has no current word/no `.autocorrect` suggestion type expected for
an empty pending token, this looks safe under current TypeEngine ranking
rules, but it's exactly the kind of ordering-sensitive interaction the
harvested azooKey ledger pattern would make provably safe instead of
safe-by-current-ranking-behavior. Mode 2 isn't the default (mode 1 is), so it's
lower priority for the reported bug, but worth a scenario test regardless.

### Ranking (most to least likely cause of the reported bug)

1. **Hypothesis A** (double-guard race in `shouldEndCurrentSentence` /
   `endSentence`, triggered by a suggestion-bar tap's auto-inserted space
   followed by the user's own space) — direct code match, upstream-corroborated
   as a real, maintainer-acknowledged defect class in this exact function,
   present in our vendored version, no upstream fix available to us.
2. **Hypothesis C's mode-2 residual** — plausible, same family, but
   structurally different code path (bypasses `ProxyState` entirely) and only
   reachable by users who've switched off the default spacebar mode — lower
   prior exposure.
3. **Hypothesis B** (raw host-proxy staleness) — plausible contributing factor
   in some third-party text fields, but no direct evidence for this specific
   function; likely a secondary amplifier of A rather than a standalone cause.

## Recommended action list

1. Write scenario/regression tests (headless harness, `Packages/KeyboardKit`
   or `type-repl`, whichever exercises `StandardActionHandler` end-to-end) for
   the exact issue #978 sequence: tap a bar suggestion → press space
   immediately → assert exactly one space or one ". "  results, never two
   literal spaces and never an eaten character. This is copy-testable directly
   from the upstream bug report's description without needing their fix.
2. Audit `shouldEndCurrentSentence` + `endSentence(withText:)` +
   `ProxyState.spaceState` as a unit; consider whether `ProxyState`'s bare
   process-wide singleton (not reset on field/context change) can be replaced
   or supplemented with something that can't drift from the actual sequence of
   edits we issued — this is where the azooKey `ExpectedEditTracker` pattern is
   directly portable (small, self-contained, already has its own test suite to
   copy the test *shape* from, not the code, since azooKey is MIT but a literal
   copy-paste isn't warranted — the pattern is the harvest, not the file).
3. Lower-priority: add the same "tap suggestion, then space" scenario for mode
   2 (`alwaysInsertPrediction`) even though it's not the default, since the
   ordering argument in Hypothesis C's residual isn't airtight without a test.
4. No action needed on: KeyboardKit 9.9.1 vendoring strategy (confirmed
   correct — nothing more exists upstream to pull), issue #712's empty-context
   fix (already inherited via 9.9.1 >> 8.7), azooKey's marked-text/live-conversion
   machinery (not applicable — we don't do IME composition).

## Top-5 harvestable fixes (summary table)

| # | Fix / pattern | Source + cite | Applies to us? | Effort |
|---|---|---|---|---|
| 1 | Harden `shouldEndCurrentSentence`/`endSentence` against the tap-then-space race | KeyboardKit issue [#978](https://github.com/KeyboardKit/KeyboardKit/issues/978) (fixed in closed-source 10.1; our 9.9.1 still has the pre-fix logic) | Yes — direct, same code, same bug class | Medium (needs careful proxy-state reasoning + scenario tests; no diff to port from, must reason it out) |
| 2 | Expected-edit ledger (before/after snapshot matching) to replace/harden heuristic "was this my own edit" detection | azooKey `ExpectedEditTracker.swift` + `DisplayedTextManager.swift` | Yes — same problem class as `TypingSession.noteExternalTextChange`'s heuristic, described in our own `KeyboardViewController.swift` comments | Medium — small, self-contained pattern (~60 lines), well-tested reference to design against |
| 3 | Replace/scope `ProxyState.spaceState`'s process-wide static singleton | Read of `Packages/KeyboardKit/Sources/KeyboardKit/Proxy/UITextDocumentProxy+Autocomplete.swift` (our own vendored code) | Yes — root-caused as part of Hypothesis A | Low-Medium (self-contained file, but interacts with steps 1-2) |
| 4 | Scenario-test "tap suggestion → immediate space" for both spacebar modes | Derived from #978 + our own `SpacebarMode`/`LyklabordActionHandler` code | Yes | Low (test-only) |
| 5 | Note KeyboardKit's own escape hatch precedent (settings toggle for double-space-to-period) | KeyboardKit issue [#936](https://github.com/KeyboardKit/KeyboardKit/issues/936) | Maybe — not a bug fix, but validates that a user-facing off-switch for this feature is a reasonable future affordance if hardening doesn't fully kill the report | Low (product decision, not urgent) |
