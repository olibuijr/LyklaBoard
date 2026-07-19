# Changelog

All notable changes to **LyklaBoard** are documented here. Versions map to
[GitHub Releases](https://github.com/olibuijr/LyklaBoard/releases); each ships a
sideloadable debug-signed APK. No secrets are ever bundled — ElevenLabs voice keys
come only from the on-device settings field.

## [0.7.1] - 2026-07-19

### Fixed
- **Tap-to-append autocorrect**: tapping a completion appended the suggestion instead of
  replacing the word (`hver` + `hverslags` → `hverhverslags`). The composing region was
  gated on `prefs.suggestion.enabled` while the engine force-showed candidates, so there
  was no composing region to replace. Composing is now enabled for any non-password text
  field (`determineComposingEnabled()` already ANDs `isSuggestionOn()`), and suggestions
  default on.
- **Splash screen** showed the old FlorisBoard logo on launch; now the Ð-keycap.
- **Icelandic wording**: "Glide typing" mistranslation `strokuritun` → **`puttaskrif`**.

### Changed (adopted upstream iOS engine fixes → Kotlin engine)
- **#6** symbol-leading tokens (`/goal`, `#tag`, `~path`, `-flag`) are verbatim-class and
  never auto-corrected (no prefix-eating); `trailingSegment` splits on any non-word char.
- **#8** numeric guard: a digit-leading token no longer offers letter suggestions.
- **#3** quoted-term relaxation: a token typed after an opening double quote (`„ " "`) is
  offered but never force-corrected; quote characters are now word delimiters.
- **#9** patronymic title-casing: `-sson`/`-dóttir` suggestions capitalize after a
  capitalized word (`Katrín` → `Jakobsdóttir`); English `-son` words excluded.
- Verified by `WaveADogfoodTest` (host-JVM); engine parity floor 124/158 held.

## [0.7.0] - 2026-07-19

### Added
- **Icelandic-first**: default subtype is now `is-IS` (primary) with `en-US` secondary,
  driven by the Lyklaborð NLP engine — a fresh install types Icelandic out of the box.
- **Full Icelandic app localization** (`res/values-is`): home, navigation, actions, setup
  wizard, and the LyklaBoard settings/dictionary screens.

### Changed
- **Rebrand to LyklaBoard** everywhere (launcher label across all locales, crash/about
  strings, in-app strings, TTS sample). Fixes the debug/beta labels that still read
  "FlorisBoard".
- **Launcher icon** is now the Ð-keycap (adaptive + legacy + round, all densities).
- Fixed version stamping (git dir is one level up from the Gradle project).

## [0.6.0] - 2026-07-19

### Added
- First public build after pivoting the repository to the Android fork: the Kotlin
  engine (`lib/engine`, 1:1 port of the iOS Swift TypeEngine) behind FlorisBoard's
  `NlpProvider` seam — morphology-aware Icelandic+English autocorrect, completion,
  next-word prediction, on-device personal learning, dictionary/settings UI, three
  spacebar modes, emoji frecency, keyboard-height slider, and optional ElevenLabs voice.

### Changed
- Repository is now the Android-only distributable (`AndroidClient/` + `README` +
  `LICENSE`); the original iOS/Swift sources and corpora were moved out of the tracked
  tree (gitignored `.refrepos/lyklabord-ios/`).
- Removed all baked secrets: ElevenLabs keys are read only from on-device settings.

[0.7.1]: https://github.com/olibuijr/LyklaBoard/releases/tag/v0.7.1
[0.7.0]: https://github.com/olibuijr/LyklaBoard/releases/tag/v0.7.0
[0.6.0]: https://github.com/olibuijr/LyklaBoard/releases/tag/v0.6.0
