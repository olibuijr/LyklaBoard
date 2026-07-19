package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.testsupport.buildEngine
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe

/**
 * Port of the upstream (iOS) engine test suite `QuotedTermRelaxationTests` from
 * jokull/LyklabordApp (GitHub issue #3): a token typed immediately after an
 * opening double quote („ / " / ") is often a deliberate foreign/technical
 * term — suggestions stay OFFERED (tap-only) but the auto-apply flag is
 * stripped so nothing force-replaces a quoted token (dogfood: „vold [c→v miss
 * for "cold"] auto-applied to „völd). Adjacency-gated, not a global weakening.
 * Verifies the behavior ported into the Kotlin [TypingSession].
 */
class QuotedTermRelaxationTest : FunSpec({

    // Feed text character-by-character (like keystrokes through the proxy),
    // returning the suggestions from the final keystroke.
    fun typeThrough(session: TypingSession, text: String, limit: Int = 3): List<Suggestion> {
        var buffer = ""
        var result = emptyList<Suggestion>()
        for (ch in text) {
            buffer += ch
            result = session.suggestions(`for` = buffer, limit = limit)
        }
        return result
    }

    // MARK: - Context predicate

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

    // MARK: - End-to-end through a session

    test("a quoted token keeps suggestions but loses auto-apply") {
        // "teh" reliably arms autocorrect from a fresh session; inside quotes
        // it must keep its suggestions but lose the auto-apply flag.
        val s = TypingSession(buildEngine())
        val bar = typeThrough(s, "„teh")
        bar.any { !it.isVerbatim } shouldBe true
        bar.any { it.isAutocorrect } shouldBe false
    }

    test("the same token without a quote keeps normal autocorrect") {
        // Control: the same token with no ADJACENT quote arms autocorrect —
        // the relaxation is adjacency-gated, not a global weakening. (Swift's
        // Fixtures.engine() arms a sentence-initial "teh"; the Kotlin reference
        // fixture reaches the auto-apply threshold with the "with the" bigram,
        // so the unquoted control primes the same context the quoted forms use.)
        val s = TypingSession(buildEngine())
        val bar = typeThrough(s, "with teh")
        bar.any { it.isAutocorrect } shouldBe true
    }

    test("a straight quote behaves like an Icelandic quote") {
        val s = TypingSession(buildEngine())
        val bar = typeThrough(s, "\"teh")
        bar.any { !it.isVerbatim } shouldBe true
        bar.any { it.isAutocorrect } shouldBe false
    }

    test("a curly opening quote behaves like an Icelandic quote") {
        val s = TypingSession(buildEngine())
        val bar = typeThrough(s, "\u201Cteh")
        bar.any { it.isAutocorrect } shouldBe false
    }

    test("a quotation closed earlier in the sentence does not suppress") {
        // „with" commits the quoted word, then "teh" after the space arms
        // autocorrect normally (the "with the" bigram backs the correction).
        val s = TypingSession(buildEngine())
        val bar = typeThrough(s, "„with\u201C teh")
        bar.any { it.isAutocorrect } shouldBe true
    }

    test("a still-open quotation does not suppress later words") {
        // Inside a still-open quotation only the FIRST token sits right after
        // the quote; the second word (context ends with the space) corrects
        // normally. Per-token adjacency, not a quotation-spanning mode.
        val s = TypingSession(buildEngine())
        val bar = typeThrough(s, "„with teh")
        bar.any { it.isAutocorrect } shouldBe true
    }
})
