package `is`.solberg.lyklabord.engine.morph

import `is`.solberg.lyklabord.engine.testsupport.RepoData
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.booleans.shouldBeFalse
import io.kotest.matchers.booleans.shouldBeTrue
import io.kotest.matchers.collections.shouldContain
import io.kotest.matchers.shouldBe

class BinaryLemmatizerTest : FunSpec({
    val lemmatizer = BinaryLemmatizer(RepoData.mapLE("data/is/bin-morph.core.bin"))

    test("shipped compact core is a valid LEMA v1 table") {
        // Grounded: data/is/bin-morph.core.bin is LEMA v1 (magic 0x4C454D41,
        // version 1, 99680 lemmas, 350000 word forms, 0 bigrams). v1 carries no
        // packed morph features.
        lemmatizer.version shouldBe 1
        lemmatizer.hasMorphFeatures.shouldBeFalse()
        (lemmatizer.lemmaCount > 1000).shouldBeTrue()
        (lemmatizer.wordFormCount > 1000).shouldBeTrue()
    }

    test("hestur is known and lemmatizes to itself with a noun POS") {
        lemmatizer.isKnown("hestur").shouldBeTrue()
        lemmatizer.isKnown("HESTUR") shouldBe lemmatizer.isKnown("hestur")
        lemmatizer.lemmatize("hestur") shouldContain "hestur"

        val pos = lemmatizer.lemmatizeWithPOS("hestur")
        pos.any { it.lemma == "hestur" && it.pos == "no" }.shouldBeTrue()

        // Faithful to Swift: v1 packs no case/gender bits (both null), but the
        // shared number table maps code 0 -> "et", so number is "et" for every
        // v1 entry (mirrors BinaryLemmatizer.swift codeToNumber = ["et","ft"]).
        val morph = lemmatizer.lemmatizeWithMorph("hestur").first { it.lemma == "hestur" && it.pos == "no" }
        morph.morph?.grammaticalCase shouldBe null
        morph.morph?.gender shouldBe null
        morph.morph?.number shouldBe "et"
    }

    test("unknown and apostrophe-normalized words behave consistently") {
        lemmatizer.isKnown("zzzxqwk").shouldBeFalse()
        // Unknown words echo the normalized surface form (fold U+2019, lowercase, NFC).
        lemmatizer.lemmatize("ZZZ\u2019X") shouldBe listOf("zzz'x")
    }
})
