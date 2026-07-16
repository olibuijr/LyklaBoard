import Foundation

/// Lane-relaxation pricing (PLAN.md "Lane relaxation profiles").
///
/// One value is computed per correction call from the current lane
/// posterior and priced into BOTH candidate-cost paths — the beam decoder's
/// search currency and the exact spatial-DP re-score — so the two stay in
/// the same currency:
///
///   foldCost(char) = max(foldEpsilon, foldBaseCost · (1 − laneWeight))
///   laneWeight     = smoothstep(rampLo → rampHi)(P_lane)
///
/// Profiles (the fold set rationale lives in PLAN.md):
///  * IS — acute-vowel folding a→á e→é i→í o→ó u→ú y→ý (the six
///    long-press-gated vowels; ð þ æ ö have dedicated keys and never fold);
///    orthographic confusions (d→ð, t→þ, o→ö, ð↔þ) and gemination-shaped
///    indels lane-DISCOUNTED, never ~free (error class).
///  * EN — apostrophe folding (dont→don't: the omitted-apostrophe insertion
///    is priced at foldCost; folding only ever INSERTS apostrophes,
///    composing cleanly with the apostrophe-preservation auto-apply guard,
///    which forbids dropping them). Lone i→I lives in the corrector's
///    dedicated single-letter path.
///
/// Composition with the future per-tap provider (PLAN.md "Touch decoding"):
/// fold pricing sits ON TOP of the `PositionCostProvider` seam, it does not
/// replace it. A fold substitution is priced min(providerCost, foldCost)
/// today; when per-tap likelihoods land, the per-tap confidence will
/// MULTIPLY into the fold price (a dead-center tap on the BASE key is
/// exactly the lazy-input signal — fold stays cheap; a tap that selected an
/// accent via long-press/callout is a deliberateness veto, see
/// `vetoRelaxation`), so the provider swap never touches this type.
struct FoldPricing {
    /// laneWeight of the Icelandic profile, in [0, 1].
    let weightIS: Double
    /// laneWeight of the English profile, in [0, 1].
    let weightEN: Double
    /// Fold price of one acute-vowel fold under the IS profile.
    let acuteFoldCost: Double
    /// Scale factor on the orthographic-confusion constant (IS profile).
    let confusionScale: Double
    /// Scale factor on gemination-shaped indels (IS profile).
    let geminationScale: Double
    /// Deliberateness veto (a long-pressed character anywhere in the word):
    /// all relaxation is off — folds price at the neutral base cost, and
    /// no restoration-class auto-apply may fire for this word.
    let vetoRelaxation: Bool
    private let foldEpsilon: Double
    private let apostropheBaseCost: Double

    init(config: EngineConfig, pIcelandic: Double, vetoRelaxation: Bool = false) {
        self.vetoRelaxation = vetoRelaxation
        let lo = config.laneWeightRampLo
        let hi = config.laneWeightRampHi
        let wIS =
            (config.foldProfileISEnabled && !vetoRelaxation)
            ? Self.smoothstep(pIcelandic, lo: lo, hi: hi) : 0
        let wEN =
            (config.foldProfileENEnabled && !vetoRelaxation)
            ? Self.smoothstep(1 - pIcelandic, lo: lo, hi: hi) : 0
        self.weightIS = wIS
        self.weightEN = wEN
        self.foldEpsilon = config.foldEpsilon
        self.acuteFoldCost = max(config.foldEpsilon, config.foldBaseCost * (1 - wIS))
        self.confusionScale = 1 - wIS * config.confusionLaneDiscount
        self.geminationScale = 1 - wIS * config.geminationLaneDiscount
        self.apostropheBaseCost = config.spatialCosts.deletion
    }

    /// Neutral pricing (laneWeight 0 in both profiles): byte-identical to
    /// the pre-relaxation engine. Used at init time and wherever no lane
    /// posterior applies.
    static func neutral(config: EngineConfig) -> FoldPricing {
        FoldPricing(config: config, pIcelandic: 0.5)
    }

    /// Hermite smoothstep of `x` between lo and hi (0 below, 1 above).
    static func smoothstep(_ x: Double, lo: Double, hi: Double) -> Double {
        guard hi > lo else { return x >= hi ? 1 : 0 }
        let t = min(max((x - lo) / (hi - lo), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Restoration-class edit shapes

    /// Acute-vowel fold: typed the BASE letter, intended the long-press
    /// accent twin (a→á …). Direction matters — the reverse (typed á,
    /// intended a) is an ordinary error-class substitution: folding never
    /// removes accents.
    static func isAcuteFold(typed: Character, intended: Character) -> Bool {
        SpatialModel.accentBase[intended] == typed
    }

    /// Lane-discounted orthographic confusion: typed the plain letter for
    /// its Icelandic counterpart (d→ð, t→þ, o→ö) or slipped between the two
    /// Icelandic letters (ð↔þ). Directional like the fold set: ð→d etc.
    /// stay at the full confusion constant.
    static func isLaneConfusion(typed: Character, intended: Character) -> Bool {
        switch (typed, intended) {
        case ("d", "ð"), ("t", "þ"), ("o", "ö"), ("ð", "þ"), ("þ", "ð"):
            return true
        default:
            return false
        }
    }

    /// Word-internal apostrophes (straight + typographic) — the "English
    /// diacritic" the EN profile folds in (by insertion only).
    static func isApostrophe(_ character: Character) -> Bool {
        Corrector.apostrophes.contains(character)
    }

    // MARK: - Prices

    /// Lane price of a typed→intended substitution, or nil when the pair is
    /// not a lane-relaxation pair (the caller falls back to its base cost —
    /// the static SpatialModel or the PositionCostProvider).
    func substitutionPrice(
        typed: Character, intended: Character, confusionBase: Double
    ) -> Double? {
        if Self.isAcuteFold(typed: typed, intended: intended) {
            return acuteFoldCost
        }
        if Self.isLaneConfusion(typed: typed, intended: intended) {
            return max(foldEpsilon, confusionBase * confusionScale)
        }
        return nil
    }

    /// Price of a character the user OMITTED (an insertion in the
    /// candidate): apostrophes fold under the EN profile; everything else
    /// keeps the base omitted-character constant.
    func omissionPrice(of character: Character, base: Double) -> Double {
        guard Self.isApostrophe(character) else { return base }
        return max(foldEpsilon, min(base, apostropheBaseCost * (1 - weightEN)))
    }

    /// Price of a gemination-shaped indel (dropping one of a doubled typed
    /// letter, or omitting an intended doubling), given the base indel
    /// constant. IS-profile discount, error class.
    func geminationIndelPrice(base: Double) -> Double {
        max(foldEpsilon, base * geminationScale)
    }
}

/// Decomposed channel cost of one candidate: the lane-priced total (the
/// ranking/conservatism currency) plus the op-class split that keeps
/// restoration edits accounted SEPARATELY from error edits — a word with
/// three folds and one genuine fat-finger substitution prices ≈ the
/// substitution alone at a saturated lane, and a candidate whose every edit
/// is restoration-class is eligible for the relaxed auto-apply rules.
struct ChannelCost {
    /// Lane-priced total cost, in nats.
    var total: Double
    /// Error-class ops on the optimal alignment (substitutions outside the
    /// restoration set, indels, transpositions, completion characters).
    var errorOps: Int
    /// Restoration-class ops (acute folds, directional orthographic
    /// confusions, apostrophe insertions).
    var restorationOps: Int

    /// The candidate differs from the typed token by restoration alone.
    var isRestorationOnly: Bool { errorOps == 0 && restorationOps > 0 }
}

extension SpatialModel {
    /// Lane-priced variant of `typingCost` with the restoration/error op
    /// decomposition (see `ChannelCost`). At neutral pricing the total is
    /// byte-identical to `typingCost` — fold pairs already sat at the
    /// `minSubstitution` floor the neutral fold price equals.
    ///
    /// Alignment choice: lexicographic min on (cost, errorOps), so among
    /// equal-cost alignments the most restoration-shaped reading wins and
    /// `isRestorationOnly` is never spuriously false.
    func channelCost(
        typed: [Character], intended: [Character], pricing: FoldPricing
    ) -> ChannelCost {
        let n = typed.count
        let m = intended.count
        if n == 0 {
            var cost = 0.0
            var restoration = 0
            var errors = 0
            for character in intended {
                let price = pricing.omissionPrice(of: character, base: costs.deletion)
                cost += price
                if FoldPricing.isApostrophe(character) { restoration += 1 } else { errors += 1 }
            }
            return ChannelCost(total: cost, errorOps: errors, restorationOps: restoration)
        }
        if m == 0 {
            return ChannelCost(
                total: Double(n) * costs.insertion, errorOps: n, restorationOps: 0)
        }

        struct Cell {
            var cost: Double
            var errorOps: Int32
            var restorationOps: Int32
        }
        func better(_ a: Cell, _ b: Cell) -> Cell {
            if a.cost < b.cost { return a }
            if b.cost < a.cost { return b }
            return a.errorOps <= b.errorOps ? a : b
        }

        let width = m + 1
        var dp = [Cell](
            repeating: Cell(cost: 0, errorOps: 0, restorationOps: 0), count: (n + 1) * width)
        for i in 1...n {
            dp[i * width] = Cell(
                cost: Double(i) * costs.insertion, errorOps: Int32(i), restorationOps: 0)
        }
        for j in 1...m {
            let character = intended[j - 1]
            let previous = dp[j - 1]
            let price = pricing.omissionPrice(of: character, base: costs.deletion)
            let apostrophe = FoldPricing.isApostrophe(character)
            dp[j] = Cell(
                cost: previous.cost + price,
                errorOps: previous.errorOps + (apostrophe ? 0 : 1),
                restorationOps: previous.restorationOps + (apostrophe ? 1 : 0)
            )
        }

        for i in 1...n {
            let typedChar = typed[i - 1]
            for j in 1...m {
                let intendedChar = intended[j - 1]

                // Substitution / match.
                var best: Cell
                let diagonal = dp[(i - 1) * width + (j - 1)]
                if typedChar == intendedChar {
                    best = diagonal
                } else {
                    let base = substitutionCost(typed: typedChar, intended: intendedChar)
                    if let lane = pricing.substitutionPrice(
                        typed: typedChar, intended: intendedChar, confusionBase: base)
                    {
                        best = Cell(
                            cost: diagonal.cost + min(lane, base),
                            errorOps: diagonal.errorOps,
                            restorationOps: diagonal.restorationOps + 1
                        )
                    } else {
                        best = Cell(
                            cost: diagonal.cost + base,
                            errorOps: diagonal.errorOps + 1,
                            restorationOps: diagonal.restorationOps
                        )
                    }
                }

                // Extra typed character (deletion); gemination-shaped when
                // it duplicates its typed neighbor ("takkk" → "takk").
                let up = dp[(i - 1) * width + j]
                let deletionBase =
                    (i >= 2 && typed[i - 1] == typed[i - 2])
                    ? pricing.geminationIndelPrice(base: costs.insertion)
                    : costs.insertion
                best = better(
                    best,
                    Cell(
                        cost: up.cost + deletionBase,
                        errorOps: up.errorOps + 1,
                        restorationOps: up.restorationOps
                    )
                )

                // Omitted intended character (insertion); apostrophes fold
                // (EN profile), doublings get the gemination discount
                // ("tomorow" → "tomorrow").
                let left = dp[i * width + (j - 1)]
                let insertionBase: Double
                let insertionRestoration: Bool
                if FoldPricing.isApostrophe(intendedChar) {
                    insertionBase = pricing.omissionPrice(of: intendedChar, base: costs.deletion)
                    insertionRestoration = true
                } else if j >= 2, intended[j - 1] == intended[j - 2] {
                    insertionBase = pricing.geminationIndelPrice(base: costs.deletion)
                    insertionRestoration = false
                } else {
                    insertionBase = costs.deletion
                    insertionRestoration = false
                }
                best = better(
                    best,
                    Cell(
                        cost: left.cost + insertionBase,
                        errorOps: left.errorOps + (insertionRestoration ? 0 : 1),
                        restorationOps: left.restorationOps + (insertionRestoration ? 1 : 0)
                    )
                )

                // Transposition.
                if i >= 2, j >= 2,
                    typed[i - 1] == intended[j - 2],
                    typed[i - 2] == intended[j - 1],
                    typed[i - 1] != typed[i - 2]
                {
                    let corner = dp[(i - 2) * width + (j - 2)]
                    best = better(
                        best,
                        Cell(
                            cost: corner.cost + costs.transposition,
                            errorOps: corner.errorOps + 1,
                            restorationOps: corner.restorationOps
                        )
                    )
                }

                dp[i * width + j] = best
            }
        }
        let final = dp[n * width + m]
        return ChannelCost(
            total: final.cost,
            errorOps: Int(final.errorOps),
            restorationOps: Int(final.restorationOps)
        )
    }
}

