package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.testsupport.buildEngine
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe

/**
 * Port of the upstream (iOS) engine test suite `WaveADogfoodTests` from
 * jokull/LyklabordApp: Wave A dogfood fixes — issue #6 (prefix-eating), issue
 * #8 (numeric guard), issue #9 (patronymic casing). Quoted-term relaxation (#3)
 * has its own suite in [QuotedTermRelaxationTest]. These verify the fixes
 * ported into the Kotlin [TypingSession].
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

    // MARK: - Issue #8: numeric guard (end-to-end through a session)

    test("issue #8: a digit-leading token gets no letter suggestions") {
        val session = TypingSession(buildEngine())
        val suggestions = session.suggestions(`for` = "kostar 21.000,5", limit = 4)
        for (suggestion in suggestions.filterNot { it.isVerbatim }) {
            suggestion.text.all { it.isDigit() || it == '.' || it == ',' || it == ':' } shouldBe true
        }
    }
})
