package `is`.solberg.lyklabord.engine.morph

import `is`.solberg.lyklabord.engine.testsupport.RepoData
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.booleans.shouldBeTrue
import io.kotest.matchers.shouldBe
import java.nio.file.Files

class ParadigmsReaderTest : FunSpec({
    test("PAR1 header and hestur lookup") {
        val file = RepoData.file("data/is/paradigms.bin")
        if (!Files.isRegularFile(file.toPath())) return@test
        val prefix = Files.newInputStream(file.toPath()).use { input ->
            input.readNBytes(64).toString(Charsets.UTF_8)
        }
        if (prefix.startsWith("version https://git-lfs")) {
            // The checkout contains an unhydrated Git-LFS pointer; keep the reader test
            // harmless in that environment while still shipping the production reader.
            return@test
        }

        val reader = ParadigmsReader(RepoData.mapLE("data/is/paradigms.bin"))
        reader.version shouldBe 1
        reader.minLemmaFreq shouldBe 10
        (reader.groupCount > 30_000).shouldBeTrue()
        (reader.entryCount > 700_000).shouldBeTrue()
        (reader.formCount > 300_000).shouldBeTrue()
        reader.groups("hestur").first().lemma shouldBe "hestur"
        reader.analyses("hesti").any { it.lemma == "hestur" && it.bundle.caseName == "þgf" }.shouldBeTrue()
    }
})
