# App Store Connect — review answers, age rating & privacy label

Everything a reviewer/questionnaire needs, justified against `docs/PRIVACY.md`
and `research/tablestakes-roadmap.md §1`.

---

## Age rating (Apple questionnaire)

Target rating: **4+**. Answer every content question **None / No**:

| Question | Answer |
|---|---|
| Cartoon/Fantasy Violence, Realistic Violence, Prolonged Violence | None |
| Sexual Content or Nudity, Profanity or Crude Humor | None |
| Alcohol, Tobacco, or Drug Use or References | None |
| Mature/Suggestive Themes, Horror/Fear Themes | None |
| Gambling (simulated or real), Contests | None |
| Medical/Treatment Information | None |
| Unrestricted Web Access | **No** (the keyboard has no web view and no network code) |
| User-Generated Content / social features | **No** |
| Data collection used for tracking | **No** |

Result: **4+**, no age gate.

---

## App privacy label — "Data Not Collected"

Declaration: **Data Not Collected** (App Store Connect → App Privacy →
"We do not collect data from this app").

Justification (per `docs/PRIVACY.md`):
- The keyboard extension contains **no networking code** — there is no code path
  that transmits anything off device. Verifiable in the open source.
- No analytics, no diagnostics, no crash reporting, no advertising identifiers,
  no third-party SDKs.
- On-device learning (learned words, bigram counts, per-key touch averages,
  user edits/tombstones) stays in the app's private container and is **not
  collected by us** — it never reaches any server we operate (we operate none).
- **iCloud sync nuance (the one thing to get right):** optional sync writes an
  AES-256-GCM-encrypted copy of the user's personal dictionary to the user's
  **own** CloudKit private database, initiated by the user, with the key held
  only in the user's iCloud Keychain. This is the user's data in the user's own
  iCloud — **not data collected by the developer**, and not "linked to identity"
  in Apple's taxonomy. It does not change the "Data Not Collected" answer.
  (If ASC's questionnaire pushes on "data used to provide sync/backup," the
  honest framing: the developer neither receives nor can read this data.)

## App Tracking Transparency
**No ATT prompt.** Zero IDFA, zero cross-app/cross-site tracking, zero ad SDKs —
nothing to declare, so the app never presents the ATT prompt. (Worth stating in
review notes so its absence doesn't read as an oversight.)

---

## Export compliance (`ITSAppUsesNonExemptEncryption`)
- Once CryptoKit AES-GCM sync ships, set **`ITSAppUsesNonExemptEncryption = YES`**
  in `App/Info.plist` **and** claim the standard exemption in ASC (Apple's own
  CryptoKit used for its intended purpose → exempt, no BIS filing).
- Until sync code is in the build, either the key is absent (sync not present)
  or set to `NO`. **This flag blocks TestFlight builds if unanswered once crypto
  lands** — see roadmap §1.

---

## App Review notes (paste into "Notes for Reviewer")

> Lyklaborð is an Icelandic/English keyboard extension.
>
> FULL ACCESS ("RequestsOpenAccess = YES"): Full Access is used **only** to
> share the App Group container between the app and the keyboard (for the
> personal-dictionary and optional iCloud sync) and to enable typing haptics
> (iOS blocks the haptic engine for third-party keyboards without Full Access).
> It is **not** used for networking — the extension contains no networking code
> at all. Typing, autocorrect, and prediction are fully functional with Full
> Access DENIED (Guideline 4.4.1); only sync and haptics degrade.
>
> To verify with Full Access off: General → Keyboard → Keyboards → Lyklaborð →
> turn Allow Full Access OFF, then type — autocorrect and predictions still work.
>
> PRIVACY: No analytics, no tracking, no ads, no third-party SDKs, no network
> calls from the extension. Privacy label is "Data Not Collected." Optional
> iCloud sync uses the user's own CloudKit private database, encrypted before
> leaving the device. The full source is public: https://github.com/jokull/LyklabordApp
>
> The globe key (next-keyboard) is present on every keyboard layout. In secure
> (password) fields iOS switches to the system keyboard by design — expected
> platform behavior, not a bug.

---

## Bundle / account facts to confirm before submission
- Bundle ID: (app) + keyboard extension — confirm in `project.yml` / Xcode.
- Repo name in URLs is **LyklabordApp** (`github.com/jokull/LyklabordApp`).
- Primary language: Icelandic (is) or English (en) — recommend **Icelandic**
  primary given the target market; en-US is a supplemental localization.
