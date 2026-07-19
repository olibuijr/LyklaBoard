package `is`.solberg.lyklabord.engine.testsupport

import `is`.solberg.lyklabord.engine.GovernorsModel
import `is`.solberg.lyklabord.engine.InflectionModel
import `is`.solberg.lyklabord.engine.TypeEngine
import `is`.solberg.lyklabord.engine.config.EngineConfig
import `is`.solberg.lyklabord.engine.lexicon.FrequencyLexicon
import `is`.solberg.lyklabord.engine.lexicon.LexiconCalibrationProfile
import `is`.solberg.lyklabord.engine.morph.BinaryLemmatizer
import `is`.solberg.lyklabord.engine.morph.ParadigmsReader

/**
 * Build the full bilingual engine from the reference `data/` tree (host-JVM,
 * no device), mirroring CoreScenariosTest. Shared by the end-to-end typing
 * tests so each ported upstream test suite reuses one fixture.
 */
fun buildEngine(): TypeEngine {
    val config = EngineConfig().apply {
        beamTimeBudget = 3600.0
        splitTimeBudget = 3600.0
    }
    val engine = TypeEngine(
        icelandic = FrequencyLexicon(RepoData.mapLE("data/is/is.lex")),
        english = FrequencyLexicon(RepoData.mapLE("data/en/en.lex")),
        morphologyProvider = BinaryLemmatizer(RepoData.mapLE("data/is/bin-morph.core.bin")),
        config = config,
        icelandicCalibration = LexiconCalibrationProfile.fromJson(
            RepoData.file("data/is/is-calibration.json").readText(),
        ),
        englishCalibration = LexiconCalibrationProfile.fromJson(
            RepoData.file("data/en/en-calibration.json").readText(),
        ),
    )
    val paradigms = RepoData.file("data/is/paradigms.bin")
    val governors = RepoData.file("data/is/governors.json.gz")
    if (paradigms.isFile && governors.isFile) {
        engine.setInflection(
            InflectionModel(
                paradigms = ParadigmsReader(RepoData.mapLE("data/is/paradigms.bin")),
                governors = governors.inputStream().use { GovernorsModel(it) },
            ),
        )
    }
    return engine
}
