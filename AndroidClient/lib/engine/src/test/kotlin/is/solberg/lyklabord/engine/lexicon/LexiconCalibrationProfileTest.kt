package `is`.solberg.lyklabord.engine.lexicon

import `is`.solberg.lyklabord.engine.testsupport.RepoData
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.booleans.shouldBeTrue
import io.kotest.matchers.doubles.shouldBeGreaterThan
import io.kotest.matchers.ints.shouldBeGreaterThan
import io.kotest.matchers.shouldBe

class LexiconCalibrationProfileTest : FunSpec({
    for ((language, path) in listOf(
        "Icelandic" to "data/is/is-calibration.json",
        "English" to "data/en/en-calibration.json",
    )) {
        test("decodes $language calibration artifact") {
            val profile = LexiconCalibrationProfile.decode(RepoData.file(path).readText())

            profile.schema shouldBe LexiconCalibrationProfile.schema
            profile.schema shouldBe "lyklabord.lexicon-calibration.v1"
            profile.languageDataGeneration.isNotEmpty().shouldBeTrue()
            profile.addK.shouldBeGreaterThan(0.0)
            profile.meanLogFrequency.shouldBeGreaterThan(0.0)
            profile.stdLogFrequency.shouldBeGreaterThan(0.25)
            profile.warmupWords.size.shouldBeGreaterThan(0)
            profile.isValid.shouldBeTrue()
        }
    }
})
