package `is`.solberg.lyklabord.engine.lexicon

import `is`.solberg.lyklabord.engine.testsupport.RepoData
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.booleans.shouldBeTrue
import io.kotest.matchers.ints.shouldBeGreaterThan
import io.kotest.matchers.shouldBe
import io.kotest.matchers.shouldNotBe

/**
 * Verifies the Kotlin [FrequencyLexicon] reader parses the shipped `LXC1` v1
 * artifacts and answers lookups consistently with the format contract.
 */
class FrequencyLexiconTest : FunSpec({

    val lex = FrequencyLexicon(RepoData.mapLE("data/is/is.lex"))

    test("header parses to a sane table") {
        lex.version shouldBe 1
        lex.unigramCount shouldBeGreaterThan 1000
        lex.bigramCount shouldBeGreaterThan 1000
        (lex.totalUnigramTokens > 0uL).shouldBeTrue()
    }

    test("a common Icelandic word is known") {
        lex.frequency("hestur") shouldNotBe null
        // Case + apostrophe folding: uppercase and curly variants resolve.
        lex.frequency("HESTUR") shouldBe lex.frequency("hestur")
    }

    test("completions of a prefix are non-empty, contain the prefix word, sorted desc") {
        val comps = lex.completions("hes", limit = 20)
        comps.isNotEmpty().shouldBeTrue()
        comps.any { it.word == "hestur" }.shouldBeTrue()
        comps.all { it.word.startsWith("hes") }.shouldBeTrue()
        for (i in 1 until comps.size) {
            (comps[i - 1].frequency >= comps[i].frequency).shouldBeTrue()
        }
    }

    test("continuations of a known word are next-words sorted desc") {
        val conts = lex.continuations("það", limit = 10)
        // "það" is among the most common Icelandic words; it must have bigrams.
        conts.isNotEmpty().shouldBeTrue()
        for (i in 1 until conts.size) {
            (conts[i - 1].frequency >= conts[i].frequency).shouldBeTrue()
        }
    }

    test("prefix cursor descends and finds exact word") {
        val search = FrequencyLexiconPrefixSearch(lex)
        var cursor = search.prefixRootCursor()
        for (ch in "hestur") {
            cursor = search.descend(cursor, ch)
        }
        (cursor.count > 0).shouldBeTrue()
        search.exactEntry(cursor)?.word shouldBe "hestur"
    }
})
