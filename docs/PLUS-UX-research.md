# Lyklaborð+ UX — Research Appendix

Companion to `docs/PLUS-UX.md`. Research performed 2026-07-17. Section numbers (§A1…)
are referenced from the main document.

---

## A1. Studied apps

### Overcast (Marco Arment)

- History: Patronage (pure goodwill, no exclusive features) converted ~1.9%; Arment then
  moved to free-with-ads + Premium ($9.99/yr) for ad removal and uploads, writing that
  the money has to come from somewhere and that for a daily-use app the incentive
  alignment of the model matters more than squeezing conversion.
  Source: [Overcast trying ads, dark theme now free — Marco.org](https://marco.org/2016/09/09/overcast-ads)
- What we take: **no feature the user had is ever taken away** when the business model
  evolves; upsells live where the gated feature lives (uploads screen, settings row) and
  nowhere else; the free tier is a complete product, not a demo.
- What we don't take: the ads compromise itself — Lyklaborð's privacy identity rules out
  ads entirely, so the Plus layer must carry the model alone.

### Flighty

- Apple Design Award winner; paywall documented at
  [paywall.tips/flighty](https://paywall.tips/flighty/): feature carousel up top, three
  visible tiers (yearly/weekly/lifetime) plus hidden family plans, social proof (Apple
  featuring, reviews), features presented as a flight-safety card. Notably **no trial**,
  no countdowns, no fake urgency; dismissal immediate.
- What we take: the *honest preview* instinct — Flighty demonstrates the product rather
  than dramatizing the lock; the feature-explanation rows carry the sell.
- What we don't take: five purchase options; even a sympathetic reviewer found it
  "lacking in focus." Lyklaborð+ is one product, one button.

### Halide (Lux)

- Lux explains directly why the app costs money
  ([Why is Halide not free? — lux.camera](https://www.lux.camera/why-is-halide-not-free/))
  and, in [Lux Year 4: Doubling Down](https://www.lux.camera/lux-year-4-doubling-down/),
  why they added a **Pay-Once option** ($60, deliberately under the ~$60 market they
  measured) beside the $19.99/yr membership — "to stem negativity" about subscriptions.
- What we take: the tone of explaining the business model to the user like an adult
  (mirrored in our `settingsFooter` and paywall intro paragraph); the $19.99/yr price
  point validates our $19 anchor for a daily-use pro-ish tool.
- Flagged for later (main doc §10): the pay-once escape valve is the single most
  effective subscription-fatigue antidote in this cohort.

### CARROT Weather

- Free to download, real free tier, 7-day trial, three clearly compared premium levels
  ([support.meetcarrot.com/weather](https://support.meetcarrot.com/weather/)).
- What we take: the free tier stays genuinely usable forever; trial exists and is stated
  plainly.
- What we don't take: three-tier laddering — unnecessary for a single-layer product.

### Bear

- Bear Pro is a short, quiet paywall: a handful of feature rows (sync, export, themes),
  cheap annual price, one-week trial, instantly dismissible; upgrade entry points are the
  gated features themselves (e.g. toggling sync). The app is fully usable free, forever.
  Source: [bear.app](https://bear.app/) and its in-app Pro sheet.
- What we take: **gate = entry point** (our §5 touchpoints), and sync as the flagship
  paid feature — infrastructure-flavored value people accept paying for.

### Fantastical (cautionary)

- The 2020 subscription transition drew heavy criticism for moving previously-owned
  features (calendar views, tasks) behind Premium and for the resulting perception of a
  degraded free tier, despite legacy-user grandfathering.
  Sources: [Daring Fireball](https://daringfireball.net/linked/2020/02/04/fantastical-3-app-store),
  [iMore on subscription fatigue](https://www.imore.com/app-subscription-fatigue-real-and-reaching-breaking-point).
- What we ban because of it: feature regression of any kind (main doc §8.8; pinned
  decision 5 — "nobody ever loses a feature they had" — is the exact inverse of the
  Fantastical mistake, adopted deliberately from v1 so there is never a transition
  moment at all).

### Apollo (historical)

- Christian Selig's Ultra paywall was famously friendly: plain feature list, cheap
  price, lifetime option, tip jars, zero urgency, dismissal always visible; upsells only
  at gated features. (App discontinued 2023; referenced from contemporary coverage and
  the app itself.)
- What we take: warmth as a differentiator — the paywall can sound like the developer
  talking, not a growth team.

### Callsheet (Casey Liss)

- **Metered trial**: first 20 searches free, no time pressure, then $1/mo / $9/yr with
  honest whole-number pricing; widely praised specifically for letting you truly use the
  app before paying.
  Sources: [caseyliss.com/2023/8/7/callsheet](https://www.caseyliss.com/2023/8/7/callsheet),
  [Six Colors](https://sixcolors.com/link/2023/08/callsheet-provides-a-clean-alternative-to-imdb/),
  [512 Pixels](https://512pixels.net/2023/08/callsheet/).
- What we take: the *experience-before-paying* principle, adapted: our read-only
  dictionary preview and SwiftKey parse-preview (main doc §5.1–5.2) are the metered-trial
  idea applied to a data product — you see exactly what Plus would activate, using your
  own data, before any purchase. Also the whole-number price instinct (§10.2).

### Ivory (Tapbots)

- Free download, read-only without subscription, $1.99/mo / $14.99/yr; Tapbots' support
  page states plainly why it's a subscription (API costs, sustainability).
  Sources: [tapbots.com/support/ivory/general/sub](https://tapbots.com/support/ivory/general/sub),
  [TechCrunch](https://techcrunch.com/2023/01/24/tapbots-launches-a-new-mastodon-client-ivory-after-twitter-kills-its-tweetbot-app/).
- What we take: the "why a subscription" explanation surfaced in-product.
- What we don't take: read-only-as-free-tier — Ivory's free tier is a demo. Lyklaborð's
  free tier must remain a complete keyboard (pinned decision 1).

---

## A2. Apple requirements (App Review 3.1.2 + subscription best practices)

From the [App Review Guidelines §3.1.2](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase)
and Apple's [auto-renewable subscription best practices](https://developer.apple.com/app-store/subscriptions/):

Hard requirements the paywall sheet satisfies (main doc §3):

1. Before asking to subscribe, clearly describe what the user gets for the price
   (3.1.2(c)) — feature rows + intro paragraph.
2. Sign-up screen must show subscription name/duration, and the **full renewal price
   clearly and prominently**; the billed amount must be **the most prominent pricing
   element**; savings breakdowns, if any, must be subordinate (we have none).
3. For free trials: **clearly indicate trial length and the price billed once the trial
   ends** — our `trialDisclosure` sentence sits directly under the CTA.
4. Communicate Schedule 2 terms: auto-renewal until cancelled, what is provided per
   period, actual charge, how to cancel — `trialDisclosure`/`renewDisclosure` +
   `manageButton`.
5. A way for existing subscribers to **restore purchases on the sign-up screen** —
   `restoreButton` on the sheet (and in Settings).
6. Ongoing value across devices (3.1.2) — iCloud sync of the personal model is the
   canonical cross-device value; ongoing value = continuous learning + sync + updates.
7. Reviewers frequently reject paywalls where price/period prominence is weak
   ([RevenueCat rejection guide](https://www.revenuecat.com/blog/growth/the-ultimate-guide-to-app-store-rejections/)) —
   hence the wireframe puts price+period in body-size text adjacent to the CTA, never
   in fine print.

Operational best practices adopted from the same Apple page: `showManageSubscriptions(in:)`
for in-app management; Billing Grace Period (16 days) so involuntary churn doesn't punish
users (main doc §7.2); win-back offers left to Apple's system surfaces rather than in-app
nagging; benefits may be presented once during onboarding (Apple explicitly endorses
this — main doc §4 does it as a passive card).

**Apple sends no trial-ending reminder.** Confirmed via Apple Support community threads
(e.g. [discussions.apple.com/thread/254580585](https://discussions.apple.com/thread/254580585),
[thread/251481896](https://discussions.apple.com/thread/251481896)): users are responsible
for cancelling ≥24h before renewal; no advance warning is sent. This is why
`trialStartedReminderNote` and the in-app expiry banner exist (main doc §6.2–6.3) — the
app takes on the reminder duty Apple declines, which is both the ethical position and a
differentiator no dark-pattern app will copy.

---

## A3. Patterns adopted (distilled)

| Pattern | From | Where in PLUS-UX.md |
|---|---|---|
| Free tier is a complete product; upsell lives only where gated features live | Overcast, Bear | §2 T1–T4, §5 |
| Experience the paid layer with your own data before paying (metered-preview) | Callsheet | §5.1, §5.2 |
| Explain the business model like an adult; developer voice | Halide, Ivory, Apollo | §1, §3.2, `settingsFooter` |
| One product, one button, no decoys | anti-Flighty simplification | §3, §8.11 |
| Feature rows do the selling; no lock theater | Flighty, Bear | §3.3, §5 |
| Cancel is as reachable as subscribe | Apple best practices | §6.3, §7.3 `manageButton` |
| Data retained on lapse, export always free | product identity + Overcast's no-regression ethos | §6.4, §7.1, T9 |
| Volunteer the trial-ending reminder Apple doesn't send | gap found in A2 | §6.2–6.3 |

## A4. Patterns banned (with the precedent that discredits each)

1. Fake urgency/countdowns/anchor-price strikethroughs — endemic in the paywall-template
   industry ([Adapty](https://adapty.io/paywall-library/) /
   [paywallscreens.com](https://www.paywallscreens.com/) galleries are catalogs of it);
   absent from every respected app studied.
2. Hidden/delayed close buttons — same.
3. Shame buttons ("No thanks, I like typos") — same.
4. Pre-selected plans/toggles — flagged even in conversion-focused literature as
   trust-destroying.
5. Trial-first CTA with the real price buried — the exact thing App Review rejects for
   prominence (A2.7).
6. Launch interstitials / "what's new in Premium" takeovers — the most common complaint
   in subscription-fatigue coverage
   ([iMore](https://www.imore.com/app-subscription-fatigue-real-and-reaching-breaking-point)).
7. Push notifications about billing — no studied app does it; a keyboard doing it would
   be disqualifying.
8. Feature regression — Fantastical (A1).
9. Gray-wall/blurred previews of the user's own data — inverse of Callsheet's metered
   openness.
10. Paying to remove annoyance — Overcast chose ads as a compromise; Lyklaborð refuses
    the category entirely.
11. Decoy pricing (weekly plans, unmeant lifetime anchors) — Flighty's weakest element
    per its own sympathetic review (A1).
12. Piggybacked rating prompts/cross-sells on purchase moments — general App Store
    hygiene; keeps the thanks screen a thanks screen.

## A5. Trial length evidence (decision: 14 days)

- RevenueCat's cross-app data: median trial-to-paid conversion is ~30% for ≤4-day
  trials vs ~44–45% for 5–9, 10–16, and 17–32-day trials — i.e. **beyond ~5 days,
  length doesn't hurt conversion**, but short trials cause panic-cancellations (55%+
  cancel day 0–1 on 3-day trials vs ~31% on 30-day).
  Sources: [revenuecat.com/blog/growth/app-trial-conversion-rate-insights](https://www.revenuecat.com/blog/growth/app-trial-conversion-rate-insights),
  [revenuecat.com/blog/growth/7-day-trial-subscription-app](https://www.revenuecat.com/blog/growth/7-day-trial-subscription-app).
- The same RevenueCat piece argues trial length should anchor to **time-to-value**:
  products whose value compounds (habit formation, learning, behavior change) and
  higher-commitment annual pricing justify ≥14 days; YNAB's 34-day trial is the extreme
  example (needs a full budgeting cycle).
- Lyklaborð's time-to-value: a learned word activates only after the 2-distinct-days
  rule; coordinate adaptation needs typing volume across contexts; vocabulary coverage
  spans work-week and weekend registers. Seven days risks expiring right at the "it
  knows me" moment; fourteen comfortably contains several learn-activate loops and two
  weekly cycles.
- Against 21–28 days (also allowed by the pinned range): activation doesn't improve
  further for an app used hundreds of times daily — RevenueCat found longer trials add
  starts but not activation ([Phiture's framework](https://phiture.com/mobilegrowthstack/the-subscription-stack-how-to-optimize-trial-length/)
  concurs) — and because Apple sends no reminder (A2), every extra trial day widens the
  forgot-I-had-a-trial window we'd then have to manage. 14 days is the honest optimum
  inside the pinned 2–4-week range.

## A6. Where research pushes on pinned decisions

1. **Pay-once option** (Halide): strongest evidence-backed challenge to
   subscription-only. Recommendation recorded in main doc §10.1; pinned single-product
   decision stands for v1.
2. **Metered trial instead of timed trial** (Callsheet): a pure metered model ("first
   50 learned words free") was considered and rejected — it would make the free keyboard
   *feel* like it degrades as the meter runs out, colliding with pinned decision 1. The
   adopted compromise: timed trial + always-on read-only preview.
3. **Trial at all?** Flighty converts with no trial. Rejected: a learning layer is
   precisely the product you must feel learn *you*; the trial is the demo.
4. Everything else in the pinned set (free-forever engine, retained-on-lapse data, free
   export, no keyboard-extension upsells) is *reinforced*, not challenged, by the
   research: it is the composite of what the respected apps are praised for.
