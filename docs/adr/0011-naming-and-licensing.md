# Rename to Lyklaborð; identifiers; MIT license with separate data licenses

Status: Amended
Date: 2026-07-15; amended 2026-07-18

## Context

The project was developed under a temporary working identity, with legacy
bundle identifiers and an App Group. Before M2
(personal learning) started accumulating real user data under those
identifiers, the project needed to settle on a real product name — changing
identifiers after users have data tied to them is much more disruptive than
before.

Separately, the repository bundles three categories of non-code content
with different licensing regimes: BÍN-derived Icelandic language data
(© Árni Magnússon Institute for Icelandic Studies, redistribution-
restricted per ADR-0004), SymSpell-derived English frequency data (MIT,
itself sourced from Google Ngrams v2 public-domain data intersected with
Hunspell dictionaries under various open licenses), and Wikipedia-derived
evaluation sentences (CC BY-SA 4.0, per ADR-0010). A single repo-wide
license could not honestly cover all three.

An unresolved question remained open in PLAN.md at the time of most other
decisions: MIT (maximum adoption) versus GPL/AGPL (prevents closed
commercial forks of a free community project) for the code itself.

## Decision

- **Product name: Lyklaborð** (Icelandic for "keyboard"), chosen after
  confirming the name was unsquatted in App Store search (reservation in
  App Store Connect still pending as of this writing).
- **Identifiers renamed** before M2 data accumulation: the legacy bundle ids
  were replaced by `is.solberg.lyklabord` and
  `is.solberg.lyklabord.keyboard`
  (`bundleIdPrefix: is.solberg.lyklabord` in `project.yml`); App Group
  the legacy App Group → `group.is.solberg.lyklabord` (both entitlements
  files, and `KeyboardApp.appGroupId` in `KeyboardExt/KeyboardViewController.swift`);
  display names (app and extension `CFBundleDisplayName`, plus
  `KeyboardApp.name`) set to "Lyklaborð"; onboarding copy updated to match.
- **Code/project identity completed on 2026-07-18**: repository
  `LyklabordApp`; Xcode project, scheme, target, and main product `Lyklabord`;
  extension target/product `LyklabordKeyboard`; Swift/source symbols and files
  use `Lyklabord*`. Internal queue names, keys, logs, scripts, and active docs
  likewise use `lyklabord` / `is.solberg.lyklabord`. This amendment supersedes
  the original temporary decision to retain the working code identity.
- **Code license: MIT** — resolves the open PLAN.md question in favor of
  maximum adoption over copyleft protection against closed commercial
  forks. The vendored KeyboardKit 9.9.1 fork (ADR-0003) retains its own MIT
  license unchanged.
- **Data files are licensed separately**, stated explicitly in `LICENSE`
  and detailed in `data/README.md` / `data/ATTRIBUTION.md`:
  - BÍN-derived Icelandic data: © Árni Magnússon Institute for Icelandic
    Studies, used under the BÍN conditions (credit required; no raw-data
    redistribution; no publishing of complete inflection paradigms — see
    ADR-0004 for how the shipped `.bin` format satisfies this).
  - SymSpell-derived English data: MIT.
  - Evaluation sentences (`data/eval/`): CC BY-SA 4.0, from Wikipedia (see
    ADR-0010).

## Consequences

- The identifier rename happened at the cheapest possible point in the
  timeline (before personal-data accumulation begins in M2), avoiding a
  future migration that would need to reconcile old- and new-identifier
  App Group data.
- Anyone forking the MIT-licensed code must independently satisfy the BÍN
  data conditions if they want to redistribute BÍN-derived artifacts — the
  code license does not launder the data restrictions, and this is stated
  explicitly rather than left implicit.
- "Lyklaborð" is the user-facing and App-Store-facing identity everywhere;
  ASCII `Lyklabord` is used only where Swift/Xcode/filesystem identifiers are
  safer without diacritics. The former working name appears only above as
  historical migration evidence.
- Related: ADR-0004 (BÍN data conditions this license structure encodes),
  ADR-0003 (the vendored KeyboardKit fork's own license), ADR-0010
  (eval-sentence licensing).
