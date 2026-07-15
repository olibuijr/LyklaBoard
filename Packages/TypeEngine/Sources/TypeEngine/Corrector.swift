import Foundation
import Lexicon

/// One ranked suggestion.
public struct Suggestion: Equatable, Sendable {
    public let text: String
    /// True only on the top candidate, and only when the conservatism rules
    /// allow auto-replacement (typed word unknown everywhere + confidence
    /// margin met). A valid typed word NEVER yields isAutocorrect = true —
    /// with ONE sanctioned, lane-gated exception: single-letter accent
    /// restoration (a→á, i→í), where the bare letter may be valid in the
    /// OTHER language ("a" in English) but is not a word in the confident
    /// Icelandic lane (see `Corrector.singleLetterCorrection`).
    public let isAutocorrect: Bool
    /// Softmax posterior over the scored candidate pool, in (0, 1].
    public let confidence: Double
    /// True for the verbatim escape-hatch slot: the literal token the user
    /// typed, offered so it can be committed as-is (rendered quoted by the
    /// keyboard toolbar via KeyboardKit's `.unknown` suggestion type).
    /// Emitted by `TypingSession`, never by the corrector/predictor.
    public let isVerbatim: Bool

    public init(
        text: String,
        isAutocorrect: Bool,
        confidence: Double,
        isVerbatim: Bool = false
    ) {
        self.text = text
        self.isAutocorrect = isAutocorrect
        self.confidence = confidence
        self.isVerbatim = isVerbatim
    }
}

/// Result of correcting a single typed word.
public struct CorrectionResult {
    public let suggestions: [Suggestion]
    /// True when the typed word exists in either lexicon or is BÍN-valid.
    /// When true, suggestions are alternatives only (never autocorrect).
    public let typedWordIsValid: Bool
}

/// Noisy-channel corrector: spatial likelihood × blended language prior.
public struct Corrector {
    /// Candidate-generation alphabet: base latin + Icelandic letters +
    /// long-press accents + apostrophes (word-internal characters for
    /// contractions: "don't", "I'm"; both the straight and typographic
    /// forms iOS produces).
    static let alphabet: [Character] = Array("aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö'’")

    /// Word-internal apostrophe characters (straight + typographic).
    static let apostrophes: Set<Character> = ["'", "’"]

    let spatial: SpatialModel
    let model: BlendedLanguageModel
    let config: EngineConfig

    public init(
        icelandic: Lexicon,
        english: Lexicon,
        morphology: MorphologyProviding? = nil,
        config: EngineConfig = EngineConfig()
    ) {
        self.config = config
        self.spatial = SpatialModel(costs: config.spatialCosts)
        self.model = BlendedLanguageModel(
            icelandic: icelandic,
            english: english,
            morphology: morphology,
            config: config
        )
    }

    init(model: BlendedLanguageModel, config: EngineConfig) {
        self.config = config
        self.spatial = SpatialModel(costs: config.spatialCosts)
        self.model = model
    }

    /// Ranked correction candidates for `typed` (assumed a single word).
    ///
    /// - Parameters:
    ///   - typed: the word as typed (will be lowercased internally)
    ///   - previousWord: last committed word, for bigram context (lowercased)
    ///   - pIcelandic: current language posterior P(IS)
    ///   - limit: max suggestions returned
    public func correct(
        typed rawTyped: String,
        previousWord: String? = nil,
        pIcelandic: Double = 0.5,
        limit: Int = 3
    ) -> CorrectionResult {
        let typed = rawTyped.lowercased()
        let typedChars = Array(typed)
        guard !typedChars.isEmpty, limit > 0 else {
            return CorrectionResult(suggestions: [], typedWordIsValid: false)
        }

        // Hyphenated compound rule (PLAN.md "Compounds" + harness quirk
        // list): a token containing hyphens whose parts are each valid is
        // itself valid — never corrected, never walked through the edits2
        // landmine ("vel-þekkt" must not be rewritten to "velþekkt").
        if isValidHyphenatedCompound(typed) {
            return CorrectionResult(suggestions: [], typedWordIsValid: true)
        }

        // Personal-learning semantics fold in here (PLAN.md "Learning"):
        // learned/user-added words are valid (never auto-corrected away) —
        // and so are TOMBSTONED words, because deletion means "stop
        // suggesting", never "punish typing" (isValidTypedWord docs).
        let typedIsValid = model.isValidTypedWord(typed)

        // Single-letter input: the general pipeline is both too expensive
        // (1-char completion ranges) and too noisy for one letter — the only
        // useful correction is accent restoration (dogfood "giskar a allt":
        // a→á, i→í are extreme-frequency Icelandic words typed accentless
        // because accents live behind long-press). Dedicated targeted path.
        if typedChars.count == 1 {
            return singleLetterCorrection(
                letter: typedChars[0],
                previousWord: previousWord,
                pIcelandic: pIcelandic,
                typedIsValid: typedIsValid
            )
        }

        // ---- Candidate generation ----------------------------------------
        // word -> spatial cost
        var candidates: [String: Double] = [:]

        func admit(_ word: String) {
            guard word != typed, candidates[word] == nil else { return }
            // Tombstoned words are never offered, base-lexicon presence
            // notwithstanding (every generation pass funnels through here).
            guard !model.isPersonalTombstoned(word) else { return }
            candidates[word] = spatialCost(typedChars: typedChars, candidate: word)
        }

        // 1. edits1, existence-checked against lexicons + BÍN. Generated
        // with the spatial cost of the single edit attached (O(1) per
        // string), which step 5 uses to order its walk without recomputing
        // full edit-distance matrices.
        let e1 = Self.edits1Costed(of: typedChars, spatial: spatial)
        for word in e1.keys where isCandidateWord(word, checkMorphology: true) {
            admit(word)
        }

        // 2. Diacritic/orthographic restoration: all combinations of the
        // cheap Icelandic confusions (a→á, o→ó/ö, d→ð, t→þ, …) up to 3
        // positions, existence-checked. Targeted and tiny compared to
        // edits2, and exactly the accent-restoration case that matters on
        // this layout ("islenska"→"íslenska", "godan"→"góðan"): each
        // substitution costs only the spatial floor / orthographic-confusion
        // constant, so restored forms rank (and auto-apply) easily.
        for word in Self.diacriticVariants(of: typedChars)
        where isCandidateWord(word, checkMorphology: true) {
            admit(word)
        }

        // 2b. Gemination repairs: drop one of a doubled letter and/or double
        // another ("tommorow"→"tomorrow", "occured"→"occurred"; Icelandic
        // kk/ll/nn/tt geminates). These are the classic distance-2 typos a
        // budgeted edits2 walk can no longer be relied on to reach; the
        // variant set is tiny (≈ n² worst case) and existence-checked.
        for word in Self.geminationVariants(of: typedChars)
        where isCandidateWord(word, checkMorphology: true) {
            admit(word)
        }

        // 2c. Gemination + accent compositions ("nogg" → dedouble → "nog" →
        // o→ó → "nóg"; "huss" → "hús"): the classic Icelandic double-error
        // shape neither targeted pass reaches alone. Tiny: dedoubled bases
        // (≤ #doubled pairs) × their diacritic variants, existence-checked.
        for base in Self.dedoubledVariants(of: typedChars) {
            for word in Self.diacriticVariants(of: base, maxChanges: 2)
            where isCandidateWord(word, checkMorphology: true) {
                admit(word)
            }
        }

        // 3. Prefix completions of the typed word (completion-as-suggestion).
        for lexicon in [model.icelandic, model.english] {
            for completion in lexicon.completions(of: typed, limit: config.completionPoolLimit) {
                admit(completion.word)
            }
        }

        // 3b. Personal-vocabulary completions: learned/user-added words are
        // always suggestible, including OOV ones the base pools can never
        // produce ("veitingahusid" typed as "veitingahusi" must complete).
        for completion in model.personal.completions(
            of: typed, limit: config.personalCompletionPoolLimit)
        {
            admit(completion.word)
        }

        // 4. Completions of slightly shorter prefixes — but only when no
        // good close candidate exists yet (same gate as edits2): covers
        // suffix-area typos that neither edits1 nor typed-prefix completions
        // reach ("basicly"→"basically", "publically"→"publicly") far more
        // cheaply than an edits2 walk. Spatial cost still judges the
        // candidates, so junk from the wider buckets ranks on merit.
        if typedChars.count >= 5, (candidates.values.min() ?? .infinity) > config.edits2Gate {
            let shortestPrefix = max(3, typedChars.count - 4)
            for length in stride(from: typedChars.count - 1, through: shortestPrefix, by: -1) {
                let prefix = String(typedChars.prefix(length))
                for lexicon in [model.icelandic, model.english] {
                    for completion in lexicon.completions(of: prefix, limit: config.completionPoolLimit) {
                        admit(completion.word)
                    }
                }
                for completion in model.personal.completions(
                    of: prefix, limit: config.personalCompletionPoolLimit)
                {
                    admit(completion.word)
                }
            }
        }

        // 4b. Diacritic-restored prefix completions (dogfood "faralega" →
        // "fáránlega"): missing accents in the PREFIX combined with an
        // ordinary omission/typo in the tail are unreachable by every pass
        // above (3 edits from the typed word). Completing diacritic
        // variants of typed prefixes ("fárá" → fáránlega…) covers exactly
        // that shape. Icelandic-only (accents are the IS phenomenon), and
        // gated like edits2 — but on the best ATTESTED-or-personal
        // candidate, so BÍN-floored junk ("garalega") cannot suppress the
        // honest repair it is junk relative to.
        if !typedIsValid, typedChars.count >= 5,
            bestAttestedCost(in: candidates) > config.diacriticCompletionGate
        {
            // Shortest prefix first: it has the fewest variants and the
            // widest completion range, and the tail typo is more likely to
            // sit several characters back ("fara|lega" needs the length-4
            // prefix) — longest-first would burn the budget on
            // near-full-length variants that pass 2 mostly covered.
            var budget = config.diacriticCompletionMaxLookups
            let shortestPrefix = max(3, typedChars.count - 4)
            outer: for length in stride(from: shortestPrefix, through: typedChars.count, by: 1) {
                let prefix = Array(typedChars.prefix(length))
                for variant in Self.diacriticVariants(of: prefix, maxChanges: 2) {
                    guard budget > 0 else { break outer }
                    budget -= 1
                    for completion in model.icelandic.completions(
                        of: variant, limit: config.completionPoolLimit)
                    {
                        admit(completion.word)
                    }
                }
            }
        }

        // 5. edits2, only for words of length 5...edits2MaxLength with no
        // good edits1 hit, under BOTH an expansion cap and a wall-clock
        // budget (unknown long words otherwise walk hundreds of thousands
        // of expansions — the 300–935 ms/keystroke landmine). On abort we
        // simply keep the edits1/completion candidates found so far.
        // Existence check skips BÍN here: a full morphology probe per edits2
        // expansion is too expensive (~100µs each on the mmap-ed binary).
        let bestSoFar = candidates.values.min() ?? .infinity
        if typedChars.count >= 5, typedChars.count <= config.edits2MaxLength,
            bestSoFar > config.edits2Gate
        {
            // Walk the cheapest (most plausible) intermediate bases first:
            // under the expansion/time budgets, the part of the space that
            // gets explored is then the likeliest — and, unlike raw hash
            // order, deterministic across runs. Costs were attached at
            // edits1 generation, so ordering is just a sort.
            var orderedBases = Array(e1)
            orderedBases.sort { lhs, rhs in
                lhs.value < rhs.value || (lhs.value == rhs.value && lhs.key < rhs.key)
            }
            let deadline = ContinuousClock.now + .seconds(config.edits2TimeBudget)
            var expansions = 0
            outer: for entry in orderedBases {
                let base = entry.key
                // Materializing a base's edits1 set is itself milliseconds
                // for long words — check the budget per base, not just per
                // expansion, so the abort can't overshoot by a whole base.
                if ContinuousClock.now >= deadline { break }
                for word in Self.edits1(of: Array(base)) {
                    expansions += 1
                    if expansions > config.maxEdits2Expansions { break outer }
                    if expansions % 256 == 0, ContinuousClock.now >= deadline { break outer }
                    if word != typed, candidates[word] == nil,
                        isCandidateWord(word, checkMorphology: false)
                    {
                        admit(word)
                    }
                }
            }
        }

        // ---- Scoring ------------------------------------------------------
        // score = -spatialCost + λ·S_lang(candidate | context, posterior),
        // where S_lang blends per-lexicon CALIBRATED scores by the posterior
        // (see BlendedLanguageModel.blendedScore).
        var scored: [(word: String, spatialCost: Double, score: Double)] = candidates.map {
            word, cost in
            let s = model.blendedScore(of: word, previous: previousWord, pIcelandic: pIcelandic)
            return (word, cost, -cost + config.languageWeight * s)
        }

        // 6. Space-miss splits (PLAN.md "Space-miss correction"): an unknown
        // all-letter token with no good single-word candidate may be two
        // words around a missed/mis-hit spacebar tap. Gated exactly like
        // edits2 (unknown + the cheap passes' best spatial cost above the
        // gate — bestSoFar deliberately excludes edits2 junk), so ordinary
        // typos and prefixes-in-progress (which always have a cheap
        // completion) never pay for it. Split candidates join the same
        // scored pool: the channel cost (penalty + half repairs) plays the
        // spatial-cost role in ranking, conservatism and confidence.
        if !typedIsValid,
            typedChars.count >= config.splitMinLength,
            typedChars.allSatisfy(\.isLetter),
            bestSoFar > config.splitGate
        {
            scored.append(
                contentsOf: splitCandidates(
                    typedChars: typedChars,
                    previousWord: previousWord,
                    pIcelandic: pIcelandic
                )
            )
        }

        scored.sort { $0.score > $1.score || ($0.score == $1.score && $0.word < $1.word) }

        // ---- Conservatism / autocorrect decision --------------------------
        var autocorrect = false
        if !typedIsValid,
            let best = scored.first,
            typedChars.count >= config.minAutocorrectLength,
            best.spatialCost <= config.autocorrectMaxSpatialCost,
            Self.preservesApostrophes(of: typed, in: best.word)
        {
            let margin = scored.count > 1 ? best.score - scored[1].score : .infinity
            if best.word.contains(" ") {
                // Split auto-apply (dogfood "fara lega" tightening): a split
                // is a bigger intervention than a repair, so it must clear a
                // RAISED margin AND the merged token must have no plausible
                // attested/personal single-word repair within the generous
                // cost bound — if a one-word fix exists, the split stays
                // bar-only. BÍN-only forms never veto (junk one edit from
                // everything must not block "helloworld" → "hello world").
                let bestSingleCost = scored
                    .filter { !$0.word.contains(" ") && isAttestedOrPersonal($0.word) }
                    .map(\.spatialCost)
                    .min() ?? .infinity
                autocorrect = margin >= config.splitAutocorrectMargin
                    && bestSingleCost > config.splitAutoApplySingleWordCutoff
            } else {
                // Single-word auto-apply additionally requires the winner to
                // be typical vocabulary (attested at z ≥ autocorrectMinZ;
                // personal words are exempt): BÍN-floored junk like
                // "garalega" may be suggested but never auto-applied.
                let typicality =
                    model.isPersonalValid(best.word)
                    ? Double.infinity
                    : (attestedTypicality(of: best.word) ?? -.infinity)
                autocorrect = margin >= config.autocorrectMargin
                    && typicality >= config.autocorrectMinZ
            }
        }

        // ---- Confidence: softmax over the top of the candidate pool -------
        let confidencePool = scored.prefix(8)
        let maxScore = confidencePool.first?.score ?? 0
        let z = confidencePool.reduce(0.0) { $0 + exp($1.score - maxScore) }

        let suggestions = scored.prefix(limit).enumerated().map { index, entry in
            Suggestion(
                text: entry.word,
                isAutocorrect: index == 0 && autocorrect,
                confidence: z > 0 ? exp(entry.score - maxScore) / z : 0
            )
        }
        return CorrectionResult(suggestions: Array(suggestions), typedWordIsValid: typedIsValid)
    }

    // MARK: - Space-miss splits

    /// Split hypotheses for an unknown token (see `correct` step 6). Two
    /// generation classes, explored best-evidence-first under a wall-clock
    /// budget:
    ///
    /// 1. **Space-substitution** (cheap penalty): an interior letter that
    ///    sits directly above the spacebar (`SpatialModel
    ///    .spaceAdjacentLetters`, derived from key geometry) is consumed AS
    ///    the space — "smelirna" → "smelir"+"a".
    /// 2. **Space-insertion** (full omitted-keystroke penalty): a space is
    ///    inserted between two characters — "helloworld" → "hello"+"world".
    ///
    /// Each half must be exact-valid or cheaply repairable by the targeted
    /// passes (`halfHypotheses`); a candidate's score combines both halves'
    /// calibrated language scores — blended JOINTLY per lane, the second
    /// half conditioned on the first so bigram coherence is priced in (see
    /// `BlendedLanguageModel.blendedPairScore`) — plus the split penalty
    /// and any half repair costs:
    ///
    ///   score = -(penalty + cost_left + cost_right)
    ///           + λ·S_pair(left, right | prev, posterior)
    ///
    /// Returned tuples mirror the single-word pool's (word, spatialCost,
    /// score) shape; the channel cost stands in for the spatial cost in the
    /// autocorrect conservatism check.
    func splitCandidates(
        typedChars: [Character],
        previousWord: String?,
        pIcelandic: Double
    ) -> [(word: String, spatialCost: Double, score: Double)] {
        let n = typedChars.count
        guard n >= config.splitMinLength else { return [] }

        // (left, right, penalty, repairCap) hypotheses. Substitution splits
        // first (strongest evidence, smallest class), then insertion
        // splits; each class walked center-out — a missed space is
        // likeliest near the middle of the fused token — so the budget
        // sheds edges. Insertion splits get the tighter half-repair cap
        // (no tap evidence — see splitInsertionHalfRepairMaxCost).
        var hypotheses:
            [(left: [Character], right: [Character], penalty: Double, repairCap: Double)] = []
        let centerOut: (Int, Int) -> Bool = { lhs, rhs in
            let l = abs(2 * lhs - n)
            let r = abs(2 * rhs - n)
            return l < r || (l == r && lhs < rhs)
        }

        let substitutionPositions = (1..<(n - 1))
            .filter { spatial.spaceAdjacentLetters.contains(typedChars[$0]) }
            .sorted(by: centerOut)
            .prefix(config.splitMaxPositions)
        for j in substitutionPositions {
            hypotheses.append(
                (
                    Array(typedChars[0..<j]),
                    Array(typedChars[(j + 1)...]),
                    config.splitSubstitutionPenalty,
                    config.splitHalfRepairMaxCost
                )
            )
        }

        let insertionPositions = (1...(n - 1))
            .sorted(by: centerOut)
            .prefix(min(n - 2, config.splitMaxPositions))
        for i in insertionPositions {
            hypotheses.append(
                (
                    Array(typedChars[0..<i]),
                    Array(typedChars[i...]),
                    config.splitInsertionPenalty,
                    config.splitInsertionHalfRepairMaxCost
                )
            )
        }

        var best: [String: (spatialCost: Double, score: Double)] = [:]
        var halfCache: [String: [(word: String, cost: Double)]] = [:]
        func resolvedHalves(for half: [Character]) -> [(word: String, cost: Double)] {
            let key = String(half)
            if let cached = halfCache[key] { return cached }
            let fresh = halfHypotheses(half)
            halfCache[key] = fresh
            return fresh
        }

        let deadline = ContinuousClock.now + .seconds(config.splitTimeBudget)
        for hypothesis in hypotheses {
            if ContinuousClock.now >= deadline { break }
            let lefts = resolvedHalves(for: hypothesis.left)
            guard !lefts.isEmpty else { continue }
            let rights = resolvedHalves(for: hypothesis.right)
            guard !rights.isEmpty else { continue }
            for (leftWord, leftCost) in lefts where leftCost <= hypothesis.repairCap {
                for (rightWord, rightCost) in rights where rightCost <= hypothesis.repairCap {
                    let channel = hypothesis.penalty + leftCost + rightCost
                    let text = leftWord + " " + rightWord
                    if let existing = best[text], existing.spatialCost <= channel { continue }
                    let language = model.blendedPairScore(
                        first: leftWord,
                        second: rightWord,
                        previous: previousWord,
                        pIcelandic: pIcelandic
                    )
                    best[text] = (channel, -channel + config.languageWeight * language)
                }
            }
        }
        return best.map { (word: $0.key, spatialCost: $0.value.spatialCost, score: $0.value.score) }
    }

    /// Resolutions of one split half: the half itself when valid (cost 0)
    /// plus cheaply-repaired valid forms from the targeted passes —
    /// diacritic restoration, gemination, and (only when those find
    /// nothing) single edits with tight spatial cost. Never edits2. Capped
    /// at `splitHalfHypothesisLimit`, cheapest first.
    func halfHypotheses(_ chars: [Character]) -> [(word: String, cost: Double)] {
        var best: [String: Double] = [:]
        func admit(_ word: String, _ cost: Double) {
            guard cost <= config.splitHalfRepairMaxCost else { return }
            guard word.count > 1 || isGenuineSingleCharWord(word) else { return }
            guard !model.isPersonalTombstoned(word) else { return }
            if let existing = best[word], existing <= cost { return }
            best[word] = cost
        }

        let text = String(chars)
        if model.isKnownAnywhere(text) || model.isPersonalValid(text) { admit(text, 0) }
        for variant in Self.diacriticVariants(of: chars)
        where isCandidateWord(variant, checkMorphology: true) {
            admit(variant, spatialCost(typedChars: chars, candidate: variant))
        }
        for variant in Self.geminationVariants(of: chars)
        where isCandidateWord(variant, checkMorphology: true) {
            admit(variant, spatialCost(typedChars: chars, candidate: variant))
        }
        // edits1 is the expensive pass (hundreds of existence checks): only
        // walked when the cheap passes produced nothing, and never for
        // 1–2 char halves (every 1–2 letter word is one edit from another).
        if best.isEmpty, chars.count >= 3 {
            for (word, cost) in Self.edits1Costed(of: chars, spatial: spatial)
            where cost <= config.splitHalfRepairMaxCost
                && isCandidateWord(word, checkMorphology: true)
            {
                admit(word, cost)
            }
        }
        return best
            .sorted { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(config.splitHalfHypothesisLimit)
            .map { (word: $0.key, cost: $0.value) }
    }

    /// A single-character split half must be a GENUINE one-letter word —
    /// always an extreme-frequency function word in its language (IS á/í,
    /// EN a/i) — not corpus tokenization noise: "s" and "e" are attested in
    /// both lexicons but only at mid-tier typicality. Judged by calibrated
    /// z-score against `splitSingleCharHalfMinZ`.
    private func isGenuineSingleCharWord(_ word: String) -> Bool {
        let minZ = config.splitSingleCharHalfMinZ
        if model.icelandic.frequency(of: word) != nil,
            model.calibratedUnigramScore(of: word, language: .icelandic) >= minZ
        {
            return true
        }
        if model.english.frequency(of: word) != nil,
            model.calibratedUnigramScore(of: word, language: .english) >= minZ
        {
            return true
        }
        return false
    }

    // MARK: - Single-letter accent restoration

    /// The accent vowel pairs: bare letter → the long-press accented twin
    /// that is (potentially) a genuine one-letter Icelandic word. Only
    /// vowels — d→ð / t→þ never form one-letter words.
    static let singleLetterAccentPairs: [Character: Character] = [
        "a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý",
    ]

    /// Could a single-letter token get the accent-restoration suggestion at
    /// all? Cheap shape check for embedder gating (TypingSession's ≥2-char
    /// gate stays shut for every other single letter).
    public static func hasSingleLetterAccentEscape(_ token: String) -> Bool {
        guard token.count == 1, let letter = token.lowercased().first else { return false }
        return singleLetterAccentPairs[letter] != nil
    }

    /// Targeted single-letter path (dogfood "giskar a allt" → "giskar á"):
    /// offer the accented twin when it is a genuinely frequent Icelandic
    /// word, lane-gated. Auto-apply — the one sanctioned exception to both
    /// `minAutocorrectLength` and the valid-typed-word rule — only when the
    /// lane is confidently Icelandic AND the bare letter is not itself
    /// Icelandic vocabulary (is.lex-genuine, personal, or tombstoned; BÍN
    /// deliberately excluded, as everywhere junk-collides). In an English
    /// lane "a"/"i" are never touched and nothing is even offered.
    private func singleLetterCorrection(
        letter: Character,
        previousWord: String?,
        pIcelandic: Double,
        typedIsValid: Bool
    ) -> CorrectionResult {
        func empty() -> CorrectionResult {
            CorrectionResult(suggestions: [], typedWordIsValid: typedIsValid)
        }
        guard let accented = Self.singleLetterAccentPairs[letter] else { return empty() }
        let variant = String(accented)
        guard !model.isPersonalTombstoned(variant) else { return empty() }
        // The accented twin must be genuinely frequent Icelandic ("á" +3.3,
        // "í" +3.4 clear the bar; "é"/"ý" are corpus noise and never show).
        guard model.icelandic.frequency(of: variant) != nil,
            model.calibratedUnigramScore(of: variant, language: .icelandic)
                >= config.accentRestoreMinZ
        else { return empty() }
        // Lane offer gate: in a strongly English lane the variant is noise.
        guard pIcelandic >= config.accentOfferMinPosterior else { return empty() }

        let bare = String(letter)
        let bareIsIcelandicWord =
            model.isPersonalValid(bare)
            || model.isPersonalTombstoned(bare)
            || (model.icelandic.frequency(of: bare) != nil
                && model.calibratedUnigramScore(of: bare, language: .icelandic)
                    >= config.splitSingleCharHalfMinZ)
        let autocorrect =
            pIcelandic >= config.accentAutoApplyMinPosterior && !bareIsIcelandicWord

        // Confidence: two-way softmax between the accented reading and the
        // typed letter's own blended score.
        let sVariant = model.blendedScore(
            of: variant, previous: previousWord, pIcelandic: pIcelandic)
        let sBare = model.blendedScore(of: bare, previous: previousWord, pIcelandic: pIcelandic)
        let m = max(sVariant, sBare)
        let confidence = exp(sVariant - m) / (exp(sVariant - m) + exp(sBare - m))
        return CorrectionResult(
            suggestions: [
                Suggestion(text: variant, isAutocorrect: autocorrect, confidence: confidence)
            ],
            typedWordIsValid: typedIsValid
        )
    }

    // MARK: - Dotted-token space-miss escape

    /// Score/validate the "word word" reading of a dotted token whose SHAPE
    /// already passed TypingSession's checks (exactly one internal dot,
    /// all-letter halves, no known TLD, no www — see
    /// `TypingSession.spaceEscapeHalves`). Returns nil unless both halves
    /// are common attested words in one common language
    /// (`dottedEscapeMinHalfZ`). Auto-apply follows the strict split rules:
    /// the stricter half-typicality bar AND no attested/personal
    /// single-word repair of the merged letters within the generous bound.
    func dotSplitSuggestion(
        left: String,
        right: String,
        previousWord: String?,
        pIcelandic: Double
    ) -> Suggestion? {
        guard !model.isPersonalTombstoned(left), !model.isPersonalTombstoned(right) else {
            return nil
        }
        guard let commonness = pairCommonness(left: left, right: right),
            commonness >= config.dottedEscapeMinHalfZ
        else { return nil }

        let score =
            -config.dottedEscapePenalty
            + config.languageWeight
                * model.blendedPairScore(
                    first: left, second: right, previous: previousWord, pIcelandic: pIcelandic)
        let autocorrect =
            commonness >= config.dottedEscapeAutoApplyMinHalfZ
            && bestSingleWordRepairCost(of: left + right) > config.splitAutoApplySingleWordCutoff
        // Squashed score as a display confidence (there is no candidate
        // pool to softmax against — the alternative reading is the literal
        // verbatim token, which the bar always carries anyway).
        let confidence = 1 / (1 + exp(-score))
        return Suggestion(
            text: left + " " + right,
            isAutocorrect: autocorrect,
            confidence: min(max(confidence, 0), 1)
        )
    }

    /// max over language L of min(z_L(left), z_L(right)) — the pair's
    /// commonness in its best COMMON language; nil when no single language
    /// attests both halves (cross-language pairs never get the escape).
    /// One-letter halves must be genuine one-letter words in that language
    /// (`splitSingleCharHalfMinZ`).
    private func pairCommonness(left: String, right: String) -> Double? {
        func z(_ word: String, _ language: Language) -> Double? {
            guard model.lexicon(for: language).frequency(of: word) != nil else { return nil }
            let score = model.calibratedUnigramScore(of: word, language: language)
            if word.count == 1, score < config.splitSingleCharHalfMinZ { return nil }
            return score
        }
        var best: Double?
        for language in [Language.icelandic, .english] {
            if let l = z(left, language), let r = z(right, language) {
                best = max(best ?? -.infinity, min(l, r))
            }
        }
        return best
    }

    /// Cheapest ATTESTED-or-personal single-word repair of `typed` by the
    /// targeted passes (valid-as-is, edits1, diacritics, gemination — never
    /// edits2/completions): the item-2 "no plausible one-word fix" probe
    /// for split auto-apply. BÍN-only forms deliberately don't count.
    func bestSingleWordRepairCost(of typed: String) -> Double {
        if model.isValidTypedWord(typed) { return 0 }
        let chars = Array(typed)
        var best = Double.infinity
        func consider(_ word: String, _ cost: Double) {
            guard cost < best, isAttestedOrPersonal(word) else { return }
            best = cost
        }
        for (word, cost) in Self.edits1Costed(of: chars, spatial: spatial) {
            consider(word, cost)
        }
        for word in Self.diacriticVariants(of: chars) {
            consider(word, spatialCost(typedChars: chars, candidate: word))
        }
        for word in Self.geminationVariants(of: chars) {
            consider(word, spatialCost(typedChars: chars, candidate: word))
        }
        return best
    }

    // MARK: - Attestation helpers

    /// Attested in a frequency table, or valid personal vocabulary
    /// (tombstoned words excluded). BÍN validity deliberately does not
    /// count — its 3M forms collide with junk (same stance as laneEvidence).
    private func isAttestedOrPersonal(_ word: String) -> Bool {
        guard !model.isPersonalTombstoned(word) else { return false }
        return model.isPersonalValid(word)
            || model.icelandic.frequency(of: word) != nil
            || model.english.frequency(of: word) != nil
    }

    /// Best within-language calibrated typicality of an ATTESTED word; nil
    /// when the word is in neither frequency table (BÍN-only / unknown).
    private func attestedTypicality(of word: String) -> Double? {
        var best: Double?
        if model.icelandic.frequency(of: word) != nil {
            best = model.calibratedUnigramScore(of: word, language: .icelandic)
        }
        if model.english.frequency(of: word) != nil {
            best = max(
                best ?? -.infinity,
                model.calibratedUnigramScore(of: word, language: .english)
            )
        }
        return best
    }

    /// Cheapest attested-or-personal candidate cost in a generation pool
    /// (the gate currency for passes that BÍN-floored junk must not
    /// suppress — see step 4b).
    private func bestAttestedCost(in candidates: [String: Double]) -> Double {
        var best = Double.infinity
        for (word, cost) in candidates where cost < best && isAttestedOrPersonal(word) {
            best = cost
        }
        return best
    }

    // MARK: - Internals

    /// Apostrophe conservatism (harness quirk: "don't"→"dont", "I'm"→"Ibm"):
    /// an auto-replacement may never drop apostrophes the user typed. The
    /// candidate must contain at least as many apostrophes as the typed
    /// word (bar suggestions are unaffected — only auto-apply is blocked).
    /// Holds regardless of whether the lexicon knows the contraction.
    static func preservesApostrophes(of typed: String, in candidate: String) -> Bool {
        let typedCount = typed.filter { apostrophes.contains($0) }.count
        guard typedCount > 0 else { return true }
        return candidate.filter { apostrophes.contains($0) }.count >= typedCount
    }

    /// A token containing hyphens whose parts are each valid (lexicon or
    /// BÍN) is treated as a valid compound. A trailing hyphen (word in
    /// progress: "vel-") only needs the completed parts to be valid.
    private func isValidHyphenatedCompound(_ word: String) -> Bool {
        guard word.contains("-") else { return false }
        let parts = word.split(separator: "-")
        guard !parts.isEmpty else { return false }
        // Typed-word protection semantics (personal words count, and so do
        // tombstoned ones — see isValidTypedWord).
        return parts.allSatisfy { model.isValidTypedWord(String($0)) }
    }

    private func isCandidateWord(_ word: String, checkMorphology: Bool) -> Bool {
        guard !model.isPersonalTombstoned(word) else { return false }
        if model.isPersonalValid(word) { return true }
        if model.icelandic.frequency(of: word) != nil { return true }
        if model.english.frequency(of: word) != nil { return true }
        if checkMorphology, model.morphology?.isKnown(word) == true { return true }
        return false
    }

    /// Spatial cost of a candidate; strict-prefix completions are charged
    /// per not-yet-typed character instead of per "insertion error".
    func spatialCost(typedChars: [Character], candidate: String) -> Double {
        let candidateChars = Array(candidate)
        var cost = spatial.typingCost(typed: typedChars, intended: candidateChars)
        if candidateChars.count > typedChars.count, candidateChars.starts(with: typedChars) {
            let extra = Double(candidateChars.count - typedChars.count)
            cost = min(cost, extra * config.completionCharCost)
        }
        return cost
    }

    /// Diacritic/orthographic restoration map: plain character → characters
    /// commonly intended instead on the Icelandic layout (accents live
    /// behind long-press, so users often type the base letter; d/ð and t/þ
    /// are the classic orthographic slips).
    static let restorationVariants: [Character: [Character]] = [
        "a": ["á"], "e": ["é"], "i": ["í"], "o": ["ó", "ö"], "u": ["ú"],
        "y": ["ý"], "d": ["ð"], "t": ["þ"],
    ]

    /// All words reachable from `chars` by replacing up to `maxChanges`
    /// characters with their restoration variants (see above). Bounded and
    /// tiny: a 10-letter all-vowel word yields < 200 variants.
    static func diacriticVariants(of chars: [Character], maxChanges: Int = 3) -> [String] {
        var results: [String] = []
        var current = chars

        func recurse(from index: Int, changesLeft: Int) {
            guard changesLeft > 0 else { return }
            for i in index..<current.count {
                guard let variants = Self.restorationVariants[current[i]] else { continue }
                let original = current[i]
                for variant in variants {
                    current[i] = variant
                    results.append(String(current))
                    recurse(from: i + 1, changesLeft: changesLeft - 1)
                }
                current[i] = original
            }
        }
        recurse(from: 0, changesLeft: maxChanges)
        return results
    }

    /// Bases reachable by removing one letter of a doubled pair ("nogg" →
    /// "nog"). Shared by the gemination pass and the gemination+accent
    /// composition pass (2c).
    static func dedoubledVariants(of chars: [Character]) -> [[Character]] {
        let n = chars.count
        guard n >= 2 else { return [] }
        var dedoubled: [[Character]] = []
        for i in 0..<(n - 1) where chars[i] == chars[i + 1] {
            var copy = chars
            copy.remove(at: i)
            dedoubled.append(copy)
        }
        return dedoubled
    }

    /// Gemination-error variants: remove one letter of a doubled pair,
    /// double an existing letter, or both (in that order — covering
    /// "tommorow"→"tomorrow" in one targeted pass).
    static func geminationVariants(of chars: [Character]) -> [String] {
        let n = chars.count
        guard n >= 2 else { return [] }
        let dedoubled = Self.dedoubledVariants(of: chars)
        var results: [String] = dedoubled.map { String($0) }
        func doubling(_ base: [Character], into results: inout [String]) {
            for i in 0..<base.count where i == 0 || base[i] != base[i - 1] {
                var copy = base
                copy.insert(base[i], at: i)
                results.append(String(copy))
            }
        }
        doubling(chars, into: &results)
        for base in dedoubled {
            doubling(base, into: &results)
        }
        return results
    }

    /// All strings at Damerau-Levenshtein distance 1 from `chars`, each with
    /// the spatial cost of the single edit that produced it (minimum across
    /// generation paths). O(1) cost per string — used to priority-order the
    /// budgeted edits2 walk without recomputing edit-distance matrices.
    static func edits1Costed(
        of chars: [Character], spatial: SpatialModel
    ) -> [String: Double] {
        var out: [String: Double] = [:]
        out.reserveCapacity(chars.count * 2 * (alphabet.count + 1))

        func admit(_ word: [Character], _ cost: Double) {
            let key = String(word)
            if let existing = out[key], existing <= cost { return }
            out[key] = cost
        }

        let n = chars.count
        let costs = spatial.costs
        // deletions (the user typed an extra, unintended character)
        for i in 0..<n {
            var copy = chars
            copy.remove(at: i)
            admit(copy, costs.insertion)
        }
        // transpositions
        if n >= 2 {
            for i in 0..<(n - 1) where chars[i] != chars[i + 1] {
                var copy = chars
                copy.swapAt(i, i + 1)
                admit(copy, costs.transposition)
            }
        }
        // substitutions
        for i in 0..<n {
            for ch in alphabet where ch != chars[i] {
                var copy = chars
                copy[i] = ch
                admit(copy, spatial.substitutionCost(typed: chars[i], intended: ch))
            }
        }
        // insertions (the user omitted a character they intended)
        for i in 0...n {
            for ch in alphabet {
                var copy = chars
                copy.insert(ch, at: i)
                admit(copy, costs.deletion)
            }
        }
        return out
    }

    /// All strings at Damerau-Levenshtein distance 1 from `chars`.
    static func edits1(of chars: [Character]) -> Set<String> {
        var out = Set<String>()
        let n = chars.count
        // deletions
        for i in 0..<n {
            var copy = chars
            copy.remove(at: i)
            out.insert(String(copy))
        }
        // transpositions
        if n >= 2 {
            for i in 0..<(n - 1) where chars[i] != chars[i + 1] {
                var copy = chars
                copy.swapAt(i, i + 1)
                out.insert(String(copy))
            }
        }
        // substitutions
        for i in 0..<n {
            for ch in alphabet where ch != chars[i] {
                var copy = chars
                copy[i] = ch
                out.insert(String(copy))
            }
        }
        // insertions
        for i in 0...n {
            for ch in alphabet {
                var copy = chars
                copy.insert(ch, at: i)
                out.insert(String(copy))
            }
        }
        return out
    }
}
