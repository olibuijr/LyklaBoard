package `is`.solberg.lyklabord.engine.lexicon

import `is`.solberg.lyklabord.engine.testsupport.RepoData
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.booleans.shouldBeFalse
import io.kotest.matchers.booleans.shouldBeTrue
import io.kotest.matchers.ints.shouldBeGreaterThan

class CuratedVocabularyTest : FunSpec({
    test("parses the shipped extra vocabulary") {
        val vocabulary = CuratedVocabulary.fromFile(RepoData.file("data/is/extra-vocab.txt"))
            ?: error("extra-vocab.txt should contain curated forms")

        vocabulary.count.shouldBeGreaterThan(0)
        vocabulary.forms.isNotEmpty().shouldBeTrue()
        vocabulary.forms.any { it.isBlank() }.shouldBeFalse()
        vocabulary.forms.none { it.startsWith("#") }.shouldBeTrue()
        vocabulary.contains("ChatGPT").shouldBeTrue()
        vocabulary.contains("chatgpt").shouldBeTrue()
        vocabulary.contains("").shouldBeFalse()
    }
})
