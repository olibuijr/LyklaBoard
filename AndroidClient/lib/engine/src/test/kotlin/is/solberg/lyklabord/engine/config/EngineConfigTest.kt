package `is`.solberg.lyklabord.engine.config

import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe

class EngineConfigTest : FunSpec({
    test("matches Swift defaults across engine subsystems") {
        val config = EngineConfig()

        config.addK shouldBe 0.5
        config.assumedVocabularySize shouldBe 100_000.0
        config.calibrationTemperature shouldBe 1.0
        config.completionPoolLimit shouldBe 8
        config.continuationPoolLimit shouldBe 24
        config.personalContinuationPoolLimit shouldBe 8
        config.unigramPoolLimit shouldBe 50
        config.personalCompletionPoolLimit shouldBe 8
        config.beamCostCap shouldBe 8.0
        config.beamMultiEditCostCap shouldBe 5.0
        config.beamMaxEdits shouldBe 3
        config.beamMaxExpansions shouldBe 6000
        config.beamTimeBudget shouldBe 0.006
        config.autocorrectMargin shouldBe 1.15
        config.autocorrectMinZ shouldBe -2.5
        config.vacuumAutoApplyEnabled shouldBe false
        config.compoundValidityEnabled shouldBe true
        config.foldProfileISEnabled shouldBe true
    }

    test("domain snapshots mirror their flat fields") {
        val config = EngineConfig()
        val domains = config.domains

        domains.search.beamMaxEdits shouldBe config.beamMaxEdits
        domains.search.completionPoolLimit shouldBe config.completionPoolLimit
        domains.ranking.calibrationTemperature shouldBe config.calibrationTemperature
        domains.action.autocorrectMargin shouldBe config.autocorrectMargin
        domains.touch.sigmaX shouldBe config.tapSigmaX
        domains.lane.switchProbability shouldBe config.laneSwitchProbability
        domains.morphology.completionPoolLimit shouldBe config.morphCompletionPoolLimit
    }
})
