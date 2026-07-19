package `is`.solberg.lyklabord.engine.scenarios

import `is`.solberg.lyklabord.engine.AutocorrectApplyGuard
import `is`.solberg.lyklabord.engine.CorrectionTrace
import `is`.solberg.lyklabord.engine.FieldKind
import `is`.solberg.lyklabord.engine.PersonalTouchSnapshot
import `is`.solberg.lyklabord.engine.PersonalVocabulary
import `is`.solberg.lyklabord.engine.PersonalWord
import `is`.solberg.lyklabord.engine.ProxySimulator
import `is`.solberg.lyklabord.engine.RevertInstruction
import `is`.solberg.lyklabord.engine.Suggestion
import `is`.solberg.lyklabord.engine.TypeEngine
import `is`.solberg.lyklabord.engine.TypingSession
import `is`.solberg.lyklabord.engine.learning.LearningEvent
import java.io.File
import java.util.Locale

/** One parsed command, retaining the source line for useful failures. */
data class ScenarioCommand(val keyword: String, val argument: String, val line: Int)

data class ParsedScenario(
    val name: String,
    val commands: List<ScenarioCommand>,
    val quirk: Boolean = false,
)

data class ParsedScenarioFile(
    val preamble: List<ScenarioCommand>,
    val scenarios: List<ParsedScenario>,
)

/** Line-oriented parser for the Swift type-repl scenario format. */
object ScenarioDsl {
    fun parse(raw: String): ParsedScenarioFile {
        val preamble = mutableListOf<ScenarioCommand>()
        val scenarios = mutableListOf<ParsedScenario>()
        var currentName: String? = null
        var currentCommands = mutableListOf<ScenarioCommand>()
        var currentQuirk = false
        var pendingQuirk = false

        fun finish() {
            val name = currentName ?: return
            scenarios += ParsedScenario(name, currentCommands.toList(), currentQuirk)
            currentName = null
            currentCommands = mutableListOf()
            currentQuirk = false
        }

        raw.lineSequence().forEachIndexed { index, rawLine ->
            val lineNumber = index + 1
            val line = rawLine.trim()
            if (line.isEmpty()) return@forEachIndexed
            if (line.startsWith("#")) {
                val comment = line.removePrefix("#").trim()
                if (comment.startsWith("QUIRK") || comment.startsWith("[QUIRK]")) pendingQuirk = true
                return@forEachIndexed
            }
            val (keyword, argument) = split(line)
            if (keyword == "SCENARIO") {
                finish()
                currentName = argument
                currentQuirk = pendingQuirk
                pendingQuirk = false
                return@forEachIndexed
            }
            val command = ScenarioCommand(keyword, argument, lineNumber)
            if (currentName == null) preamble += command else currentCommands += command
        }
        finish()
        return ParsedScenarioFile(preamble, scenarios)
    }

    fun split(line: String): Pair<String, String> {
        val space = line.indexOf(' ')
        if (space < 0) return line to ""
        return line.substring(0, space) to line.substring(space + 1).trim()
    }

    fun unquote(text: String): String =
        if (text.length >= 2 && text.first() == '"' && text.last() == '"') text.substring(1, text.length - 1) else text
}

/** Mutable implementation of the Swift seeded personal vocabulary fixture. */
private class SeededPersonalVocabulary : PersonalVocabulary {
    val words = linkedMapOf<String, UInt>()
    val explicit = linkedSetOf<String>()
    val bigrams = linkedMapOf<String, UInt>()
    val tombstones = linkedSetOf<String>()

    val isEmpty: Boolean
        get() = words.isEmpty() && explicit.isEmpty() && bigrams.isEmpty() && tombstones.isEmpty()

    override fun allWords(): List<PersonalWord> = words.map { PersonalWord(it.key, it.value) }

    override fun continuations(of: String, limit: Int): List<PersonalWord> {
        if (limit <= 0) return emptyList()
        val prefix = "$of "
        return bigrams.asSequence()
            .filter { it.key.startsWith(prefix) }
            .map { PersonalWord(it.key.substring(prefix.length), it.value) }
            .sortedWith(compareByDescending<PersonalWord> { it.count }.thenBy { it.word })
            .take(limit)
            .toList()
    }

    override fun bigramCount(first: String, second: String): UInt? = bigrams["$first $second"]

    override fun isTombstoned(word: String): Boolean = word in tombstones

    override fun isExplicit(word: String): Boolean = word in explicit
}

data class ScenarioFailure(
    val scenario: String,
    val line: Int,
    val message: String,
    val quirk: Boolean = false,
) {
    override fun toString(): String = "[$scenario] line $line: $message"
}

data class ScenarioReport(
    val total: Int,
    val passed: Int,
    val failures: List<ScenarioFailure>,
) {
    val failed: Int get() = total - passed
}

/** The Kotlin twin of the Swift Typist, including proxy ledger and dot rules. */
class Typist(
    val engine: TypeEngine,
    val proxy: ProxySimulator = ProxySimulator(),
    var limit: Int = 5,
) {
    val session: TypingSession = TypingSession(engine)
    var appliesAutocorrectOnDot: Boolean = false

    var lastSuggestions: List<Suggestion> = emptyList()
        private set
    var lastContextBefore: String = ""
        private set
    var lastSuggestionPendingToken: String = ""
        private set
    var lastLatencyMicros: Double = 0.0
        private set
    val latenciesMicros = mutableListOf<Double>()
    var lastAppliedAutocorrect: Pair<String, String>? = null
        private set
    var lastRevert: RevertInstruction? = null
        private set
    var lastTrace: CorrectionTrace? = null
        private set
    val collectedEvents = mutableListOf<LearningEvent>()

    val currentWord: String
        get() = TypingSession.splitCurrentWord(lastContextBefore).currentWord

    fun type(text: String) {
        text.forEach(::typeCharacter)
    }

    fun typeCharacter(character: Char) {
        lastAppliedAutocorrect = null
        lastRevert = null
        val ledgerBefore = proxy.trueContextBeforeInput

        session.continuationRevert(character)?.let { revert ->
            repeat(revert.deleteCount) { proxy.deleteBackward() }
            proxy.insertText(revert.text)
            lastRevert = revert
        }
        session.punctuationAttachment(character)?.let { attachment ->
            repeat(attachment.deleteCount) { proxy.deleteBackward() }
            proxy.insertText(attachment.text)
        }

        val applies = TypingSession.isDelimiter(character) &&
            (character != '.' || appliesAutocorrectOnDot)
        if (applies) {
            val autocorrect = lastSuggestions.firstOrNull { it.isAutocorrect }
            if (
                autocorrect != null &&
                AutocorrectApplyGuard.shouldAutoApply(
                    recordedPendingToken = lastSuggestionPendingToken,
                    textBeforeCursor = proxy.trueContextBeforeInput,
                )
            ) {
                val word = currentWord
                if (word.isNotEmpty() && autocorrect.text != word) {
                    repeat(word.length) { proxy.deleteBackward() }
                    proxy.insertText(autocorrect.text)
                    lastAppliedAutocorrect = word to autocorrect.text
                }
            }
        }
        proxy.insertText(character.toString())
        session.noteSelfEdit(ledgerBefore, proxy.trueContextBeforeInput)
        refresh()
    }

    fun longPress(text: String) {
        text.forEach {
            session.noteLongPressInsertion(it)
            typeCharacter(it)
        }
    }

    fun tapCharacter(character: Char, dx: Double, dy: Double) {
        session.noteTap(character, dx, dy)
        typeCharacter(character)
    }

    fun pressBackspace(count: Int = 1) {
        repeat(count) {
            val before = proxy.trueContextBeforeInput
            proxy.deleteBackward()
            session.noteSelfEdit(before, proxy.trueContextBeforeInput)
            refresh()
        }
    }

    fun tapSuggestion(text: String): Boolean {
        val suggestion = lastSuggestions.firstOrNull { it.text == text } ?: return false
        lastAppliedAutocorrect = null
        lastRevert = null
        if (suggestion.isVerbatim) {
            if (!session.revertToLiteral(suggestion.text)) session.noteVerbatimChoice(suggestion.text)
        }
        val ledgerBefore = proxy.trueContextBeforeInput
        val word = currentWord
        repeat(word.length) { proxy.deleteBackward() }
        proxy.insertText(suggestion.text)
        val windows = proxy.contextWindows()
        if (!windows.before.endsWith(' ') && !windows.after.startsWith(' ')) proxy.insertText(" ")
        session.noteSelfEdit(ledgerBefore, proxy.trueContextBeforeInput)
        refresh()
        return true
    }

    fun predictSpace(): Boolean {
        val before = proxy.trueContextBeforeInput
        if (before.isNotEmpty() && !before.endsWith(' ')) return false
        val prediction = lastSuggestions.firstOrNull { !it.isVerbatim && it.text.isNotEmpty() } ?: return false
        lastAppliedAutocorrect = null
        lastRevert = null
        proxy.insertText(prediction.text)
        proxy.insertText(" ")
        session.noteSelfEdit(before, proxy.trueContextBeforeInput)
        refresh()
        return true
    }

    fun externalChange() {
        session.noteExternalTextChange()
        refresh()
    }

    fun silentExternalChange() = refresh()

    fun forwardWindowNote() {
        session.noteExternalTextChange(proxy.contextBeforeInput)
    }

    fun refresh() {
        val before = proxy.contextBeforeInput
        lastContextBefore = before
        lastSuggestionPendingToken = TypingSession.splitCurrentWord(before).currentWord
        val trace = CorrectionTrace()
        val start = System.nanoTime()
        lastSuggestions = session.suggestions(`for` = before, limit = limit, trace = trace)
        lastLatencyMicros = (System.nanoTime() - start).toDouble() / 1_000.0
        latenciesMicros += lastLatencyMicros
        lastTrace = trace
        collectPendingEvents()
    }

    fun collectPendingEvents() {
        if (session.hasPendingLearningEvents) collectedEvents += session.drainLearningEvents()
    }

    fun learnWord(word: String) {
        session.learnWordImmediately(word)
        collectPendingEvents()
    }

    fun reset(document: String = "") {
        proxy.hostReplaceText(document)
        session.reset()
        lastSuggestions = emptyList()
        lastContextBefore = ""
        lastSuggestionPendingToken = ""
        lastAppliedAutocorrect = null
        lastRevert = null
        latenciesMicros.clear()
        lastLatencyMicros = 0.0
        collectedEvents.clear()
    }
}

/** Replay runner; failures are retained so Kotest can report all mismatches. */
class ScenarioRunner(
    private val engine: TypeEngine,
    private val defaultLimit: Int = 5,
    private val basePersonal: PersonalVocabulary? = null,
    private val basePersonalTouch: PersonalTouchSnapshot? = null,
) {
    fun run(file: File): ScenarioReport = run(file.readText())

    fun runFile(fileAt: String): ScenarioReport = run(File(fileAt))

    fun run(raw: String): ScenarioReport {
        val parsed = ScenarioDsl.parse(raw)
        var limit = defaultLimit
        var typist = Typist(engine, limit = limit)
        var seeds = SeededPersonalVocabulary()
        var touchSeeds = linkedMapOf<Char, PersonalTouchSnapshot.KeyStats>()
        parsed.preamble.forEach { command ->
            if (command.keyword == "LIMIT") limit = command.argument.toIntOrNull() ?: limit
        }

        fun applySeeds() {
            engine.setPersonalVocabulary(if (seeds.isEmpty) basePersonal else seeds)
            engine.setPersonalTouch(
                if (touchSeeds.isEmpty()) basePersonalTouch else PersonalTouchSnapshot(touchSeeds),
            )
        }

        val failures = mutableListOf<ScenarioFailure>()
        var passed = 0
        parsed.scenarios.forEach { scenario ->
            seeds = SeededPersonalVocabulary()
            touchSeeds = linkedMapOf()
            applySeeds()
            typist = Typist(engine, limit = limit)
            typist.reset()
            var failed = false
            fun fail(command: ScenarioCommand, message: String) {
                failures += ScenarioFailure(scenario.name, command.line, message, scenario.quirk)
                failed = true
            }
            fun expectBar(command: ScenarioCommand, check: (List<Suggestion>) -> String?) {
                check(typist.lastSuggestions)?.let { fail(command, it) }
            }

            scenario.commands.forEach { command ->
                when (command.keyword) {
                    "LIMIT" -> {
                        limit = command.argument.toIntOrNull() ?: limit
                        typist.limit = limit
                    }
                    "T", "TYPE" -> typist.type(ScenarioDsl.unquote(command.argument))
                    "RESET" -> typist.reset(ScenarioDsl.unquote(command.argument))
                    "LONGPRESS" -> typist.longPress(ScenarioDsl.unquote(command.argument))
                    "BACKSPACE" -> typist.pressBackspace(command.argument.toIntOrNull() ?: 1)
                    "FIELD" -> {
                        val kind = FieldKind.entries.firstOrNull { it.rawValue == command.argument }
                        if (kind == null) fail(command, "bad FIELD argument: ${command.argument}") else typist.session.fieldKind = kind
                    }
                    "CONTEXT", "HOST_SET", "HOST_SET_SILENT" -> {
                        typist.proxy.hostReplaceText(ScenarioDsl.unquote(command.argument))
                        if (command.keyword == "HOST_SET_SILENT") typist.silentExternalChange() else typist.externalChange()
                    }
                    "CURSOR_MOVE", "CURSOR_MOVE_SILENT" -> {
                        when (command.argument) {
                            "start" -> typist.proxy.moveCursor(to = 0)
                            "end" -> typist.proxy.moveCursor(to = typist.proxy.document.length)
                            else -> {
                                val parsed = command.argument.toIntOrNull()
                                if (parsed == null) {
                                    fail(command, "bad ${command.keyword} argument: ${command.argument}")
                                } else if (command.argument.startsWith('+') || command.argument.startsWith('-')) {
                                    typist.proxy.moveCursor(by = parsed)
                                } else {
                                    typist.proxy.moveCursor(to = parsed)
                                }
                            }
                        }
                        if (command.keyword == "CURSOR_MOVE_SILENT") typist.silentExternalChange() else typist.externalChange()
                    }
                    "NOTE_WINDOW" -> typist.forwardWindowNote()
                    "TRUNCATE_AT" -> {
                        val n = command.argument.toIntOrNull()
                        if (n == null) fail(command, "bad TRUNCATE_AT argument: ${command.argument}") else typist.proxy.truncation.maxBeforeLength = n
                    }
                    "STALE_READS" -> typist.proxy.staleReads = command.argument == "on"
                    "SWALLOW_EDITS" -> typist.proxy.swallowEdits = command.argument == "on"
                    "PREDICT_SPACE" -> if (!typist.predictSpace()) {
                        fail(command, "PREDICT_SPACE needs no word in progress and a prediction in the bar: ${describe(typist.lastSuggestions)}")
                    }
                    "REFRESH" -> typist.refresh()
                    "DOT_APPLY" -> typist.appliesAutocorrectOnDot = command.argument == "on"
                    "TAP" -> {
                        val parts = command.argument.split(Regex("\\s+"))
                        val character = parts.firstOrNull()?.singleOrNull()
                        val dx = parts.getOrNull(1)?.toDoubleOrNull()
                        val dy = parts.getOrNull(2)?.toDoubleOrNull()
                        if (parts.size == 3 && character != null && dx != null && dy != null) {
                            typist.tapCharacter(character, dx, dy)
                        } else if (!typist.tapSuggestion(ScenarioDsl.unquote(command.argument))) {
                            fail(command, "no suggestion \"${command.argument}\" to tap, bar: ${describe(typist.lastSuggestions)}")
                        }
                    }
                    "PERSONAL" -> {
                        val parts = command.argument.split(Regex("\\s+"))
                        val count = parts.getOrNull(1)?.toUIntOrNull()
                        if (parts.size == 2 && count != null) {
                            seeds.words[parts[0]] = count
                            applySeeds()
                        } else fail(command, "usage: PERSONAL <word> <count>")
                    }
                    "PERSONAL_EXPLICIT" -> {
                        val parts = command.argument.split(Regex("\\s+"))
                        val count = parts.getOrNull(1)?.toUIntOrNull()
                        if (parts.size == 1 && parts[0].isNotEmpty()) {
                            seeds.words[parts[0]] = maxOf(seeds.words[parts[0]] ?: 0u, 1u)
                            seeds.explicit += parts[0]
                            applySeeds()
                        } else if (parts.size == 2 && count != null) {
                            seeds.words[parts[0]] = count
                            seeds.explicit += parts[0]
                            applySeeds()
                        } else fail(command, "usage: PERSONAL_EXPLICIT <word> [count]")
                    }
                    "PERSONAL_BIGRAM" -> {
                        val parts = command.argument.split(Regex("\\s+"))
                        val count = parts.getOrNull(2)?.toUIntOrNull()
                        if (parts.size == 3 && count != null) {
                            seeds.bigrams["${parts[0]} ${parts[1]}"] = count
                            applySeeds()
                        } else fail(command, "usage: PERSONAL_BIGRAM <first> <second> <count>")
                    }
                    "PERSONAL_TOUCH" -> {
                        val parts = command.argument.split(Regex("\\s+"))
                        val character = parts.firstOrNull()?.singleOrNull()
                        val values = parts.drop(1).map { it.toDoubleOrNull() }
                        if (parts.size in 6..7 && character != null && values.all { it != null }) {
                            val count = values[0]!!
                            val meanDx = values[1]!!
                            val meanDy = values[2]!!
                            val sigmaX = values[3]!!
                            val sigmaY = values[4]!!
                            val covariance = values.getOrNull(5) ?: 0.0
                            touchSeeds[character] = PersonalTouchSnapshot.KeyStats(
                                meanDX = meanDx,
                                meanDY = meanDy,
                                varianceX = sigmaX * sigmaX,
                                varianceY = sigmaY * sigmaY,
                                covarianceXY = covariance,
                                count = count,
                            )
                            applySeeds()
                        } else fail(command, "usage: PERSONAL_TOUCH <char> <count> <meanDx> <meanDy> <sigmaX> <sigmaY> [cov]")
                    }
                    "TOMBSTONE" -> if (command.argument.isEmpty()) {
                        fail(command, "usage: TOMBSTONE <word>")
                    } else {
                        seeds.tombstones += command.argument
                        applySeeds()
                    }
                    "LEARN" -> if (command.argument.isEmpty()) fail(command, "usage: LEARN <word>") else typist.learnWord(command.argument)
                    "EJECT" -> if (command.argument.isEmpty()) {
                        fail(command, "usage: EJECT <word>")
                    } else {
                        seeds.words.remove(command.argument)
                        seeds.explicit.remove(command.argument)
                        seeds.tombstones += command.argument
                        engine.forgetSessionWord(command.argument)
                        applySeeds()
                        typist.refresh()
                    }
                    "EXPECT_PERSONAL_LEARNED" -> expectBar(command) { bar ->
                        val hit = bar.firstOrNull { it.text == command.argument }
                        when {
                            hit == null -> "expected \"${command.argument}\" in bar: ${describe(bar)}"
                            !hit.isPersonalLearned -> "\"${command.argument}\" is in the bar but NOT flagged personal-learned"
                            else -> null
                        }
                    }
                    "EXPECT_NOT_PERSONAL_LEARNED" -> expectBar(command) { bar ->
                        val hit = bar.firstOrNull { it.text == command.argument }
                        when {
                            hit == null -> "expected \"${command.argument}\" in bar: ${describe(bar)}"
                            hit.isPersonalLearned -> "\"${command.argument}\" is unexpectedly flagged personal-learned"
                            else -> null
                        }
                    }
                    "EXPECT_EVENTS" -> {
                        typist.collectPendingEvents()
                        val expected = command.argument.toIntOrNull()
                        if (expected == null || typist.collectedEvents.size != expected) {
                            fail(command, "expected ${command.argument} learning events, got ${typist.collectedEvents.size}: ${typist.collectedEvents}")
                        }
                    }
                    "EXPECT_TOP" -> expectBar(command) { bar ->
                        if (bar.firstOrNull { !it.isVerbatim }?.text == command.argument) null
                        else "expected top \"${command.argument}\", bar: ${describe(bar)}"
                    }
                    "EXPECT_AUTOCORRECT" -> expectBar(command) { bar ->
                        val top = bar.firstOrNull { !it.isVerbatim }
                        when {
                            top == null -> "expected autocorrect \"${command.argument}\", bar: ${describe(bar)}"
                            top.text != command.argument -> "expected autocorrect \"${command.argument}\", top is \"${top.text}\"${if (top.isAutocorrect) "*" else ""}"
                            !top.isAutocorrect -> "top is \"${top.text}\" but NOT flagged autocorrect"
                            else -> null
                        }
                    }
                    "EXPECT_VERBATIM" -> expectBar(command) { bar ->
                        val first = bar.firstOrNull()
                        when {
                            first == null -> "expected verbatim \"${command.argument}\", bar empty"
                            !first.isVerbatim -> "expected verbatim slot first, bar: ${describe(bar)}"
                            first.text != command.argument -> "expected verbatim \"${command.argument}\", got \"${first.text}\""
                            else -> null
                        }
                    }
                    "EXPECT_ONLY_VERBATIM" -> expectBar(command) { bar ->
                        val only = bar.singleOrNull()
                        when {
                            only == null || !only.isVerbatim -> "expected only the verbatim slot, bar: ${describe(bar)}"
                            only.text != command.argument -> "expected verbatim \"${command.argument}\", got \"${only.text}\""
                            else -> null
                        }
                    }
                    "EXPECT_NO_AUTOCORRECT" -> expectBar(command) { bar ->
                        val flagged = bar.firstOrNull { it.isAutocorrect }
                        if (flagged == null) null else "autocorrect fired: \"${flagged.text}\" (bar: ${describe(bar)})"
                    }
                    "EXPECT_CONTAINS" -> expectBar(command) { bar ->
                        if (bar.any { it.text == command.argument }) null else "expected \"${command.argument}\" in bar: ${describe(bar)}"
                    }
                    "EXPECT_NOT_CONTAINS" -> expectBar(command) { bar ->
                        if (bar.any { it.text == command.argument }) "did not expect \"${command.argument}\" in bar: ${describe(bar)}" else null
                    }
                    "EXPECT_NO_SPLIT" -> expectBar(command) { bar ->
                        val split = bar.firstOrNull { ' ' in it.text }
                        if (split == null) null else "split suggestion offered: \"${split.text}\" (bar: ${describe(bar)})"
                    }
                    "EXPECT_EMPTY" -> expectBar(command) { bar -> if (bar.isEmpty()) null else "expected empty bar, got: ${describe(bar)}" }
                    "EXPECT_NONEMPTY" -> expectBar(command) { bar -> if (bar.isEmpty()) "expected non-empty bar" else null }
                    "EXPECT_POSTERIOR_GT" -> {
                        val expected = command.argument.toDoubleOrNull() ?: Double.POSITIVE_INFINITY
                        if (!(typist.session.probabilityIcelandic > expected)) fail(command, "expected P(IS) > ${command.argument}, got ${"%.3f".format(Locale.US, typist.session.probabilityIcelandic)}")
                    }
                    "EXPECT_POSTERIOR_LT" -> {
                        val expected = command.argument.toDoubleOrNull() ?: Double.NEGATIVE_INFINITY
                        if (!(typist.session.probabilityIcelandic < expected)) fail(command, "expected P(IS) < ${command.argument}, got ${"%.3f".format(Locale.US, typist.session.probabilityIcelandic)}")
                    }
                    "EXPECT_COMMITS" -> {
                        val expected = command.argument.toIntOrNull()
                        if (expected == null || typist.session.committedWordCount != expected) fail(command, "expected ${command.argument} commits, got ${typist.session.committedWordCount}")
                    }
                    "EXPECT_LAST_COMMIT" -> {
                        if (typist.session.lastCommittedWord != command.argument) fail(command, "expected last commit \"${command.argument}\", got ${typist.session.lastCommittedWord?.let { "\"$it\"" } ?: "none"}")
                    }
                    "EXPECT_BUFFER" -> {
                        val expected = ScenarioDsl.unquote(command.argument)
                        if (typist.proxy.document != expected) fail(command, "expected buffer \"$expected\", got \"${typist.proxy.document}\"")
                    }
                    "EXPECT_CONTEXT" -> {
                        val expected = ScenarioDsl.unquote(command.argument)
                        if (typist.lastContextBefore != expected) fail(command, "expected context \"$expected\", got \"${typist.lastContextBefore}\"")
                    }
                    else -> fail(command, "unknown directive: ${command.keyword}")
                }
            }
            if (!failed) passed++
        }
        return ScenarioReport(parsed.scenarios.size, passed, failures)
    }

    private fun describe(bar: List<Suggestion>): String =
        if (bar.isEmpty()) "(empty)" else bar.joinToString(", ") {
            val text = if (it.isVerbatim) "“${it.text}”" else it.text
            "$text${if (it.isAutocorrect) "*" else ""}"
        }
}
