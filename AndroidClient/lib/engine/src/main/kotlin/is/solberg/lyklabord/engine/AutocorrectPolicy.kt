package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfigDomains
import kotlin.math.max

/** Everything the action/safety layer may inspect after ranking is complete. */
data class AutocorrectPolicyInput(
    val typed: String,
    val typedChars: List<Char>,
    val deliberate: List<Char>,
    val previousWord: String?,
    val contextPrev: String?,
    val pIcelandic: Double,
    val capitalizedMidSentence: Boolean,
    val typedIsValid: Boolean,
    val typedIsProtected: Boolean,
    val typedCompoundSplit: CompoundSplit?,
    val perTap: PerTapCostProvider?,
    val pricing: FoldPricing,
    val candidates: CandidateAdmissionPool,
    val speculativeCompletions: Set<String>,
    val mashRecoveryAdmissions: Set<String>,
    val scored: List<RankedCandidate>,
)

/** Post-ranking action decision. Candidate generation and ranking are immutable here. */
fun Corrector.decideAutocorrect(
    input: AutocorrectPolicyInput,
    trace: CorrectionTrace?,
): Boolean {
    val action = EngineConfigDomains(config).action
    val typed = input.typed
    val typedChars = input.typedChars
    val deliberate = input.deliberate
    val previousWord = input.previousWord
    val contextPrev = input.contextPrev
    val pIcelandic = input.pIcelandic
    val capitalizedMidSentence = input.capitalizedMidSentence
    val typedIsValid = input.typedIsValid
    val typedIsProtected = input.typedIsProtected
    val typedCompoundSplit = input.typedCompoundSplit
    val perTap = input.perTap
    val pricing = input.pricing
    val candidates = input.candidates
    val speculativeCompletions = input.speculativeCompletions
    val mashRecoveryAdmissions = input.mashRecoveryAdmissions
    val scored = input.scored

    var autocorrect = false
    val best = scored.firstOrNull() ?: return false
    val lengthOK = typedChars.size >= action.minAutocorrectLength
    val costOK = best.cost.total <= action.autocorrectMaxSpatialCost
    val apostrophesOK = Corrector.preservesApostrophes(typed, best.word)
    val quotationsOK = Corrector.preservesQuotationMarks(typed, best.word)
    val deliberateOK = Corrector.preservesDeliberateCharacters(deliberate, typedChars, best.word)
    val preconditionsOK = lengthOK && costOK && apostrophesOK && quotationsOK && deliberateOK
    val linkingYield = action.compoundLinkingRepairYieldEnabled && !typedIsValid &&
        !best.word.contains(" ") && typedCompoundSplit?.let {
            model.icelandic.frequency(best.word) != null &&
                Corrector.isLinkingLetterRepair(typedChars, best.word, it)
        } == true
    val effectiveProtected = typedIsProtected && !linkingYield
    if (linkingYield) {
        trace?.note("compound protection YIELDS: winner \"${best.word}\" is an attested linking-letter repair at the decomposition boundary")
    }
    val margin = if (scored.size > 1) best.score - scored[1].score else Double.POSITIVE_INFINITY
    val tapMarginFactor = tapVetoFactor(
        typedChars,
        best.word,
        perTap,
        best.cost.isRestorationOnly,
        if (model.isPersonalValid(best.word)) Double.POSITIVE_INFINITY else attestedTypicality(best.word) ?: Double.NEGATIVE_INFINITY,
    )
    trace?.apply {
        this.margin = margin
        this.tapVetoFactor = tapMarginFactor
        this.rule = if (!effectiveProtected && best.word.contains(" ")) "split"
        else if (!effectiveProtected) "ordinary-unknown"
        else if (best.cost.isRestorationOnly && !best.word.contains(" ") && deliberate.isEmpty()) "skeleton-restoration"
        else "valid-word (no auto-apply path)"
        if (!lengthOK) gate("minAutocorrectLength", "typed length ${typedChars.size} < ${action.minAutocorrectLength}", false)
        if (!costOK) gate("autocorrectMaxSpatialCost", "best cost ${fmt(best.cost.total, "%.3f")} > ${action.autocorrectMaxSpatialCost}", false)
        if (!apostrophesOK) gate("preservesApostrophes", "candidate drops a typed apostrophe", false)
        if (!quotationsOK) gate("preservesQuotationMarks", "candidate drops a typed quotation mark", false)
        if (!deliberateOK) gate("preservesDeliberateCharacters", "candidate drops a long-pressed character", false)
    }

    if (preconditionsOK && !effectiveProtected && best.word.contains(" ")) {
        val bestSingleCost = scored.asSequence()
            .filter { !it.word.contains(" ") && isAttestedOrPersonal(it.word) }
            .map { it.cost.total }.minOrNull() ?: Double.POSITIVE_INFINITY
        val marginOK = margin >= action.splitAutocorrectMargin * tapMarginFactor
        val noSingleRepair = bestSingleCost > action.splitAutoApplySingleWordCutoff
        trace?.apply {
            requiredMargin = action.splitAutocorrectMargin
            gate("splitMargin", "margin ${fmt(margin, "%.3f")} >= ${action.splitAutocorrectMargin} x ${fmt(tapMarginFactor, "%.2f")}", marginOK)
            gate("noSingleWordRepair", "best attested single-word cost ${fmt(bestSingleCost, "%.3f")} > cutoff ${action.splitAutoApplySingleWordCutoff}", noSingleRepair)
        }
        return marginOK && noSingleRepair
    }

    if (preconditionsOK && !effectiveProtected) {
        val typicality = if (model.isPersonalValid(best.word)) Double.POSITIVE_INFINITY else attestedTypicality(best.word) ?: Double.NEGATIVE_INFINITY
        val rewrite = Corrector.rewriteDistance(typedChars, best.word.toList())
        val farRepair = rewrite >= action.autocorrectFarRepairEdits
        val short = typedChars.size <= action.autocorrectShortLengthMax
        val archaicTwinWinner = action.archaicTwinRestorationEnabled && short &&
            best.cost.isRestorationOnly && model.acuteFoldShadowTwin(typed) == best.word
        var minZ = if (farRepair) max(action.autocorrectMinZ, action.autocorrectFarRepairMinZ) else action.autocorrectMinZ
        if (short) minZ = max(minZ, if (archaicTwinWinner) action.archaicTwinShortMinZ else action.autocorrectShortMinZ)
        val marginLane = if (pIcelandic >= 0.5) Language.icelandic else Language.english
        val winnerLift = model.contextualLift(best.word, contextPrev, marginLane)
        val runnerUpLift = scored.getOrNull(1)?.let { model.contextualLift(it.word, contextPrev, marginLane) }
        val contextShort = !short && typedChars.size <= action.autocorrectContextLengthMax &&
            !best.cost.isRestorationOnly && contextPrev != null
        val contextShortUnvouched = contextShort && (winnerLift ?: Double.NEGATIVE_INFINITY) < action.autocorrectContextLiftFloor
        if (contextShortUnvouched) minZ = max(minZ, action.autocorrectContextShortMinZ)
        val shortCompletion = short && best.word.length > typedChars.size && best.word.startsWith(typed)
        val profileWeight = restorationProfileWeight(typed, best.word, pricing)
        val restorationRelaxed = best.cost.isRestorationOnly && profileWeight > 0.0
        var requiredMargin = if (restorationRelaxed) action.restorationAutoApplyMargin else action.autocorrectMargin
        val junkWinner = !restorationRelaxed && typicality < action.autocorrectJunkWinnerZ
        if (junkWinner) requiredMargin *= action.autocorrectJunkWinnerMarginScale
        val bigramRelief = !junkWinner && (winnerLift ?: Double.NEGATIVE_INFINITY) >= action.bigramMarginReliefMinLift &&
            (runnerUpLift ?: Double.NEGATIVE_INFINITY) <= 0.0
        if (bigramRelief) requiredMargin *= action.bigramMarginRelief
        var marginOK = margin >= requiredMargin * tapMarginFactor
        var typicalityOK = typicality >= minZ
        var vacuum = false
        if (action.vacuumAutoApplyEnabled && !typicalityOK && !farRepair && !short &&
            model.morphology?.isKnown(best.word) == true &&
            bestAttestedCost(candidates.costs, speculativeCompletions) > action.closeCandidateGate
        ) {
            vacuum = true
            typicalityOK = true
            marginOK = margin >= maxOf(requiredMargin, action.vacuumAutoApplyMargin) * tapMarginFactor
        }
        val properNounOK = if (action.properNounGuardEnabled && capitalizedMidSentence &&
            !best.cost.isRestorationOnly && typedChars.size >= 4 && typedChars.lastOrNull() == 's' && typedChars.all { it.isLetter() }
        ) {
            val stem = typedChars.dropLast(1).joinToString("")
            model.english.frequency(stem) != null || model.icelandic.frequency(stem) == null
        } else true
        if (trace != null) {
            if (action.properNounGuardEnabled && capitalizedMidSentence && !properNounOK) {
                trace.gate("proper-noun-possessive-guard", "capitalized mid-sentence Name+s with unattested stem; error-class auto-apply suppressed", false)
            }
            trace.requiredMargin = if (vacuum) maxOf(requiredMargin, action.vacuumAutoApplyMargin) else requiredMargin
            trace.note(if (restorationRelaxed) "restoration-only winner, lane ramp open (weight ${fmt(profileWeight, "%.2f")}) -> relaxed margin" else if (best.cost.isRestorationOnly) "restoration-only winner but lane ramp CLOSED -> ordinary margin" else "error-class winner (rewriteDistance $rewrite${if (farRepair) ", FAR repair" else ""})")
            if (vacuum) trace.note("VACUUM: BÍN-valid winner below the typicality floor, no attested repair within closeCandidateGate -> stricter margin, floor waived")
            if (junkWinner) trace.note("junk-tier winner (z ${fmt(typicality, "%+.3f")} < ${fmt(action.autocorrectJunkWinnerZ, "%+.2f")}) -> margin x${fmt(action.autocorrectJunkWinnerMarginScale, "%.1f")}")
            if (bigramRelief) trace.note("bigram-dominance relief: winner lift ${fmt(winnerLift ?: 0.0, "%+.2f")} vs runner-up ${runnerUpLift?.let { fmt(it, "%+.2f") } ?: "none"} -> margin x${fmt(action.bigramMarginRelief, "%.2f")}")
            if (contextShortUnvouched) trace.note("context-short token (len ${typedChars.size}) without bigram vouch (winner lift ${winnerLift?.let { fmt(it, "%+.2f") } ?: "none"}) -> minZ raised to ${fmt(action.autocorrectContextShortMinZ, "%+.2f")}")
            trace.gate("margin", "margin ${fmt(margin, "%.3f")} >= ${fmt(if (vacuum) maxOf(requiredMargin, action.vacuumAutoApplyMargin) else requiredMargin, "%.3f")} x ${fmt(tapMarginFactor, "%.2f")}${if (vacuum) " (vacuum margin)" else ""}", marginOK)
            trace.gate("typicality", "winner z ${if (typicality == Double.POSITIVE_INFINITY) "personal" else fmt(typicality, "%+.3f")} >= minZ ${fmt(minZ, "%+.3f")}${if (farRepair) " (far-repair floor)" else ""}${if (short) if (archaicTwinWinner) " (archaic-twin floor)" else " (short-token floor)" else ""}", typicalityOK)
        }
        if (shortCompletion) trace?.gate("short-completion", "short token; winner \"${best.word}\" is a strict-prefix completion — never auto-expanded", false)
        val mashOfferOnly = mashRecoveryAdmissions.contains(best.word) && best.cost.total > action.beamMultiEditCostCap
        if (mashOfferOnly) trace?.gate("mash-recovery-offer-only", "winner admitted only by the widened mash-recovery cone at cost ${fmt(best.cost.total, "%.3f")} > beamMultiEditCostCap ${action.beamMultiEditCostCap} — offer, never auto-apply", false)
        autocorrect = marginOK && typicalityOK && properNounOK && !shortCompletion && !mashOfferOnly
    } else if (preconditionsOK && best.cost.isRestorationOnly && !best.word.contains(" ") && deliberate.isEmpty()) {
        val marginOK = margin >= action.restorationAutoApplyMargin * tapMarginFactor
        trace?.apply {
            requiredMargin = action.restorationAutoApplyMargin
            gate("margin", "margin ${fmt(margin, "%.3f")} >= ${action.restorationAutoApplyMargin} x ${fmt(tapMarginFactor, "%.2f")}", marginOK)
        }
        val tripleOK = passesRestorationTripleGate(typed, best.word, previousWord, pIcelandic, trace)
        autocorrect = marginOK && tripleOK
    }
    return autocorrect
}

private fun fmt(value: Double, pattern: String): String = pattern.format(value)
