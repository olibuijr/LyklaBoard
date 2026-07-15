# Timed Typing Datasets for the Replay Rig

*Researched 2026-07-15. Goal: real human typing traces (per-keystroke timing + touch x/y) to replay through the XCUITest rig (see PLAN.md testing pyramid tier 3).*

## Selected

### 1. Google TSI — primary ground truth
- **Tap Typing with Touch Sensing Images** (UIST 2024): https://github.com/google-research-datasets/tap-typing-with-touch-sensing-images
- 43,735 touch taps, 16 participants; **pixel-level x/y centroids in keyboard space** (1440×854), touch ellipse axes/orientation, capacitive heatmaps, per-tap timestamps, aligned to intended keys
- **CC-BY-4.0** — derived traces can live in our open repo with attribution
- No access hurdles: direct GitHub download
- Use: coordinate-faithful replay + SpatialModel σ calibration

### 2. Aalto ITE — scale + real errors
- **Mobile Typing with Intelligent Text Entry** dataset: https://zenodo.org/doi/10.5281/zenodo.12528162 (code: github.com/aalto-speech/ite-typing-dataset)
- 46,755 English + 8,661 Finnish participants, own devices, 2019–2020; keystroke-level logs **with autocorrect/suggestion events and raw errors left in** (~7.3GB compressed)
- **CC-BY-4.0**; open access
- Caveat: touch-coordinate availability unconfirmed — inspect README-datasets.md / tracked_data.json after download before relying on coords; timing + error events confirmed
- Use: timing distributions, error models, autocorrect-interaction traces at scale

### 3. How We Swipe — future (swipe is out of scope for v1)
- MobileHCI 2021, Leiva et al.; x/y + radius + rotation + timestamps for gesture typing; license "open" but unconfirmed; dataset location needs author follow-up. Parked.

## Excluded (and why)
- Aalto 136M keystrokes / CMU DSL — desktop only
- KeyRecs, MEU-Mobile, RHU — no touch coordinates
- BehavePassDB, HuMIdb — institutional data agreements required
- Aalto 37k (Palin 2019) — huge but coordinate availability unconfirmed; superseded by ITE for our needs
- Aalto How-We-Type mobile — finger/gaze motion study, weak keystroke-coordinate alignment

## Icelandic traces
No Icelandic dataset exists. Synthesize: Icelandic corpus sentences + timing distributions fit from TSI/ITE + spatial noise from our SpatialModel (inverse sampling). Label all synthetic traces clearly; never mix into human-trace metrics.

## Replay mapping note
Recorded coordinates are QWERTY-relative. Replay maps each tap to (key, within-key offset) in the source layout, then re-projects onto our Icelandic layout geometry — preserves human fat-finger distributions across the layout difference. Keys that don't exist on QWERTY (ð æ ö þ) only appear in synthetic IS traces.
