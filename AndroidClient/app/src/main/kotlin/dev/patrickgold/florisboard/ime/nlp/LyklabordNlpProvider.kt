/*
 * Copyright (C) 2025 The Lyklaborð Contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package dev.patrickgold.florisboard.ime.nlp

import android.content.Context
import dev.patrickgold.florisboard.appContext
import dev.patrickgold.florisboard.ime.core.Subtype
import dev.patrickgold.florisboard.ime.editor.EditorContent
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.util.concurrent.Executors
import `is`.solberg.lyklabord.engine.FieldKind
import `is`.solberg.lyklabord.engine.PersonalSnapshot
import `is`.solberg.lyklabord.engine.TypeEngine
import `is`.solberg.lyklabord.engine.TypingSession
import `is`.solberg.lyklabord.engine.learning.EventLog
import `is`.solberg.lyklabord.engine.learning.LearningEvent
import `is`.solberg.lyklabord.engine.learning.PersonalModel
import `is`.solberg.lyklabord.engine.lexicon.FrequencyLexicon
import `is`.solberg.lyklabord.engine.lexicon.LexiconCalibrationProfile
import `is`.solberg.lyklabord.engine.morph.BinaryLemmatizer
/**
 * FlorisBoard NLP provider backed by the Lyklaborð Icelandic/English engine.
 *
 * Must live in [dev.patrickgold.florisboard.ime.nlp] because [NlpProvider] is a
 * sealed interface in this package; it delegates all linguistics into
 * `is.solberg.lyklabord.engine`.
 *
 * Phase 2: full noisy-channel autocorrect + completion + next-word prediction,
 * driven through a stateful [TypingSession]. FlorisBoard supplies the pre-cursor
 * window on every content change; the session parses it (its own iOS-style
 * ProxySimulator + edit-ledger contract), returns the verbatim slot + ranked
 * candidates, and flags the autocorrect winner. FlorisBoard auto-commits the
 * first [WordSuggestionCandidate.isEligibleForAutoCommit] candidate on a
 * delimiter. Every engine call runs on one dedicated serial dispatcher — the
 * engine is not thread-safe and requires a single owner.
 */
class LyklabordNlpProvider(context: Context) : SpellingProvider, SuggestionProvider {
    companion object {
        const val ProviderId = "is.solberg.lyklabord.nlp"

        private const val ASSET_DIR = "lyklabord"
        private const val PERSONAL_MODEL_NAME = "personal-model.json"
        private const val LEARNING_LOG_NAME = "learning-events.log"
        private const val COMPACTION_DRAIN_INTERVAL = 32
    }

    private val appContext by context.appContext()

    /** Single serial owner of the (non-thread-safe) engine. */
    private val engineDispatcher: CoroutineDispatcher =
        Executors.newSingleThreadExecutor { r -> Thread(r, "lyklabord-engine") }.asCoroutineDispatcher()
    private val engineScope = CoroutineScope(SupervisorJob() + engineDispatcher)

    private val loadMutex = Mutex()
    private var engine: TypeEngine? = null
    private var session: TypingSession? = null
    private var icelandic: FrequencyLexicon? = null
    private var english: FrequencyLexicon? = null
    private var morphology: BinaryLemmatizer? = null
    private var personalModel: PersonalModel? = null
    private var learningLog: EventLog? = null
    private var personalModelFile: File? = null
    private var pendingLearningEvents = mutableListOf<LearningEvent>()
    private var drainsSinceCompaction = 0
    private var compactionJob: Job? = null

    override val providerId = ProviderId

    override suspend fun create() {
        // No language-independent setup required.
    }

    override suspend fun preload(subtype: Subtype) {
        loadMutex.withLock {
            if (engine != null) return
            withContext(engineDispatcher) {
                val ice = FrequencyLexicon(mapAsset("$ASSET_DIR/is.lex"))
                val eng = FrequencyLexicon(mapAsset("$ASSET_DIR/en.lex"))
                val morph = BinaryLemmatizer(mapAsset("$ASSET_DIR/bin-morph.core.bin"))
                val built = TypeEngine(
                    icelandic = ice,
                    english = eng,
                    morphologyProvider = morph,
                    icelandicCalibration = readCalibration("$ASSET_DIR/is-calibration.json"),
                    englishCalibration = readCalibration("$ASSET_DIR/en-calibration.json"),
                )
                val modelFile = File(appContext.filesDir, PERSONAL_MODEL_NAME)
                val model = loadPersonalModel(modelFile)
                val log = EventLog(File(appContext.filesDir, LEARNING_LOG_NAME))
                // Replay any crash-surviving events before the first suggestion pass.
                runCatching { model.compactAndSave(applying = log, to = modelFile) }
                built.setPersonalVocabulary(PersonalSnapshot(model))
                icelandic = ice
                english = eng
                morphology = morph
                personalModelFile = modelFile
                personalModel = model
                learningLog = log
                pendingLearningEvents.clear()
                drainsSinceCompaction = 0
                engine = built
                session = built.makeSession()
            }
        }
    }

    /** Reload a dictionary edit/import made by the app and refresh the live engine snapshot. */
    suspend fun refreshPersonalModel() {
        loadMutex.withLock {
            withContext(engineDispatcher) {
                val modelFile = personalModelFile ?: File(appContext.filesDir, PERSONAL_MODEL_NAME)
                val model = loadPersonalModel(modelFile)
                personalModelFile = modelFile
                personalModel = model
                engine?.setPersonalVocabulary(PersonalSnapshot(model))
            }
        }
    }

    override suspend fun suggest(
        subtype: Subtype,
        content: EditorContent,
        maxCandidateCount: Int,
        allowPossiblyOffensive: Boolean,
        isPrivateSession: Boolean,
    ): List<SuggestionCandidate> {
        val suggestions = withContext(engineDispatcher) {
            val activeSession = session ?: return@withContext emptyList()
            activeSession.fieldKind = if (isPrivateSession) FieldKind.secure else FieldKind.standard
            val result = activeSession.suggestions(
                `for` = content.textBeforeSelection,
                limit = maxCandidateCount,
                trace = null,
            )
            drainLearningEvents(activeSession, allowLearning = !isPrivateSession)
            result
        }
        return suggestions.map { s ->
            WordSuggestionCandidate(
                text = s.text,
                secondaryText = null,
                confidence = s.confidence,
                // FlorisBoard auto-commits the first eligible candidate on a
                // delimiter; only the engine's autocorrect winner is eligible.
                isEligibleForAutoCommit = s.isAutocorrect,
                sourceProvider = this,
            )
        }
    }

    override suspend fun spell(
        subtype: Subtype,
        word: String,
        precedingWords: List<String>,
        followingWords: List<String>,
        maxSuggestionCount: Int,
        allowPossiblyOffensive: Boolean,
        isPrivateSession: Boolean,
    ): SpellingResult {
        val ice = icelandic ?: return SpellingResult.unspecified()
        val eng = english
        val morph = morphology
        val known = withContext(engineDispatcher) {
            ice.frequency(word) != null || eng?.frequency(word) != null || morph?.isKnown(word) == true
        }
        if (known) return SpellingResult.validWord()
        val suggestions = withContext(engineDispatcher) {
            ice.completions(word.lowercase(), maxSuggestionCount)
        }
        if (suggestions.isEmpty()) return SpellingResult.unspecified()
        return SpellingResult.typo(suggestions.map { it.word }.toTypedArray())
    }

    override suspend fun notifySuggestionAccepted(subtype: Subtype, candidate: SuggestionCandidate) {
        withContext(engineDispatcher) {
            session?.let { drainLearningEvents(it, allowLearning = it.fieldKind.allowsLearning) }
        }
    }

    override suspend fun notifySuggestionReverted(subtype: Subtype, candidate: SuggestionCandidate) {
        withContext(engineDispatcher) {
            session?.let { drainLearningEvents(it, allowLearning = it.fieldKind.allowsLearning) }
        }
    }

    override suspend fun removeSuggestion(subtype: Subtype, candidate: SuggestionCandidate): Boolean = false

    override suspend fun getListOfWords(subtype: Subtype): List<String> = emptyList()

    override suspend fun getFrequencyForWord(subtype: Subtype, word: String): Double {
        val ice = icelandic ?: return 0.0
        val total = ice.totalUnigramTokens
        if (total == 0uL) return 0.0
        val f = ice.frequency(word) ?: return 0.0
        return f.toDouble() / total.toDouble()
    }

    override suspend fun destroy() {
        withContext(engineDispatcher) {
            session?.let { drainLearningEvents(it, allowLearning = it.fieldKind.allowsLearning) }
            compactAndInjectPersonalModel()
            compactionJob?.cancel()
            compactionJob = null
            engine = null
            session = null
            icelandic = null
            english = null
            morphology = null
            personalModel = null
            learningLog = null
            personalModelFile = null
            pendingLearningEvents.clear()
            drainsSinceCompaction = 0
        }
    }

    private fun loadPersonalModel(file: File): PersonalModel =
        if (!file.isFile) PersonalModel()
        else runCatching { PersonalModel(contentsOf = file) }.getOrElse { PersonalModel() }

    /**
     * Drain only at word-boundary/callback points. Appending is cheap; compaction
     * is queued separately so it never delays the suggestion result.
     */
    private fun drainLearningEvents(activeSession: TypingSession, allowLearning: Boolean) {
        val events = activeSession.drainLearningEvents()
        if (!allowLearning || events.isEmpty()) return
        pendingLearningEvents += events
        val log = learningLog ?: return
        try {
            log.append(contentsOf = pendingLearningEvents)
            pendingLearningEvents.clear()
        } catch (_: Exception) {
            return
        }
        if (++drainsSinceCompaction < COMPACTION_DRAIN_INTERVAL) return
        drainsSinceCompaction = 0
        if (compactionJob?.isActive == true) return
        compactionJob = engineScope.launch { compactAndInjectPersonalModel() }
    }

    private fun compactAndInjectPersonalModel() {
        val log = learningLog ?: return
        val modelFile = personalModelFile ?: return
        try {
            // Reload first so dictionary-editor writes cannot be overwritten by
            // a queued compaction from an earlier typing pass.
            val model = loadPersonalModel(modelFile)
            model.compactAndSave(applying = log, to = modelFile)
            personalModel = model
            engine?.setPersonalVocabulary(PersonalSnapshot(model))
        } catch (_: Exception) {
            // Keep the append-only log intact; retry on a later compaction/destroy.
        }
    }

    private fun readCalibration(path: String): LexiconCalibrationProfile? =
        runCatching {
            appContext.assets.open(path).use { LexiconCalibrationProfile.fromJson(it.readBytes().decodeToString()) }
        }.getOrNull()

    /** Memory-map an uncompressed asset region into a little-endian buffer. */
    private fun mapAsset(path: String): ByteBuffer {
        appContext.assets.openFd(path).use { afd ->
            FileInputStream(afd.fileDescriptor).use { fis ->
                val channel: FileChannel = fis.channel
                val buffer = channel.map(FileChannel.MapMode.READ_ONLY, afd.startOffset, afd.declaredLength)
                return buffer.order(ByteOrder.LITTLE_ENDIAN)
            }
        }
    }
}
