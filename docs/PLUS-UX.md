# Lyklaborð+ — Subscription UX Scripts

**Status:** Source of truth for every subscription-related screen, modal, flow, and line of
copy. Implementation (App/, Packages/, store/) must match this document; when code and this
document disagree, this document wins until amended.

**Scope:** UX and copy only. StoreKit plumbing, entitlement caching, and receipt handling
live in `docs/SUBSCRIPTION.md` (owned separately). Copy lands in `App/Strings.swift`
(`Strings.Plus` and neighbors); a delta list against the current strings is in §9.

**Research basis:** every pattern here is adopted from, or banned because of, a studied
precedent — see `docs/PLUS-UX-research.md` for the per-app breakdowns and citations.

---

## 0. The pinned commercial decisions (non-negotiable)

1. The base keyboard is **free forever**: the full Icelandic + English engine, autocorrect,
   completions, inflection awareness. The free tier never degrades and is never nagged
   mid-typing.
2. **Lyklaborð+** is one product: `is.solberg.lyklabord.plus.annual`, **$19/year**, unlocking
   the *personal layer* — personal vocabulary (learned words, dictionary editor, SwiftKey
   import), coordinate adjustment (per-key touch adaptation), and iCloud sync of the
   personal model.
3. **Free introductory trial** — this document fixes it at **14 days** (§6.1).
4. **Lapse:** learned data is retained but paused. Resubscribing restores it instantly.
   **Export of your data is free forever**, entitled or not.
5. The subscription exists from v1 — nobody ever loses a feature they had.
6. **No dark patterns.** This is an identity constraint, not a growth lever. The paywall
   must be the most honest one on the App Store, because the whole product's pitch is
   "verify it — the source is open."

---

## 1. Framing doctrine

*The paragraph the whole team writes copy against. Both languages are canonical; Icelandic
is what ships.*

> **IS:** Lyklaborðið er ókeypis og verður það alltaf — íslenska og enska vélin,
> leiðréttingin og beygingargreindin eru ekki til sölu og gögnin þín ekki heldur.
> Lyklaborð+ er lagið sem er persónulegt fyrir þig: orðin þín, ásláttinn þinn, samstillingin
> þín. Við seljum aldrei hræðslu, flýti eða afslátt sem rennur út á miðnætti; við segjum
> verðið upphátt, sýnum hvað þú færð og treystum þér til að ákveða þig. Ef þú hættir
> heldurðu öllu sem lyklaborðið lærði — það bíður eftir þér, og útflutningur er alltaf
> ókeypis. Tónninn er hlýr, íslenskur og rólegur: við erum stolt af vörunni og biðjum ekki
> afsökunar á því að hún kosti — en við ýtum aldrei.
>
> **EN:** The keyboard is free and always will be — the Icelandic and English engine,
> the autocorrect, the inflection intelligence are not for sale, and neither is your data.
> Lyklaborð+ is the layer that is personal to you: your words, your touch, your sync.
> We never sell fear, urgency, or a discount that expires at midnight; we say the price
> out loud, show what you get, and trust you to decide. If you stop paying you keep
> everything the keyboard learned — it waits for you, and export is always free. The tone
> is warm, Icelandic, unhurried: we are proud the product costs money and never apologize
> for it — but we never push.

Three sentences every screen must be able to survive being tested against:

- **"Það sem er ókeypis versnar aldrei."** (What is free never gets worse.)
- **"Gögnin þín eru alltaf þín."** (Your data is always yours.)
- **"Við truflum þig aldrei á meðan þú skrifar."** (We never interrupt you while you type.)

---

## 2. Timing rules (hard rules the implementation must obey)

These are invariants. Violating any of them requires amending this document first.

| # | Rule |
|---|------|
| T1 | The paywall, and any Plus upsell of any kind, **never appears inside the keyboard extension**. The extension contains zero subscription UI, zero entitlement-dependent banners, zero lock icons. The suggestion bar is sacred. |
| T2 | Nothing subscription-related ever **interrupts typing** — in the extension (T1) or in the app's own text fields (e.g. the try-it pad, dictionary search). |
| T3 | The paywall sheet appears in exactly two situations: (a) **explicit user intent** — the user tapped a gated feature or a "Kynntu þér Lyklaborð+" link; (b) **once during onboarding**, as an optional card the user scrolls past (§4), never as a blocking step. |
| T4 | **No launch-time interstitials.** Opening the app never presents a modal about Plus — not on first launch, not after trial expiry, not on version updates. Expiry states render inline where the user already is (§6.4). |
| T5 | **Soft-CTA cooldowns:** the "first learned word" card shows once, ever (§5.4); the milestone variant shows at most once more, ≥14 days later; any dismissed soft CTA never auto-reappears. Persistent low-key entry points (Settings row, gate footers) are always allowed because they sit still. |
| T6 | **No push notifications for anything subscription-related.** Ever. Trial expiry is communicated in-app only (§6.3). The app never requests notification permission for billing reasons. |
| T7 | **No badges, no red dots**, no counters on tabs or rows that exist to pull the user toward the paywall. |
| T8 | The paywall is always **dismissible instantly**: visible ✕ from first render plus swipe-to-dismiss. No delayed close button, no "are you sure?" on dismissal, no survey on the way out. |
| T9 | Free features never gain Plus framing retroactively. The gate list is closed: Orðasafn editing/activation, SwiftKey import apply, iCloud sync, coordinate adjustment. **Export and delete are never gated** (pinned decision 4). |
| T10 | Price is **never hardcoded** in copy — always StoreKit's `displayPrice` (localized). Trial eligibility is never assumed — always `isEligibleForIntroOffer`. Copy has variants for both cases (§3.4). |

---

## 3. The paywall sheet

One sheet, used everywhere (onboarding card tap, gate CTAs, Settings row). SwiftUI
`.sheet` with visible drag indicator, `✕` top-trailing, swipe-to-dismiss enabled.

### 3.1 Layout (ASCII wireframe)

```
┌──────────────────────────────────────────────┐
│  (drag indicator)                        ✕   │
│                                              │
│                 [Ð keycap art]               │
│                                              │
│           Lyklaborð+ lærir á þig             │   H1
│   Persónulega lagið ofan á ókeypis           │   subtitle
│   lyklaborðinu.                              │
│                                              │
│  Lyklaborðið sjálft er ókeypis og verður     │   honesty
│  það áfram — full íslensk og ensk            │   paragraph
│  leiðrétting, orðauppástungur og             │
│  beygingargreind. Lyklaborð+ bætir við       │
│  laginu sem er persónulegt fyrir þig.        │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │ 📖  Persónulegt orðasafn               │  │   feature
│  │     Lyklaborðið lærir orðin þín —      │  │   rows
│  │     nöfn, slangur, fagorð — og þú      │  │
│  │     stýrir safninu, með innflutningi   │  │
│  │     úr SwiftKey.                       │  │
│  ├────────────────────────────────────────┤  │
│  │ 🎯  Lærir ásláttinn þinn               │  │
│  │     Lyklaborðið lærir hvar fingurnir   │  │
│  │     þínir lenda í raun og veru og      │  │
│  │     verður nákvæmara með tímanum.      │  │
│  ├────────────────────────────────────────┤  │
│  │ ☁️  iCloud samstilling                 │  │
│  │     Orðasafnið þitt fylgir þér         │  │
│  │     dulkóðað á milli tækja — í þínu    │  │
│  │     eigin iCloud, án reiknings hjá     │  │
│  │     okkur.                             │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  Gögnin þín eru alltaf þín — útflutningur    │   trust line
│  er ókeypis, með eða án áskriftar.           │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │      Prófa frítt í 14 daga             │  │   CTA
│  └────────────────────────────────────────┘  │
│  Frítt í 14 daga, síðan 2.990 kr. á ári.     │   disclosure
│  Endurnýjast sjálfkrafa þar til sagt er      │   (price =
│  upp — þú getur sagt upp hvenær sem er.      │   displayPrice)
│                                              │
│         Endurheimta kaup                     │   restore
│                                              │
│  Skilmálar (Apple Standard EULA) ·           │   legal links
│  Persónuverndarstefna                        │
└──────────────────────────────────────────────┘
```

Notes on the layout, mapped to App Review 3.1.2 / HIG requirements:

- **The billed amount + period is the most prominent pricing element** and sits on the
  same screen as the purchase button (Apple requires this; see research §A2). The trial
  length and the post-trial price appear together in one sentence directly under the CTA.
- **Restore** is on the sheet itself, not buried in Settings (it is *also* in Settings).
- **Terms + Privacy links** on the sheet. Terms → Apple Standard EULA URL; Privacy →
  `Strings.Links.privacyPolicy`.
- One product, one button. No plan picker, no pre-selected toggles, no "lifetime" decoys,
  no strikethrough anchor prices, no countdown timers, no social-proof carousel.
- `2.990 kr.` above is illustrative only — render `product.displayPrice` verbatim (T10).

### 3.2 Copy — headline block

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `paywallHeadline` | Lyklaborð+ lærir á þig | Lyklaborð+ learns you |
| `paywallTagline` | Persónulega lagið ofan á ókeypis lyklaborðinu. | The personal layer on top of the free keyboard. |
| `paywallIntro` | Lyklaborðið sjálft er ókeypis og verður það áfram — full íslensk og ensk leiðrétting, orðauppástungur og beygingargreind. Lyklaborð+ bætir við laginu sem er persónulegt fyrir þig. | The keyboard itself is free and stays free — full Icelandic and English correction, suggestions, and inflection intelligence. Lyklaborð+ adds the layer that is personal to you. |

Headline rationale: the pinned framing "the layer that learns you" refined to
**"Lyklaborð+ lærir á þig"** — the Icelandic idiom *að læra á e-n/e-ð* ("to figure someone
out, learn how something works") is warmer and more precise than a literal "lærir þig".
The tagline keeps the pinned "personal layer" framing as the subtitle.

### 3.3 Copy — feature rows

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `featureVocabTitle` | Persónulegt orðasafn | Personal vocabulary |
| `featureVocabDetail` | Lyklaborðið lærir orðin þín — nöfn, slangur, fagorð — og þú stýrir safninu í orðabókarritlinum, með innflutningi úr SwiftKey. | The keyboard learns your words — names, slang, jargon — and you manage the collection in the dictionary editor, with import from SwiftKey. |
| `featureTouchTitle` | Lærir ásláttinn þinn | Learns your typing touch |
| `featureTouchDetail` | Lyklaborðið lærir hvar fingurnir þínir lenda í raun og veru á lyklunum og verður nákvæmara fyrir þig með tímanum. | The keyboard learns where your fingers actually land on the keys and gets more accurate for you over time. |
| `featureSyncTitle` | iCloud samstilling | iCloud sync |
| `featureSyncDetail` | Orðasafnið þitt fylgir þér dulkóðað á milli tækja — í þínu eigin iCloud, án reiknings hjá okkur. | Your vocabulary follows you, encrypted, across devices — in your own iCloud, with no account with us. |
| `paywallTrustLine` | Gögnin þín eru alltaf þín — útflutningur er ókeypis, með eða án áskriftar. | Your data is always yours — export is free, with or without a subscription. |

Feature-row rules: exactly three rows, one honest sentence each, no "and much more…",
no checkmark-vs-✕ comparison table against the free tier (a comparison table frames free
as deficient; the intro paragraph already frames free as complete).

### 3.4 Copy — CTA, disclosure, footer

Trial-eligible (`isEligibleForIntroOffer == true`):

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `trialCTA` | Prófa frítt í 14 daga | Try free for 14 days |
| `trialDisclosure(price)` | Frítt í 14 daga, síðan {price} á ári. Endurnýjast sjálfkrafa þar til sagt er upp — þú getur sagt upp hvenær sem er. | Free for 14 days, then {price} per year. Renews automatically until cancelled — you can cancel anytime. |

Not eligible (previous subscriber / trial used):

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `subscribeCTA(price)` | Gerast áskrifandi — {price} á ári | Subscribe — {price} per year |
| `renewDisclosure` | Endurnýjast sjálfkrafa árlega þar til sagt er upp — það er hægt hvenær sem er í App Store stillingunum þínum. | Renews automatically each year until cancelled — you can do that anytime in your App Store settings. |

Shared:

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `restoreButton` | Endurheimta kaup | Restore purchases |
| `termsLinkTitle` | Skilmálar (Apple Standard EULA) | Terms (Apple Standard EULA) |
| `privacyLinkTitle` | Persónuverndarstefna | Privacy policy |
| `priceLoading` | Sæki verð úr App Store… | Fetching price from the App Store… |
| `priceUnavailable` | Ekki tókst að sækja verð úr App Store — athugaðu netsamband og reyndu aftur. | Couldn't fetch the price from the App Store — check your connection and try again. |
| `closeButton` | Loka | Close |

While the price loads, the CTA is disabled and shows `priceLoading`; the sheet is fully
dismissible the whole time (T8). If StoreKit returns nothing, show `priceUnavailable`
where the disclosure would be — never a CTA without a visible price.

### 3.5 Purchase outcomes

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `purchaseFailed` | Kaupin tókust ekki og ekkert var gjaldfært. Reyndu aftur. | The purchase didn't go through and nothing was charged. Try again. |
| `purchasePending` | Beðið eftir samþykki (til dæmis „Ask to Buy“). Áskriftin virkjast sjálfkrafa um leið og kaupin eru staðfest. | Waiting for approval (for example "Ask to Buy"). The subscription activates automatically once the purchase is confirmed. |
| `thanksTitle` | Takk fyrir stuðninginn! | Thank you for the support! |
| `thanksBody` | Lyklaborð+ er virkt — persónulega orðasafnið þitt, aðlögun að áslætti og iCloud samstillingin eru í gangi. | Lyklaborð+ is active — your personal vocabulary, touch adaptation, and iCloud sync are on. |

On success the sheet content is replaced in place by the thanks state (checkmark, title,
body, "Loka") — no confetti, no rating prompt piggybacked on the purchase moment.
If the purchase started a trial, use the trial-start variant instead (§6.2).

---

## 4. First-run onboarding

The setup flow (Byrjun tab: enable keyboard → Full Access explainer → try-it pad) is
**never gated and never branches on entitlement**. Plus is mentioned exactly once, softly:
a card *below* the try-it pad, i.e. after the user has a working free keyboard. The user
scrolls past it; nothing blocks, nothing is modal.

```
│  … tryHeading / try-it pad …                 │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │  Lyklaborð+                            │  │
│  │  Allt sem þú sérð hér er ókeypis —     │  │
│  │  og verður það áfram. Lyklaborð+       │  │
│  │  bætir við persónulega laginu:         │  │
│  │  orðasafninu þínu, aðlögun að áslætti  │  │
│  │  og iCloud samstillingu.               │  │
│  │                                        │  │
│  │  [ Kynntu þér Lyklaborð+  › ]          │  │
│  └────────────────────────────────────────┘  │
```

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `onboardingPlusTitle` | Lyklaborð+ | Lyklaborð+ |
| `onboardingPlusBody` | Allt sem þú sérð hér er ókeypis — og verður það áfram. Lyklaborð+ bætir við persónulega laginu: orðasafninu þínu, aðlögun að áslætti og iCloud samstillingu. | Everything you see here is free — and stays free. Lyklaborð+ adds the personal layer: your vocabulary, touch adaptation, and iCloud sync. |
| `learnMoreButton` | Kynntu þér Lyklaborð+ | Learn about Lyklaborð+ |

Tapping the card's button opens the paywall sheet (§3). Dismissing it does nothing else —
the card remains as a passive part of the Byrjun tab (it sits still; T5 allows it).
No "skip" ceremony is needed because there is nothing to skip.

---

## 5. Feature-gate touchpoints

Design rule for every gate: **show the feature, not a wall of gray.** The un-entitled user
sees a live, honest preview of what the feature would do *with their own data*, plus a soft
CTA. Nothing is blurred, nothing is fake, no lock-icon dramatics.

### 5.1 Orðasafn (dictionary editor)

Un-entitled state of the Orðasafn tab: the keyboard's learning pipeline records candidates
regardless of entitlement (they just don't activate in typing), so the tab can show the
truth — a **read-only preview** of what has been learned so far, with editing, adding,
and activation gated.

```
│  Orðasafn                                    │
│  ┌────────────────────────────────────────┐  │
│  │  Orðasafnið er hluti af Lyklaborð+     │  │
│  │  Lyklaborðið sjálft heldur áfram að    │  │
│  │  virka ókeypis að fullu. Með           │  │
│  │  Lyklaborð+ virkjast orðin hér fyrir   │  │
│  │  neðan í uppástungum og leiðréttingum  │  │
│  │  — allt sem lyklaborðið hefur þegar    │  │
│  │  lært er geymt og kviknar um leið og   │  │
│  │  þú byrjar.                            │  │
│  │  [ Kynntu þér Lyklaborð+  › ]          │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  BÍÐUR EFTIR LYKLABORÐ+         (12 orð)     │
│    Vigdís                                    │
│    slettur                                   │
│    …                        (read-only)      │
```

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `lockedDictionaryTitle` | Orðasafnið er hluti af Lyklaborð+ | The dictionary is part of Lyklaborð+ |
| `lockedDictionaryBody` | Lyklaborðið sjálft heldur áfram að virka ókeypis að fullu. Með Lyklaborð+ virkjast orðin hér fyrir neðan í uppástungum og leiðréttingum — allt sem lyklaborðið hefur þegar lært er geymt og kviknar um leið og þú byrjar. | The keyboard itself keeps working fully, free. With Lyklaborð+ the words below activate in suggestions and corrections — everything the keyboard has already learned is stored and lights up the moment you start. |
| `lockedDictionarySection(n)` | Bíður eftir Lyklaborð+ ({n} orð) | Waiting for Lyklaborð+ ({n} words) |
| `lockedDictionaryEmpty` | Lyklaborðið hefur ekki rekist á nein ný orð ennþá — skrifaðu eins og venjulega og þau birtast hér. | The keyboard hasn't run into any new words yet — type as usual and they'll show up here. |

Interactions while gated: rows are visible but not editable; "Bæta við orði" and swipe
actions open the paywall sheet on tap (explicit intent, T3a). Search works (it's the
user's data). **Export works** (T9): the export button is present and functional in this
state and labeled exactly as in the free strings (`DataExport.button`).

### 5.2 SwiftKey import

The picker and the parse are free — the user can see exactly what would come in. Only
*applying* the import is gated.

Flow (un-entitled): explainer → file picker → parse → preview screen:

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `importPreviewTitle(n)` | Fann {n} orð í SwiftKey-útflutningnum | Found {n} words in the SwiftKey export |
| `importPreviewBody` | Þessi orð flytjast inn í persónulega orðasafnið þitt með Lyklaborð+ — og þau eru geymd hér þangað til, þannig að þú þarft ekki að velja skrána aftur. | These words import into your personal vocabulary with Lyklaborð+ — and they're kept here until then, so you won't need to pick the file again. |
| `importPreviewCTA` | Kynntu þér Lyklaborð+ | Learn about Lyklaborð+ |

Entitled users see the same preview with the CTA replaced by the normal apply button.
The staged file honors its promise: if the user subscribes later, the import applies
without re-picking.

### 5.3 iCloud sync toggle (Settings)

The toggle renders disabled (off) with the section footer swapped:

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `lockedSyncFooter` | iCloud samstilling orðasafnsins er hluti af Lyklaborð+. | iCloud sync of your dictionary is part of Lyklaborð+. |

Tapping the disabled row opens the paywall sheet (explicit intent). No other decoration.

### 5.4 "Your keyboard just learned its first word"

The one proactive soft CTA in the product, and it fires **in the app only** (never the
extension, T1), the next time the user happens to open the app after the first learn
candidate lands. It is a card at the top of the Orðasafn tab (and mirrored on Byrjun if
that tab is frontmost), not a modal.

```
┌────────────────────────────────────────┐
│  Lyklaborðið þitt lærði sitt fyrsta orð │
│  „{word}“ er tilbúið í orðasafnið      │
│  þitt. Með Lyklaborð+ birtist það í    │
│  uppástungum og leiðréttingum — og     │
│  allt sem lærist hér eftir sömuleiðis. │
│  [ Kynntu þér Lyklaborð+ ]  [ Ekki núna ] │
└────────────────────────────────────────┘
```

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `firstWordTitle` | Lyklaborðið þitt lærði sitt fyrsta orð | Your keyboard learned its first word |
| `firstWordBody(word)` | „{word}“ er tilbúið í orðasafnið þitt. Með Lyklaborð+ birtist það í uppástungum og leiðréttingum — og allt sem lærist hér eftir sömuleiðis. | "{word}" is ready for your dictionary. With Lyklaborð+ it shows up in suggestions and corrections — and so does everything learned from here on. |
| `notNowButton` | Ekki núna | Not now |
| `milestoneTitle(n)` | Lyklaborðið hefur lært {n} orð fyrir þig | Your keyboard has learned {n} words for you |
| `milestoneBody` | Þau bíða í orðasafninu þínu — geymd og tilbúin. Með Lyklaborð+ virkjast þau öll í einu. | They're waiting in your dictionary — stored and ready. With Lyklaborð+ they all switch on at once. |

Cooldown rules (T5): `firstWord` shows once, ever. One `milestone` variant may show at
25+ pending words, at least 14 days after the first card was dismissed — and then never
again. "Ekki núna" is a plain dismissal; it is never worded as a concession ("No thanks,
I don't like accuracy" is the banned pattern).

---

## 6. Trial lifecycle

### 6.1 Trial length: 14 days (decision)

Pinned range was 2–4 weeks; this document fixes **14 days**, configured as a StoreKit
introductory offer (free trial) on `is.solberg.lyklabord.plus.annual`.

Reasoning (details + citations in research appendix §A5):

- The personal layer's value **compounds**: learned words need the 2-distinct-days rule to
  activate, and coordinate adaptation needs typing volume. A 7-day trial risks expiring
  before the "it knows me now" moment; RevenueCat's data shows 10–16-day trials convert
  at the same median rate as shorter ones (~44–45%) with far fewer day-0 panic
  cancellations, and habit-formation products specifically benefit from ≥14 days.
- Against 21–28 days: longer trials don't improve activation for a keyboard that gets used
  hundreds of times daily — two weeks is plenty of typing — and they push the trust
  problem out (people forget; Apple sends **no** trial-ending reminder, so the whole
  forgot-to-cancel risk is ours to manage, and a shorter window plus our in-app notice
  manages it more honestly).
- 14 days also covers two weekly life-cycles (work-week + weekend writing styles), which
  matters for vocabulary coverage.

### 6.2 Trial start confirmation

Shown in the paywall sheet, replacing its content in place after StoreKit confirms:

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `trialStartedTitle` | Prufan er hafin | Your trial has started |
| `trialStartedBody(date, price)` | Næstu 14 daga er Lyklaborð+ virkt: persónulega orðasafnið þitt, aðlögun að áslætti og iCloud samstillingin. Ekkert verður gjaldfært fyrr en {date} — og þú getur sagt upp hvenær sem er í App Store stillingunum þínum. | For the next 14 days Lyklaborð+ is active: your personal vocabulary, touch adaptation, and iCloud sync. Nothing is charged until {date} — and you can cancel anytime in your App Store settings. |
| `trialStartedReminderNote(date)` | Apple sendir ekki áminningu áður en prufan rennur út — en við látum þig vita hér í appinu nokkrum dögum fyrir {date}. | Apple doesn't send a reminder before the trial ends — but we'll let you know here in the app a few days before {date}. |

`trialStartedReminderNote` is the single highest-trust sentence in the product: we
volunteer the thing every other app hides.

### 6.3 Mid-trial and expiry-approaching states

**Settings status row (mid-trial):** see the state table in §7.3
(`statusTrial` / `statusTrialCancelled`).

**Expiry-approaching notice** — in-app only (T6: no push, no notification permission).
During the final 3 days of the trial, a passive banner appears at the top of the Settings
subscription section and the Orðasafn tab. It is informational, dismissible, and reappears
at most once per day. It exists to keep the §6.2 promise, not to convert.

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `trialEndingBanner(date, price)` | Prufan rennur út {date}. Þá hefst áskriftin á {price} á ári — eða þú segir upp fyrir þann tíma og orðasafnið þitt geymist samt. | Your trial ends {date}. The subscription then starts at {price} per year — or you cancel before then and your dictionary is kept anyway. |
| `trialEndingManageLink` | Stjórna áskrift | Manage subscription |

The banner links to `showManageSubscriptions` — i.e. the honest paywall's mirror image:
we make **cancelling** one tap from the reminder. Decision: **no notification of any
kind outside the app** (default from the brief, confirmed). A keyboard is opened hundreds
of times a day but the *app* may not be; even so, a push notification asking for money is
exactly the pattern this product exists to reject, and the retained-data promise (§6.4)
makes a missed reminder low-stakes: worst case is one honest annual charge the user can
refund via Apple, not lost data.

Cancelled-during-trial: entitlement continues to trial end (StoreKit behavior). Status row
shows `statusTrialCancelled` (§7.3); no other UI reacts. No win-back sheet, no "are you
sure" — the user's decision is respected silently.

### 6.4 Day-after-expiry: the retained-but-paused screen (the trust moment)

**Never a modal, never on launch (T4).** The state renders where the user meets their
data: the Orðasafn tab header card, with a short echo in Settings. This screen delivers
pinned promise #4 and must be word-perfect.

```
┌────────────────────────────────────────────┐
│  Prufunni er lokið — orðasafnið þitt er    │
│  ennþá hér                                 │
│                                            │
│  Allt sem lyklaborðið lærði er geymt hér,  │
│  óbreytt — það er bara í hvíld og birtist  │
│  ekki í uppástungum í bili. Ekkert var     │
│  gjaldfært.                                │
│                                            │
│  Gerist þú áskrifandi vaknar það allt      │
│  samstundis, nákvæmlega eins og þú skildir │
│  við það. Og gögnin þín eru þín: þú getur  │
│  flutt þau út ókeypis, núna eða hvenær     │
│  sem er.                                   │
│                                            │
│  [ Gerast áskrifandi — {price} á ári ]     │
│  [ Flytja út gögnin mín ]      (ókeypis)   │
└────────────────────────────────────────────┘
```

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `trialEndedTitle` | Prufunni er lokið — orðasafnið þitt er ennþá hér | Your trial is over — your dictionary is still here |
| `trialEndedBody1` | Allt sem lyklaborðið lærði er geymt hér, óbreytt — það er bara í hvíld og birtist ekki í uppástungum í bili. Ekkert var gjaldfært. | Everything the keyboard learned is stored here, unchanged — it's just resting and won't appear in suggestions for now. Nothing was charged. |
| `trialEndedBody2` | Gerist þú áskrifandi vaknar það allt samstundis, nákvæmlega eins og þú skildir við það. Og gögnin þín eru þín: þú getur flutt þau út ókeypis, núna eða hvenær sem er. | If you subscribe, it all wakes up instantly, exactly as you left it. And your data is yours: you can export it free, now or anytime. |
| `trialEndedExportNote` | (ókeypis) | (free) |

The two action buttons reuse `subscribeCTA(price)` (§3.4 — trial no longer eligible) and
`DataExport.button`. The card is dismissible; once dismissed it collapses to the section
header `lockedDictionarySection(n)` state (§5.1). The Orðasafn otherwise returns to the
§5.1 read-only-preview state — the user keeps *seeing* their words, which is the retained
promise made visible.

Copy discipline for this screen: state the pause plainly ("í hvíld" — resting), confirm
no charge happened, promise instant restoration, and put free export on equal visual
footing with the subscribe button. No guilt ("we're sad to see you go"), no urgency, no
discount offer.

---

## 7. Lapse, resubscribe, restore — and the Settings section

### 7.1 Lapse after a paid year

Identical mechanics to trial expiry (§6.4) with adjusted first lines:

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `lapsedTitle` | Áskriftin rann út — orðasafnið þitt er ennþá hér | Your subscription ended — your dictionary is still here |
| `lapsedBody1(date)` | Áskriftin rann út {date}. Allt sem lyklaborðið hefur lært er geymt, óbreytt — það er í hvíld og birtist ekki í uppástungum í bili. | The subscription ended {date}. Everything the keyboard has learned is stored, unchanged — it's resting and won't appear in suggestions for now. |
| (reuse) `trialEndedBody2` | — | — |

iCloud sync pauses on lapse; the encrypted copy in the user's iCloud is untouched (and
"Eyða gögnum úr iCloud" keeps working — delete is never gated, T9).

### 7.2 Resubscribe and restore

- **Resubscribe:** any Plus entry point opens the standard paywall (§3) in its
  not-eligible variant (`subscribeCTA`). On success, the thanks state (§3.5) plus one
  extra line acknowledging the restoration promise being kept:

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `welcomeBackBody` | Allt sem lyklaborðið hafði lært er vaknað aftur — orðasafnið þitt er nákvæmlega eins og þú skildir við það. | Everything the keyboard had learned is awake again — your dictionary is exactly as you left it. |

- **Restore purchases** (new device / reinstall): `restoreButton` on the paywall and in
  Settings. Outcomes:

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `restoreFailed` | Ekki tókst að endurheimta kaup — athugaðu netsamband og reyndu aftur. | Couldn't restore purchases — check your connection and try again. |
| `restoreNothingFound` | Engin fyrri kaup fundust á þessum App Store reikningi. | No previous purchases were found on this App Store account. |

- **Billing grace period:** enable App Store Connect Billing Grace Period (16 days,
  existing-paid renewals). During grace, entitlement stays on and the status row explains
  rather than punishes (`statusGrace` below). Apple's own payment-update sheet handles the
  fix; we add no nagging of our own.

### 7.3 Settings → Áskrift section

```
ÁSKRIFT
┌────────────────────────────────────────────┐
│ Lyklaborð+                {status line}    │
│ Kynntu þér Lyklaborð+  ›     (if inactive) │
│ Stjórna eða segja upp áskrift ›  (if any)  │
│ Endurheimta kaup                           │
└────────────────────────────────────────────┘
{settingsFooter}
```

Status line — full state table:

| State | Key | Íslenska (ships) | English (reference) |
|---|---|---|---|
| unknown | `statusUnknown` | Athuga stöðu… | Checking status… |
| never subscribed | `statusNotEntitled` | Engin áskrift | No subscription |
| trial, renewing | `statusTrial(n, price)` | Frí prufa — {n} dagar eftir, síðan {price} á ári | Free trial — {n} days left, then {price} per year |
| trial, cancelled | `statusTrialCancelled(date)` | Prufa virk til {date} — endurnýjast ekki | Trial active until {date} — will not renew |
| active, renewing | `statusEntitledUntil(date)` | Virk áskrift — endurnýjast {date} | Active — renews {date} |
| active, cancelled | `statusEntitledLapsing(date)` | Virk til {date} — endurnýjast ekki | Active until {date} — will not renew |
| billing grace | `statusGrace` | Greiðsla tókst ekki — Lyklaborð+ helst virkt á meðan Apple reynir aftur. Athugaðu greiðslumátann í App Store stillingunum þínum. | Payment failed — Lyklaborð+ stays active while Apple retries. Check your payment method in your App Store settings. |
| expired/lapsed | `statusExpired(date)` | Áskrift rann út {date} — orðasafnið þitt er geymt | Subscription ended {date} — your dictionary is kept |
| DEBUG builds | `statusDebugNote` | Þróunarsmíð (DEBUG): allir eiginleikar opnir án áskriftar. | Development build (DEBUG): all features unlocked without a subscription. |

Rows:

| Key | Íslenska (ships) | English (reference) |
|---|---|---|
| `settingsSectionTitle` | Áskrift | Subscription |
| `statusRowTitle` | Lyklaborð+ | Lyklaborð+ |
| `learnMoreButton` | Kynntu þér Lyklaborð+ | Learn about Lyklaborð+ |
| `manageButton` | Stjórna eða segja upp áskrift | Manage or cancel subscription |
| `settingsFooter` | Lyklaborð+ opnar persónulega lagið: orðasafnið þitt, aðlögun að áslætti og iCloud samstillingu. Grunnlyklaborðið er ókeypis og opinn hugbúnaður — áskriftin styður áframhaldandi þróun. | Lyklaborð+ unlocks the personal layer: your vocabulary, touch adaptation, and iCloud sync. The base keyboard is free and open source — the subscription funds continued development. |

`manageButton` calls `showManageSubscriptions(in:)` and is present in **every** entitled
or formerly-entitled state — cancelling is always one tap from where subscribing is. The
word "segja upp" (cancel) appears in the row label itself, on purpose.

---

## 8. Banned patterns (from research — see appendix §A6)

Never, in any subscription surface:

1. **Fake urgency** — countdowns, "offer ends tonight", strikethrough anchor prices,
   blinking discounts.
2. **Delayed or hidden dismissal** — invisible ✕, ✕ that appears after N seconds, paywalls
   that re-present on dismiss.
3. **Double-negative / shame buttons** — "No thanks, I like typos."
4. **Pre-selected plans or toggles** — there is one product; nothing is pre-checked.
5. **Trial-first CTA that hides the price** — "Try free" with the annual price in 8pt gray.
   Price and period sit in the same sentence as the trial, adjacent to the CTA.
6. **Launch interstitials and takeovers** — including "what's new in Plus" full-screens.
7. **Push notifications about money** (T6).
8. **Feature regression** — moving anything free behind Plus later (the Fantastical
   lesson; pinned decision 5).
9. **Gray-wall previews** — blurred content, fake placeholder rows, padlock theater over
   the user's own data.
10. **Paying to stop being annoyed** — no ads, no nags whose removal is the product.
    Plus sells a layer, not relief.
11. **Decoy pricing** — no weekly plan priced to make annual look cheap, no "lifetime"
    anchor we don't mean.
12. **Rating prompts or cross-sells piggybacked** on purchase, trial, or cancellation
    moments.

---

## 9. Strings.swift delta (for the App/ owner)

Existing `Strings.Plus` keys that this document **changes**:

| Key | Change |
|---|---|
| `paywallTagline` | Becomes the subtitle under new `paywallHeadline` ("Lyklaborð+ lærir á þig"); case fix "lyklaborðið" → "lyklaborðinu" (static position takes dative). |
| `featureVocabDetail` | Minor rewording (drop "í orðabókarritlinum" repetition — see §3.3 exact text). |
| `subscribeButton(price)` | Now the not-eligible variant only; add `trialCTA` + `trialDisclosure(price)` for eligible users. |
| `legalFooter` | Superseded by `renewDisclosure` / `trialDisclosure` (same content, per-variant). |
| `statusEntitled` | Superseded by the full state table (§7.3): add `statusTrial`, `statusTrialCancelled`, `statusEntitledLapsing`, `statusGrace`, `statusExpired`. |
| `lockedDictionaryBody` | Reworded to reference the visible read-only preview (§5.1). |
| `thanksBody` | "innsláttarlærdómurinn" → "aðlögun að áslætti" (house term for the touch-adaptation noun). |
| `settingsFooter` | "innsláttarlærdóm" → "aðlögun að áslætti" for consistency with `featureTouchTitle`. |

All new/changed Icelandic strings in this document were review-passed through Gemini
(gemini-3.1-pro-preview, per the house translate-to-icelandic rule) on 2026-07-17;
corrections were adopted for items 3, 5 (partially), 7, 8, 11, 18, 19, 20 of that
review. "App Store stillingunum þínum" and unhyphenated "iCloud samstilling" are retained
over Gemini's suggestions for consistency with already-shipped strings (`legalFooter`,
`syncSectionTitle`); neither quotes a specific iOS menu item.

New keys: `paywallHeadline`, `paywallTrustLine`, `trialCTA`, `trialDisclosure`,
`renewDisclosure`, `onboardingPlusTitle/Body`, `lockedDictionarySection`,
`lockedDictionaryEmpty`, `importPreviewTitle/Body/CTA`, `firstWordTitle/Body`,
`notNowButton`, `milestoneTitle/Body`, `trialStartedTitle/Body/ReminderNote`,
`trialEndingBanner`, `trialEndingManageLink`, `trialEndedTitle/Body1/Body2/ExportNote`,
`lapsedTitle`, `lapsedBody1`, `welcomeBackBody`, `statusGrace`, `statusExpired`,
`statusTrial`, `statusTrialCancelled`, `statusEntitledLapsing`.

Copy rules inherited from `App/Strings.swift` and binding here: Icelandic-first; iOS
system UI referenced verbatim in English ("App Store", "Ask to Buy", "Settings"); brand
name "Lyklaborð"/"Lyklaborð+" never translated or declined in UI labels; no markdown
emphasis in strings; price always `displayPrice`.

---

## 10. Open recommendations (pinned decisions stand; these are flagged, not adopted)

1. **Pay-once option** (Halide precedent): a one-time "Lyklaborð+ að eilífu" purchase at
   ~3× annual would defuse subscription fatigue for exactly this product's audience.
   Not in v1 (one product keeps the paywall honest and simple), but worth revisiting
   after launch data.
2. **Whole-number ISK price**: mirror Callsheet's praised whole-number pricing when
   setting the ISK tier (e.g. 2.990 kr. — pick the cleanest tier available); the $19
   anchor stands.
3. **Trial length A/B**: if 14 days ever gets revisited, move within the pinned 2–4-week
   range only; never below.
