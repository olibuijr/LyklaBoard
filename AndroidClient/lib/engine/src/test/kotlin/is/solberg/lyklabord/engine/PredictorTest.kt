package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.lexicon.FrequencyLexicon
import `is`.solberg.lyklabord.engine.lexicon.LexiconCalibrationProfile
import `is`.solberg.lyklabord.engine.morph.BinaryLemmatizer
import `is`.solberg.lyklabord.engine.testsupport.RepoData
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.booleans.shouldBeTrue

/**
 * Exercises the Phase-1 completion/prediction path against the real shipped
 * Icelandic + English lexicons, morphology, and calibration profiles.
 */
class PredictorTest : FunSpec({

    val icelandic = FrequencyLexicon(RepoData.mapLE("data/is/is.lex"))
    val english = FrequencyLexicon(RepoData.mapLE("data/en/en.lex"))
    val morphology = BinaryLemmatizer(RepoData.mapLE("data/is/bin-morph.core.bin"))
    val isCal = LexiconCalibrationProfile.fromJson(RepoData.file("data/is/is-calibration.json").readText())
    val enCal = LexiconCalibrationProfile.fromJson(RepoData.file("data/en/en-calibration.json").readText())

    val predictor = Predictor(
        icelandic = icelandic,
        english = english,
        morphology = morphology,
        icelandicCalibrationProfile = isCal,
        englishCalibrationProfile = enCal,
    )

    test("mid-word completions of an Icelandic prefix are real ranked words") {
        val comps = predictor.completions(of = "hes", previousWord = null, pIcelandic = 0.8, limit = 25)
        comps.isNotEmpty().shouldBeTrue()
        comps.all { it.text.startsWith("hes") }.shouldBeTrue()
        // The citation form is surfaced among the ranked completions.
        comps.any { it.text == "hestur" }.shouldBeTrue()
        // Predictions never auto-replace; confidences are a normalized distribution.
        comps.all { !it.isAutocorrect }.shouldBeTrue()
        comps.all { it.confidence in 0.0..1.0 }.shouldBeTrue()
        // Sorted by descending confidence.
        for (i in 1 until comps.size) (comps[i - 1].confidence >= comps[i].confidence).shouldBeTrue()
    }

    test("next-word predictions after a common word are non-empty") {
        val preds = predictor.nextWords(previousWord = "ég", pIcelandic = 0.8, limit = 5)
        preds.isNotEmpty().shouldBeTrue()
        preds.all { !it.isAutocorrect }.shouldBeTrue()
    }

    test("cold start with no context yields no unigram fallback (faithful to Swift)") {
        // Swift completions(of: "") returns [] for an empty key, so the top-unigram
        // fallback in nextWords is inert at a true sentence start with no prefix —
        // predictions require either a previous word or a current prefix.
        val preds = predictor.nextWords(previousWord = null, pIcelandic = 0.8, limit = 5)
        preds.isEmpty().shouldBeTrue()
    }
})
