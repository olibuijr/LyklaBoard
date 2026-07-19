package `is`.solberg.lyklabord.engine.config

/** Read-only subsystem snapshots over the flat EngineConfig. */
class EngineConfigDomains(config: EngineConfig) {
    val search = SearchConfiguration(config)
    val ranking = RankingConfiguration(config)
    val action = ActionPolicyConfiguration(config)
    val touch = TouchConfiguration(config)
    val lane = LaneConfiguration(config)
    val morphology = MorphologyConfiguration(config)
}

/** Candidate discovery and bounded-search budgets. */
class SearchConfiguration(config: EngineConfig) {
    val disabledCandidateProviders = config.disabledCandidateProviders
    val completionPoolLimit = config.completionPoolLimit
    val contextContinuationPoolLimit = config.contextContinuationPoolLimit
    val contextContinuationMaxCost = config.contextContinuationMaxCost
    val beamCostCap = config.beamCostCap
    val beamMultiEditCostCap = config.beamMultiEditCostCap
    val beamMaxEdits = config.beamMaxEdits
    val beamMaxExpansions = config.beamMaxExpansions
    val beamMaxCandidates = config.beamMaxCandidates
    val beamTimeBudget = config.beamTimeBudget
    val splitTimeBudget = config.splitTimeBudget
    val compoundRepairMaxLookups = config.compoundRepairMaxLookups
}

/** Additive score composition after candidates have been admitted. */
class RankingConfiguration(config: EngineConfig) {
    val languageWeight = config.languageWeight
    val calibrationTemperature = config.calibrationTemperature
    val bigramInterpolation = config.bigramInterpolation
    val compoundCompletionHeadZWeight = config.compoundCompletionHeadZWeight
    val morphBackoffWeight = config.morphBackoffWeight
    val personalBoostBase = config.personalBoostBase
    val personalBoostScale = config.personalBoostScale
    val personalBoostCap = config.personalBoostCap
}

/** Every flat knob read directly by the post-ranking autocorrect decision. */
class ActionPolicyConfiguration(config: EngineConfig) {
    val minAutocorrectLength = config.minAutocorrectLength
    val autocorrectMaxSpatialCost = config.autocorrectMaxSpatialCost
    val autocorrectMargin = config.autocorrectMargin
    val autocorrectMinZ = config.autocorrectMinZ
    val autocorrectJunkWinnerZ = config.autocorrectJunkWinnerZ
    val autocorrectJunkWinnerMarginScale = config.autocorrectJunkWinnerMarginScale
    val autocorrectFarRepairEdits = config.autocorrectFarRepairEdits
    val autocorrectFarRepairMinZ = config.autocorrectFarRepairMinZ
    val autocorrectShortLengthMax = config.autocorrectShortLengthMax
    val autocorrectShortMinZ = config.autocorrectShortMinZ
    val autocorrectContextLengthMax = config.autocorrectContextLengthMax
    val autocorrectContextShortMinZ = config.autocorrectContextShortMinZ
    val autocorrectContextLiftFloor = config.autocorrectContextLiftFloor
    val archaicTwinRestorationEnabled = config.archaicTwinRestorationEnabled
    val archaicTwinShortMinZ = config.archaicTwinShortMinZ
    val vacuumAutoApplyEnabled = config.vacuumAutoApplyEnabled
    val vacuumAutoApplyMargin = config.vacuumAutoApplyMargin
    val properNounGuardEnabled = config.properNounGuardEnabled
    val closeCandidateGate = config.closeCandidateGate
    val compoundLinkingRepairYieldEnabled = config.compoundLinkingRepairYieldEnabled
    val splitAutocorrectMargin = config.splitAutocorrectMargin
    val splitAutoApplySingleWordCutoff = config.splitAutoApplySingleWordCutoff
    val restorationAutoApplyMargin = config.restorationAutoApplyMargin
    val bigramMarginRelief = config.bigramMarginRelief
    val bigramMarginReliefMinLift = config.bigramMarginReliefMinLift
    val beamMultiEditCostCap = config.beamMultiEditCostCap
}

/** Coordinate likelihood, confidence veto, and personalization controls. */
class TouchConfiguration(config: EngineConfig) {
    val sigmaX = config.tapSigmaX
    val sigmaY = config.tapSigmaY
    val vetoBaseline = config.tapVetoBaseline
    val vetoStrength = config.tapVetoStrength
    val vetoMaxFactor = config.tapVetoMaxFactor
    val nearMissMinLean = config.tapNearMissMinLean
    val nearMissCapEnabled = config.tapNearMissCapEnabled
    val edgeUndershootEnabled = config.edgeUndershootEnabled
    val personalMinSamples = config.touchPersonalMinSamples
    val priorStrength = config.touchPriorStrength
    val sigmaFloor = config.touchSigmaFloor
}

/** Bilingual posterior and restoration-profile controls. */
class LaneConfiguration(config: EngineConfig) {
    val switchProbability = config.laneSwitchProbability
    val boundaryDecay = config.laneBoundaryDecay
    val emissionTemperature = config.laneEmissionTemperature
    val emissionMaxLogRatio = config.laneEmissionMaxLogRatio
    val posteriorFloor = config.posteriorFloor
    val posteriorCeiling = config.posteriorCeiling
    val evidenceFloor = config.laneEvidenceFloor
    val evidenceDeadZone = config.laneEvidenceDeadZone
    val foldBaseCost = config.foldBaseCost
    val foldProfileISEnabled = config.foldProfileISEnabled
    val foldProfileENEnabled = config.foldProfileENEnabled
}

/** Inflection backoff, case completion, and lemma-level learning controls. */
class MorphologyConfiguration(config: EngineConfig) {
    val backoffWeight = config.morphBackoffWeight
    val minGovernorMass = config.morphMinGovernorMass
    val minPosterior = config.morphBackoffMinPosterior
    val caseFitFloor = config.morphCaseFitFloor
    val wrongFormMinAdvantage = config.morphWrongFormMinAdvantage
    val completionPoolLimit = config.morphCompletionPoolLimit
    val caseCompletionEnabled = config.caseCompletionEnabled
    val caseCompletionMaxTrim = config.caseCompletionMaxTrim
    val caseCompletionMinLength = config.caseCompletionMinLength
    val caseSplitSecondMinProbability = config.caseSplitSecondMinProbability
    val lemmaLiftBoost = config.lemmaLiftBoost
}

/** Snapshot the current grouped values. */
val EngineConfig.domains: EngineConfigDomains
    get() = EngineConfigDomains(this)
