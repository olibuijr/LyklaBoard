package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.learning.EventLog
import `is`.solberg.lyklabord.engine.learning.LanguageHint
import `is`.solberg.lyklabord.engine.learning.LearningEvent

/** Kind of host text field. */
enum class FieldKind(val rawValue: String) {
    standard("standard"), url("url"), email("email"), webSearch("webSearch"), secure("secure");

    val suppressesAutocorrect: Boolean get() = this != standard
    val allowsLearning: Boolean get() = this == standard
}

data class RevertInstruction(val deleteCount: Int, val text: String)
data class SplitCurrentWord(val context: String, val currentWord: String)

/** Stateful, UIKit-free text-before-cursor embedder. */
class TypingSession(val engine: TypeEngine) {
    var fieldKind: FieldKind = FieldKind.standard
    var committedWordCount: Int = 0
        private set
    var posteriorUpdateCount: Int = 0
        private set
    var lastCommittedWord: String? = null
        private set

    private var lastSeenWindow: String? = null
    private val ledger = ExpectedEditLedger()
    private var lastObservedWindow: String? = null
    private var ledgerRecordsSelfEdits = false
    private var previousCurrentWord = ""
    private var carriedContext: String? = null
    private var lastEmittedAutocorrect: String? = null
    private var lastEmittedSuggestionTexts: List<String> = emptyList()
    private var punctuationAttachmentArmed = false
    private var dotReplacement: DotReplacement? = null
    private var verbatimChoice: String? = null
    private var backspaceRevert: BackspaceRevert? = null
    private var backspaceRevertJustArmed = false
    private var literalSlotShowing = false
    private var longPressedCharacters = mutableListOf<Char>()
    private var pendingTapRecord = mutableListOf<TapSample?>()
    private var incomingTaps = mutableListOf<TapSample>()
    private var pendingEvents = mutableListOf<LearningEvent>()
    private var previousCommittedForEvents: String? = null
    private var tapLearnedWord: String? = null

    private data class DotReplacement(val original: String, val corrected: String)
    private data class BackspaceRevert(val literal: String, val corrected: String)

    val probabilityIcelandic: Double get() = engine.probabilityIcelandic
    val hasPendingLearningEvents: Boolean get() = pendingEvents.isNotEmpty()
    val hasPendingContinuationRevert: Boolean get() = dotReplacement != null
    val hasPendingPunctuationAttachment: Boolean get() = punctuationAttachmentArmed
    val hasArmedLiteralRevert: Boolean get() = literalSlotShowing

    fun suggestions(
        `for`: String,
        limit: Int = 3,
        trace: CorrectionTrace? = null,
    ): List<Suggestion> {
        dotReplacement = null
        punctuationAttachmentArmed = false
        val textBeforeCursor = `for`
        val split = splitCurrentWord(textBeforeCursor)
        val context = split.context
        val currentWord = split.currentWord
        val hadTrustedWindow = lastSeenWindow != null
        val windowShrank = lastSeenWindow?.let { textBeforeCursor.length < it.length } ?: false
        when (val change = classifyChange(textBeforeCursor)) {
            is WindowChange.Evolution -> {
                noteDotReplacementIfAny(currentWord)
                confirmIfCommitted(context, currentWord, change.appendedAfterContext)
                armPunctuationAttachmentIfAny(textBeforeCursor, currentWord, change.appendedAfterContext)
            }
            WindowChange.TruncationReset -> confirmPendingWordAfterTruncationReset()
            WindowChange.External -> {
                carriedContext = null
                verbatimChoice = null
                backspaceRevert = null
                ledger.clear()
                pendingTapRecord.clear()
                if (hadTrustedWindow) incomingTaps.clear()
            }
        }
        if (context.isNotEmpty()) carriedContext = null
        if (backspaceRevertJustArmed) backspaceRevertJustArmed = false
        else resolveBackspaceRevert(currentWord, windowShrank)
        reconcileTapRecord(currentWord)
        previousCurrentWord = currentWord
        lastSeenWindow = textBeforeCursor
        lastObservedWindow = textBeforeCursor
        if (currentWord.isEmpty()) longPressedCharacters.clear()
        val bar = buildSuggestions(context, currentWord, limit, trace)
        lastEmittedAutocorrect = bar.firstOrNull { it.isAutocorrect }?.text
        lastEmittedSuggestionTexts = bar.filterNot { it.isVerbatim }.map { it.text }
        return bar
    }

    private fun resolveBackspaceRevert(currentWord: String, windowShrank: Boolean) {
        val memo = backspaceRevert ?: return
        if (!(currentWord == memo.corrected && windowShrank)) {
            backspaceRevert = null
        }
    }

    fun noteLongPressInsertion(character: Char) {
        character.lowercaseChar().let { longPressedCharacters += it }
    }

    fun noteTap(char: Char, dx: Double, dy: Double) {
        if (incomingTaps.size >= incomingTapQueueLimit) incomingTaps.removeAt(0)
        incomingTaps += TapSample(char.lowercaseChar(), dx, dy)
    }

    fun noteVerbatimChoice(token: String) {
        verbatimChoice = token
        learnWordImmediately(token)
    }

    fun learnWordImmediately(word: String) {
        if (!fieldKind.allowsLearning) return
        val token = strippedEventToken(word)
        if (!isEventWord(token) || token == tapLearnedWord) return
        engine.learnSessionWord(token)
        tapLearnedWord = token
        pendingEvents += LearningEvent.wordTapped(token)
    }

    fun drainLearningEvents(): List<LearningEvent> {
        val result = pendingEvents.toList()
        pendingEvents.clear()
        return result
    }

    fun continuationRevert(`for`: Char): RevertInstruction? {
        val memo = dotReplacement ?: return null
        dotReplacement = null
        if (!`for`.isLetter() && !`for`.isDigit()) return null
        lastSeenWindow?.let { window ->
            if (window.endsWith(memo.corrected)) {
                lastSeenWindow = window.dropLast(memo.corrected.length) + memo.original
            }
        }
        previousCurrentWord = memo.original
        if (fieldKind.allowsLearning) {
            val original = strippedEventToken(memo.original)
            val applied = strippedEventToken(memo.corrected)
            if (original != applied && isEventWord(original) && isEventWord(applied)) {
                pendingEvents += LearningEvent.correctionReverted(original, applied)
            }
        }
        return RevertInstruction(memo.corrected.length, memo.original)
    }

    fun punctuationAttachment(`for`: Char): RevertInstruction? {
        if (!punctuationAttachmentArmed) return null
        punctuationAttachmentArmed = false
        if (`for` != ' ') return null
        lastSeenWindow?.let { window ->
            if (window.endsWith(" .")) lastSeenWindow = window.dropLast(2) + "."
        }
        engine.noteSentenceBoundary()
        return RevertInstruction(2, ".")
    }

    fun revertToLiteral(matching: String): Boolean {
        val memo = backspaceRevert ?: return false
        if (!literalSlotShowing || memo.literal != matching) return false
        backspaceRevert = null
        verbatimChoice = memo.literal
        if (fieldKind.allowsLearning) {
            val original = strippedEventToken(memo.literal)
            val applied = strippedEventToken(memo.corrected)
            if (original != applied && isEventWord(original) && isEventWord(applied)) {
                pendingEvents += LearningEvent.correctionReverted(original, applied)
            }
        }
        tapLearnedWord = strippedEventToken(memo.literal)
        return true
    }

    fun noteSelfEdit(before: String, after: String) {
        if (before == after) return
        ledgerRecordsSelfEdits = true
        ledger.record(before, after, lastObservedWindow)
    }

    fun noteExternalTextChange() {
        previousCurrentWord = ""
        lastSeenWindow = null
        lastObservedWindow = null
        ledger.clear()
        carriedContext = null
        dotReplacement = null
        verbatimChoice = null
        backspaceRevert = null
        backspaceRevertJustArmed = false
        longPressedCharacters.clear()
        pendingTapRecord.clear()
        incomingTaps.clear()
        punctuationAttachmentArmed = false
        lastEmittedSuggestionTexts = emptyList()
        previousCommittedForEvents = null
        tapLearnedWord = null
    }

    fun noteExternalTextChange(window: String) {
        if (lastSeenWindow == null) return
        if (ledger.wouldExplain(window, lastObservedWindow)) return
        if (heuristicChange(window) == WindowChange.External) noteExternalTextChange()
    }

    fun reset() {
        previousCurrentWord = ""
        lastSeenWindow = null
        lastObservedWindow = null
        ledger.clear()
        ledgerRecordsSelfEdits = false
        carriedContext = null
        dotReplacement = null
        verbatimChoice = null
        backspaceRevert = null
        backspaceRevertJustArmed = false
        literalSlotShowing = false
        longPressedCharacters.clear()
        pendingTapRecord.clear()
        incomingTaps.clear()
        punctuationAttachmentArmed = false
        lastEmittedAutocorrect = null
        lastEmittedSuggestionTexts = emptyList()
        committedWordCount = 0
        posteriorUpdateCount = 0
        lastCommittedWord = null
        pendingEvents.clear()
        previousCommittedForEvents = null
        tapLearnedWord = null
        engine.resetLanguagePosterior()
        engine.clearSessionVocabulary()
    }

    private fun reconcileTapRecord(currentWord: String) {
        val target = currentWord.lowercase().toList()
        if (target.isEmpty()) {
            pendingTapRecord.clear()
            incomingTaps.clear()
            return
        }
        val previous = previousCurrentWord.lowercase().toList()
        var record = pendingTapRecord.toMutableList()
        if (record.size != previous.size) record = MutableList(previous.size) { null }
        if (target.size >= previous.size && target.subList(0, previous.size) == previous) {
            for (char in target.drop(previous.size)) {
                val first = incomingTaps.firstOrNull()
                if (first != null && first.char == char) {
                    record += first
                    incomingTaps.removeAt(0)
                } else {
                    record += null
                }
            }
        } else if (previous.size >= target.size && previous.subList(0, target.size) == target) {
            record = record.take(target.size).toMutableList()
        } else {
            record = MutableList(target.size) { null }
        }
        pendingTapRecord = record
        incomingTaps.clear()
    }

    private fun buildSuggestions(context: String, currentWord: String, limit: Int, trace: CorrectionTrace?): List<Suggestion> {
        literalSlotShowing = false
        if (limit <= 0) return emptyList()
        if (currentWord.isEmpty()) {
            return engine.suggestions(context = if (context.isEmpty()) (carriedContext ?: "") else context, currentWord = "", limit = limit, trace = trace)
        }
        val pendingDot = currentWord.endsWith('.')
        val stem = if (pendingDot) currentWord.dropLast(1) else currentWord
        var engineSuggestions = mutableListOf<Suggestion>()
        if (isVerbatimClassToken(stem)) {
            val segment = trailingSegment(stem)
            if (segment.length >= 2) {
                val prefix = stem.dropLast(segment.length)
                engineSuggestions = engine.suggestions(context = "", currentWord = segment, limit = limit)
                    .filter { !it.text.contains(' ') }
                    .map { it.copy(text = prefix + it.text + if (pendingDot) "." else "", isAutocorrect = false) }
                    .toMutableList()
            }
            if (fieldKind == FieldKind.standard) {
                val halves = spaceEscapeHalves(stem)
                if (halves != null) {
                    val escape = engine.dottedSpaceMiss(halves.first, halves.second, if (context.isEmpty()) (carriedContext ?: "") else context)
                    if (escape != null) engineSuggestions.add(0, escape.copy(text = escape.text + if (pendingDot) "." else ""))
                }
            }
        } else if (stem.length >= 2 || Corrector.hasSingleLetterAccentEscape(stem)) {
            val deliberate = longPressedCharacters.filter { stem.lowercase().contains(it) }
            val taps = if (pendingTapRecord.size >= stem.length) pendingTapRecord.take(stem.length) else emptyList()
            engineSuggestions = engine.suggestions(
                context = if (context.isEmpty()) (carriedContext ?: "") else context,
                currentWord = stem,
                limit = limit,
                deliberateCharacters = deliberate,
                taps = taps,
                trace = trace,
            ).map { if (pendingDot) it.copy(text = it.text + ".") else it }.toMutableList()
        }
        if (fieldKind.suppressesAutocorrect) engineSuggestions.removeAll { it.isRestoration }
        if (fieldKind.suppressesAutocorrect || verbatimChoice == currentWord || verbatimChoice == stem) {
            engineSuggestions = engineSuggestions.map { if (it.isAutocorrect) it.copy(isAutocorrect = false) else it }.toMutableList()
        }
        engineSuggestions = engineSuggestions.map { if (!it.isVerbatim && engine.isPersonalLearnedWord(it.text)) it.markingPersonalLearned() else it }.toMutableList()
        val memo = backspaceRevert
        if (memo != null && memo.corrected == currentWord) {
            literalSlotShowing = true
            val bar = mutableListOf(Suggestion(memo.literal, false, 0.0, true))
            bar += engineSuggestions.filter { it.text != memo.literal }
            return bar.take(limit)
        }
        val bar = mutableListOf<Suggestion>()
        if (engineSuggestions.firstOrNull()?.text != currentWord) bar += Suggestion(currentWord, false, 0.0, true)
        bar += engineSuggestions
        return bar.take(limit)
    }

    private sealed interface WindowChange {
        data class Evolution(val appendedAfterContext: String) : WindowChange
        object TruncationReset : WindowChange
        object External : WindowChange
    }

    private fun classifyChange(window: String): WindowChange {
        return when (ledger.explain(window, lastObservedWindow)) {
            ExpectedEditLedger.Explanation.unexplained -> WindowChange.External
            ExpectedEditLedger.Explanation.stale -> WindowChange.Evolution("")
            ExpectedEditLedger.Explanation.matched -> heuristicChange(window).let { if (it == WindowChange.External) WindowChange.External else it }
            ExpectedEditLedger.Explanation.noRecords -> if (ledgerRecordsSelfEdits && lastObservedWindow != null && window != lastObservedWindow) WindowChange.External else heuristicChange(window)
        }
    }

    private fun heuristicChange(window: String): WindowChange {
        val previous = lastSeenWindow ?: return WindowChange.External
        if (window == previous) return WindowChange.Evolution("")
        val previousContext = splitCurrentWord(previous).context
        if (previous.startsWith(window)) {
            if (window.isEmpty() && endsWithSentenceTerminator(previous) && (lastCommittedWord != null || previousCurrentWord.isNotEmpty())) return WindowChange.TruncationReset
            return WindowChange.Evolution("")
        }
        if (window.startsWith(previousContext)) return WindowChange.Evolution(window.drop(previousContext.length))
        var index = 1
        while (index < previous.length) {
            val candidate = previous.substring(index)
            if (window.startsWith(candidate)) {
                val appended = window.length - candidate.length
                if (appended <= 4) {
                    val context = splitCurrentWord(candidate).context
                    return WindowChange.Evolution(window.drop(context.length))
                }
                break
            }
            index++
        }
        return WindowChange.External
    }

    private fun confirmIfCommitted(context: String, currentWord: String, appendedAfterContext: String) {
        if (currentWord.isNotEmpty() || previousCurrentWord.isEmpty() || appendedAfterContext.isEmpty()) return
        val boundary = containsSentenceBoundary(appendedAfterContext)
        val tokens = wordTokens(appendedAfterContext)
        if (tokens.size > 1) {
            val joined = tokens.joinToString(" ")
            if (lastEmittedSuggestionTexts.none { it == joined || it == "$joined." }) return
            tokens.forEachIndexed { i, token -> confirm(token, boundary && i == tokens.lastIndex) }
            return
        }
        val committed = lastWord(context) ?: return
        val typed = strippedEventToken(previousCurrentWord)
        val accepted = committed != previousCurrentWord && committed != typed && lastEmittedSuggestionTexts.contains(committed)
        val revert = if (accepted && committed == lastEmittedAutocorrect) previousCurrentWord else null
        confirm(committed, boundary, if (accepted) typed else null, revert)
    }

    private fun confirmPendingWordAfterTruncationReset() {
        if (previousCurrentWord.isEmpty()) { carriedContext = lastCommittedWord; return }
        val token = lastEmittedAutocorrect ?: previousCurrentWord
        val stem = if (token.endsWith('.')) token.dropLast(1) else token
        val words = wordTokens(stem)
        if (words.isEmpty()) { carriedContext = lastCommittedWord; return }
        val typed = strippedEventToken(previousCurrentWord)
        if (words.size == 1 && lastEmittedAutocorrect != null && words[0] != typed) confirm(words[0], true, typed, previousCurrentWord)
        else words.forEachIndexed { i, word -> confirm(word, i == words.lastIndex) }
        carriedContext = words.last()
    }

    private fun armPunctuationAttachmentIfAny(window: String, currentWord: String, appended: String) {
        if (currentWord.isEmpty() && appended == "." && window.endsWith(" .") && window.dropLast(2).lastOrNull()?.let { isWordable(it) } == true) punctuationAttachmentArmed = true
    }

    private fun confirm(committed: String, sentenceBoundary: Boolean, acceptedFromTyped: String? = null, revertLiteral: String? = null) {
        val before = engine.probabilityIcelandic
        engine.confirmWord(committed)
        committedWordCount++
        lastCommittedWord = committed
        verbatimChoice = null
        if (revertLiteral != null && revertLiteral != committed) {
            backspaceRevert = BackspaceRevert(revertLiteral, committed)
            backspaceRevertJustArmed = true
        }
        if (engine.probabilityIcelandic != before) posteriorUpdateCount++
        bufferCommitEvent(committed, acceptedFromTyped)
        if (sentenceBoundary) engine.noteSentenceBoundary()
        previousCommittedForEvents = if (sentenceBoundary) null else committed
    }

    private fun bufferCommitEvent(committed: String, acceptedFromTyped: String?) {
        if (!fieldKind.allowsLearning) return
        val word = strippedEventToken(committed)
        if (!isEventWord(word)) return
        val sentenceInitial = previousCommittedForEvents == null
        fun neutralized(token: String): String = if (sentenceInitial) engine.autocapArtifactLowercased(token) ?: token else token
        if (acceptedFromTyped != null && acceptedFromTyped != word && isEventWord(acceptedFromTyped)) {
            pendingEvents += LearningEvent.suggestionAccepted(neutralized(acceptedFromTyped), neutralized(word))
        } else if (word == tapLearnedWord) {
            tapLearnedWord = null
            bufferTouchSamples(word)
        } else {
            val previous = previousCommittedForEvents?.let { strippedEventToken(it) }?.takeIf { isEventWord(it) }
            pendingEvents += LearningEvent.wordCommitted(neutralized(word), previous, languageHint(word))
            bufferTouchSamples(word)
        }
    }

    private fun bufferTouchSamples(word: String) {
        if (pendingTapRecord.isEmpty()) return
        val typed = strippedEventToken(previousCurrentWord).lowercase().toList()
        if (typed.isEmpty() || typed != word.lowercase().toList() || pendingTapRecord.size < typed.size) return
        pendingTapRecord.take(typed.size).forEachIndexed { i, tap ->
            tap?.takeIf { it.char == typed[i] }?.let {
                pendingEvents += LearningEvent.touchSample(it.char, it.dxNorm, it.dyNorm)
            }
        }
        pendingTapRecord.clear()
    }

    private fun languageHint(word: String): LanguageHint {
        val evidence = engine.laneDiagnostics(word).evidence
        return when { evidence > 0 -> LanguageHint.icelandic; evidence < 0 -> LanguageHint.english; else -> LanguageHint.unknown }
    }

    private fun noteDotReplacementIfAny(currentWord: String) {
        if (!currentWord.endsWith('.') || previousCurrentWord.isEmpty() || currentWord == previousCurrentWord || currentWord == "$previousCurrentWord.") return
        val stem = currentWord.dropLast(1)
        if (stem == lastEmittedAutocorrect) dotReplacement = DotReplacement("$previousCurrentWord.", currentWord)
    }

    companion object {
        private const val incomingTapQueueLimit = 8
        private val delimiterPunctuation = ".,:;!¡?¿()[]{}<>«»་།\u200B".toSet()
        val knownTLDs = setOf("is", "com", "net", "org", "io", "app", "dev", "co", "uk", "de", "dk", "no", "se", "fi", "fo", "gl", "eu", "us", "edu", "gov", "info", "me", "tv", "ai", "to", "fm", "gg", "xyz")

        fun isDelimiter(character: Char): Boolean = character.isWhitespace() || character == '\n' || delimiterPunctuation.contains(character)
        private fun isWordable(character: Char): Boolean = character.isLetter() || character.isDigit()

        fun isDelimiter(at: Int, `in`: String): Boolean {
            val character = `in`[at]
            if (!isDelimiter(character)) return false
            if (character != '.') return true
            if (at == 0 || !isWordable(`in`[at - 1])) return true
            if (at + 1 == `in`.length) return false
            return !isWordable(`in`[at + 1])
        }

        fun isVerbatimClassToken(token: String): Boolean {
            for (index in token.indices) {
                val ch = token[index]
                if ((ch == '.' || ch == '@') && index > 0 && isWordable(token[index - 1]) && index + 1 < token.length && isWordable(token[index + 1])) return true
            }
            return false
        }

        fun spaceEscapeHalves(token: String): Pair<String, String>? {
            if ('@' in token) return null
            val parts = token.split('.', limit = 3)
            if (parts.size != 2 || parts.any { it.isEmpty() }) return null
            val (left, right) = parts
            if (!left.all { it.isLetter() } || !right.all { it.isLetter() } || left.lowercase() == "www" || knownTLDs.contains(right.lowercase())) return null
            return left to right
        }

        fun trailingSegment(token: String): String {
            val index = maxOf(token.lastIndexOf('.'), token.lastIndexOf('@'))
            return if (index < 0) token else token.substring(index + 1)
        }

        fun splitCurrentWord(textBeforeCursor: String): SplitCurrentWord {
            var start = textBeforeCursor.length
            while (start > 0 && !isDelimiter(start - 1, textBeforeCursor)) start--
            return SplitCurrentWord(textBeforeCursor.substring(0, start), textBeforeCursor.substring(start))
        }

        fun wordTokens(text: String): List<String> {
            val tokens = mutableListOf<String>(); var current = StringBuilder()
            for (index in text.indices) {
                if (isDelimiter(index, text)) { if (current.isNotEmpty()) { tokens += current.toString(); current = StringBuilder() } }
                else current.append(text[index])
            }
            if (current.isNotEmpty()) tokens += current.toString()
            return tokens
        }

        fun lastWord(text: String): String? = wordTokens(text).lastOrNull()
        fun isEventWord(word: String): Boolean = EventLog.isLearnableWord(word) && !isVerbatimClassToken(word)
        fun strippedEventToken(token: String): String = if (token.endsWith('.')) token.dropLast(1) else token
        private fun isSentenceTerminator(character: Char): Boolean = character == '.' || character == '!' || character == '?'
        private fun endsWithSentenceTerminator(text: String): Boolean = text.trimEnd().lastOrNull()?.let { isSentenceTerminator(it) } == true
        private fun containsSentenceBoundary(text: String): Boolean = text.indices.any { text[it] == '!' || text[it] == '?' || (text[it] == '.' && isDelimiter(it, text)) }
    }
}
