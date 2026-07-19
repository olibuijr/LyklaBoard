package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfig
import `is`.solberg.lyklabord.engine.lexicon.FrequencyLexicon
import `is`.solberg.lyklabord.engine.lexicon.LexiconCalibrationProfile
import `is`.solberg.lyklabord.engine.morph.BinaryLemmatizer
import `is`.solberg.lyklabord.engine.morph.ParadigmsReader
import `is`.solberg.lyklabord.engine.testsupport.RepoData
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe

/**
 * Port of the upstream (iOS) engine fixes adopted from jokull/LyklabordApp:
 * Wave A dogfood fixes (issues #6 prefix-eating, #8 numeric guard, #9 patronymic
 * casing) and quoted-term relaxation (#3). These verify the fixes ported into the
 * Kotlin [TypingSession].
 */
class WaveADogfoodTest : FunSpec({

    // MARK: - Issue #6: corrections must not eat non-word prefixes

    test("leading-symbol tokens are verbatim-class (never corrected)") {
        TypingSession.isVerbatimClassToken("/goal") shouldBe true
        TypingSession.isVerbatimClassToken("#tag") shouldBe true
        TypingSession.isVerbatimClassToken("~heim") shouldBe true
        TypingSession.isVerbatimClassToken("-flag") shouldBe true
        // Ordinary words and numbers are untouched.
        TypingSession.isVerbatimClassToken("goal") shouldBe false
        TypingSession.isVerbatimClassToken("hestur") shouldBe false
        TypingSession.isVerbatimClassToken("21") shouldBe false
    }

    test("trailing segment splits after any non-word character") {
        TypingSession.trailingSegment("/goal") shouldBe "goal"
        TypingSession.trailingSegment("#tag") shouldBe "tag"
        TypingSession.trailingSegment("profilmynd.tilvinstri") shouldBe "tilvinstri"
        TypingSession.trailingSegment("jokull@solberg") shouldBe "solberg"
        TypingSession.trailingSegment("hestur") shouldBe "hestur"
    }

    test("double quotes are word delimiters, apostrophes are word-internal") {
        TypingSession.splitCurrentWord("„orð").currentWord shouldBe "orð"
        TypingSession.splitCurrentWord("\"orð").currentWord shouldBe "orð"
        TypingSession.splitCurrentWord("sagði \u201Corð").currentWord shouldBe "orð"
        TypingSession.splitCurrentWord("don't").currentWord shouldBe "don't"
    }

    // MARK: - Issue #9: patronymic title-casing after a capitalized word

    test("patronymic shape recognizes -sson / -dóttir only") {
        TypingSession.isPatronymic("jakobsdóttir") shouldBe true
        TypingSession.isPatronymic("jónsson") shouldBe true
        TypingSession.isPatronymic("Pétursdóttir") shouldBe true
        // English -son words must NOT match.
        TypingSession.isPatronymic("season") shouldBe false
        TypingSession.isPatronymic("person") shouldBe false
        TypingSession.isPatronymic("reason") shouldBe false
        TypingSession.isPatronymic("hestur") shouldBe false
    }

    test("title-cases a patronymic after a capitalized word") {
        val out = TypingSession.titleCaseNameSuggestions(
            listOf(
                Suggestion("jakobsdóttir", false, 0.5),
                Suggestion("sagði", false, 0.4),
            ),
            "Katrín ",
        )
        out.map { it.text } shouldBe listOf("Jakobsdóttir", "sagði")
    }

    test("no title-casing after a lowercase word") {
        val out = TypingSession.titleCaseNameSuggestions(
            listOf(Suggestion("jakobsdóttir", false, 0.5)),
            "hún ",
        )
        out.map { it.text } shouldBe listOf("jakobsdóttir")
    }

    test("verbatim slot keeps typed casing") {
        val out = TypingSession.titleCaseNameSuggestions(
            listOf(Suggestion("jakobsdóttir", false, 0.0, isVerbatim = true)),
            "Katrín ",
        )
        out.map { it.text } shouldBe listOf("jakobsdóttir")
    }

    // MARK: - Issue #3: quoted-term context predicate

    test("quoted-term context detects an opening double quote before the token") {
        TypingSession.isQuotedTermContext("„") shouldBe true
        TypingSession.isQuotedTermContext("\"") shouldBe true
        TypingSession.isQuotedTermContext("\u201C") shouldBe true
        TypingSession.isQuotedTermContext("sagði „") shouldBe true
        // No quote, or a quote NOT immediately before the token: normal.
        TypingSession.isQuotedTermContext("") shouldBe false
        TypingSession.isQuotedTermContext("hestur ") shouldBe false
        TypingSession.isQuotedTermContext("„orð\u201C ") shouldBe false
    }

    // MARK: - End-to-end through a session (needs the reference data tree)

    test("issue #8: a digit-leading token gets no letter suggestions") {
        val session = TypingSession(buildEngine())
        val suggestions = session.suggestions(`for` = "kostar 21.000,5", limit = 4)
        for (suggestion in suggestions.filterNot { it.isVerbatim }) {
            suggestion.text.all { it.isDigit() || it == '.' || it == ',' || it == ':' } shouldBe true
        }
    }

    test("issue #3: a quoted token is offered suggestions but never force-corrected") {
        val session = TypingSession(buildEngine())
        var buffer = ""
        var bar = emptyList<Suggestion>()
        for (ch in "„teh") {
            buffer += ch
            bar = session.suggestions(`for` = buffer, limit = 3)
        }
        // Offered (tap-only) but no auto-apply flag inside quotes.
        bar.any { it.isAutocorrect } shouldBe false
    }
})

/** Build the full bilingual engine from the reference data tree, mirroring CoreScenariosTest. */
private fun buildEngine(): TypeEngine {
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
