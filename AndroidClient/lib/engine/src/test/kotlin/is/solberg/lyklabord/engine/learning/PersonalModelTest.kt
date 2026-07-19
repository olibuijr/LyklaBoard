package `is`.solberg.lyklabord.engine.learning

import java.nio.file.Files
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.doubles.plusOrMinus
import io.kotest.matchers.shouldBe

class PersonalModelTest : FunSpec({
    test("events compact save and reload with words tombstones and touch statistics") {
        val dir = Files.createTempDirectory("lyklabord-learning").toFile()
        val logFile = dir.resolve("events.log")
        val modelFile = dir.resolve("personal.json")
        var day = 100
        val log = EventLog(logFile) { day }
        val model = PersonalModel()
        model.remove("deleted")
        log.append(LearningEvent.WordCommitted("halló", languageHint = LanguageHint.ICELANDIC))
        day = 101
        log.append(contentsOf = listOf(
            LearningEvent.WordCommitted("halló", languageHint = LanguageHint.ICELANDIC),
            LearningEvent.WordCommitted("heimur", previousWord = "halló", languageHint = LanguageHint.ICELANDIC),
            LearningEvent.WordCommitted("deleted"),
            LearningEvent.TouchSample('h', 0.10, -0.20),
            LearningEvent.TouchSample('h', 0.20, -0.10),
        ))

        val summary = model.compactAndSave(applying = log, to = modelFile)
        summary.eventsApplied shouldBe 6
        summary.logTruncated shouldBe true
        val reloaded = PersonalModel(contentsOf = modelFile)
        reloaded.commitCount(of = "halló") shouldBe 2u
        reloaded.isLearned("halló") shouldBe true
        reloaded.bigramFrequency("halló", "heimur") shouldBe 1u
        reloaded.isTombstoned("deleted") shouldBe true
        reloaded.commitCount(of = "deleted") shouldBe 0u
        val stats = reloaded.touchStatistics('h')!!
        stats.count shouldBe 2.0
        stats.meanDX shouldBe 0.15.plusOrMinus(1e-9)
        stats.meanDY shouldBe (-0.15).plusOrMinus(1e-9)
        stats.varianceDX shouldBe 0.005.plusOrMinus(1e-9)
        stats.varianceDY shouldBe 0.005.plusOrMinus(1e-9)
        reloaded.consumedLogMarker shouldBe EventLog(logFile).read().endMarker
    }
})
