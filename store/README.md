# store/ — App Store submission asset pack

Everything needed to submit **Lyklaborð** to the App Store, generated locally.
**Nothing here has been uploaded** — no App Store Connect account/API key is
configured yet. This pack is ready for Jökull's review and for upload once the
account exists.

Generated 2026-07-16 for iPhone **6.9"** (1260 × 2736), the single required
iPhone screenshot size (per the app-store-screenshots skill and Apple's current
spec). Note: the brief mentioned 1320×2868 / 1284×2778 — those are **superseded**;
the skill and Apple's current reference both give **1260 × 2736** as the correct
6.9" size, which is what was produced. To also emit 6.5" (1284 × 2778), change
`W,H` in `screenshots/build/generate.py` + `render.sh` and re-run.

---

## What's in here

```
store/
├── research.md                      Competitor + ASO analysis → screenshot strategy
├── research/competitors/            Downloaded SwiftKey & Gboard screenshots (reference)
├── metadata/
│   ├── en.md                        en-US: name, subtitle, promo, keywords, description, what's-new, URLs, category
│   ├── is.md                        is-IS: same, description Gemini-proofed
│   ├── app-review.md                Age rating, privacy label worksheet, ATT, export compliance, reviewer notes
│   └── charcheck.txt                Character-limit verification for every capped field
├── assets/
│   ├── keycap.png                   Wave-5 keycap render (opaque)
│   ├── keycap-float.png             Wave-5 keycap, background knocked out (used in hero)
│   └── appicon.png                  Wave-6 app icon (1024)
└── screenshots/
    ├── build/generate.py            Data-driven HTML builder (faithful Icelandic keyboard recreation)
    ├── build/render.sh              Headless-Chrome → PNG at exact 1260×2736 (no GUI, no upload)
    ├── build/html/                  12 generated standalone HTML pages
    ├── export/is-IS/ (6 PNG)        Final Icelandic screenshots
    ├── export/en-US/ (6 PNG)        Final English screenshots
    └── preview/index.html           Side-by-side preview of all 12
```

### Regenerating screenshots
```bash
cd store/screenshots/build
python3 generate.py      # rebuild HTML from data/captions
./render.sh              # render all → export/{locale}/*.png (verifies dimensions)
open ../preview/index.html
```
Captions/content live in the `CONTENT` dict and the per-screenshot builders in
`generate.py`. Palette + fonts are copied verbatim from the live site.

### Re-verifying metadata character limits
```python
python3 - <<'PY'
for f,lim in [("name",30),("subtitle",30),("promo",170),("keywords",100),("desc",4000)]:
    pass  # counts recorded in metadata/charcheck.txt; edit fields then recount len(str)
PY
```

---

## Screenshot set (6 per locale × 2 locales = 12)

| # | File | Caption is-IS / en-US |
|---|---|---|
| 1 | `01_hero` | Lyklaborðið sem kann íslensku / The keyboard that knows Icelandic |
| 2 | `02_accents` | Skrifaðu broddlaust / Type accent-naked |
| 3 | `03_blend` | Íslenska og enska, blandað / Icelandic and English, blended |
| 4 | `04_bin` | Skilur beygingar / It understands inflection |
| 5 | `05_dictionary` | Orðaforðinn þinn — í alvöru þinn / Your vocabulary, truly yours |
| 6 | `06_privacy` | Ekkert netsamband / Zero networking code |

All 12: exactly **1260 × 2736**, PNG, < 1 MB each (well under Apple's 8 MB cap).

---

## Submission checklist

### A. Ready now (in this pack — review these)
- [x] Research + ASO strategy (`research.md`)
- [x] 6 screenshots × 2 locales at 1260×2736 (`screenshots/export/`)
- [x] Metadata is-IS + en-US, all fields within limits (`metadata/`)
- [x] Age rating answers (→ 4+), privacy-label worksheet, reviewer notes (`metadata/app-review.md`)
- [x] Privacy Policy URL (interim GitHub `docs/PRIVACY.md` link)

### B. Gated on the Apple Developer / App Store Connect account
_None of this is possible until the account + app record exist._
- [ ] **Reserve the app name** "Lyklaborð" in App Store Connect (do this early — names are first-come). Confirm the en-US 30-char name `Lyklaborð – Icelandic Keyboard` is accepted (the en-dash may count oddly; fallbacks are noted in `metadata/en.md`).
- [ ] Create the app record: bundle ID, **primary language = Icelandic**, category **Utilities** (secondary Productivity).
- [ ] Paste metadata from `metadata/en.md` + `metadata/is.md` into each localization.
- [ ] Enter the App Privacy questionnaire as **Data Not Collected** per `metadata/app-review.md` (mind the CloudKit-sync nuance).
- [ ] Paste the reviewer notes (Full Access justification) from `metadata/app-review.md`.
- [ ] Set age rating to 4+ using the answers in `metadata/app-review.md`.

### C. Screenshot upload (once an App Store Connect API key exists)
_The app-store-screenshots skill's Workflow 9 automates this. Requirements:_
- [ ] App Store Connect **API key** (`.p8`), Key ID, Issuer ID.
- [ ] An editable version in `PREPARE_FOR_SUBMISSION`.
- [ ] Upload via the skill's API flow: create `appScreenshotSet` with display type **`APP_IPHONE_67`** (the 6.9" images map to the 67 slot — `APP_IPHONE_69` does not exist in the API), reserve → upload binary → commit each PNG, for **both** the `is` and `en-US` localizations.
- [ ] Order 01→06 as listed above.

### D. Build / entitlement gates (engineering, before the binary ships)
- [ ] **`ITSAppUsesNonExemptEncryption`** in `App/Info.plist` once CryptoKit sync lands, + claim the standard exemption in ASC. **Blocks TestFlight builds if unanswered.** (roadmap §1)
- [ ] **Production CloudKit schema deploy:** promote the CloudKit container schema from Development → Production in the CloudKit Console (or `cktool`) before any public/TestFlight build uses sync — records written against a Dev-only schema fail in production. Pair with the export-compliance flag above (both are sync-gated).
- [ ] Confirm globe (next-keyboard) key is present on every layout, and manual QA pass with **Full Access denied** (typing/autocorrect/prediction must still work) — roadmap §1 v1-blocker.
- [ ] Host the privacy policy at a stable URL (`lyklabord.solberg.is/privacy`) and swap the Privacy Policy URL in both metadata files (currently the interim GitHub link).

### E. TestFlight (after the above)
- [ ] Archive in Xcode → upload build to App Store Connect.
- [ ] Resolve the export-compliance prompt (see D) — it recurs every build until the Info.plist key is set.
- [ ] Internal TestFlight first (no review); then external TestFlight (needs a short Beta App Review + the same reviewer notes).
- [ ] Verify on a real device: keyboard enable flow, Full-Access-off typing, accents/inflection/blend behaviors that the screenshots promise, SwiftKey import.
- [ ] Submit for App Review with the notes from `metadata/app-review.md`.

---

## Notes / decisions
- **Screenshots recreate the real keyboard in HTML/CSS** (true Icelandic layout, quoted verbatim suggestion slot) rather than capturing the simulator — accuracy over gloss, per brief, and reproducible without a running build. When the app is device-runnable, consider re-shooting hero/feature frames from real captures for the final pass.
- **Palette/typography** are copied verbatim from `site/dist/index.html` (`--bg #faf9f6`, `--ink #1c1b1a`, keycap `#d7d2c8`, system sans / ui-monospace) so the listing matches the marketing site.
- **Icelandic description + what's-new** were proofed through Gemini (`translate-to-icelandic` skill); two spelling/casing hand-fixes are logged at the bottom of `metadata/is.md`. Short capped fields (subtitle/keywords/promo) were hand-crafted from the site's native voice to hit exact limits.
- **No uploads, no commits** were made. Do not commit `store/` unless intended (large PNGs + the keycap renders).
