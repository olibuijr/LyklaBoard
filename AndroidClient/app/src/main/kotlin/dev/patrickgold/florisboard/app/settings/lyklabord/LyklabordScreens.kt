/*
 * Copyright (C) 2026 The Lyklaborð Contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package dev.patrickgold.florisboard.app.settings.lyklabord

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Policy
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.RadioButton
import dev.patrickgold.florisboard.ime.voice.ElevenLabsClient
import androidx.core.content.ContextCompat
import dev.patrickgold.florisboard.BuildConfig
import dev.patrickgold.florisboard.R
import dev.patrickgold.florisboard.app.settings.advanced.RadioListItem
import dev.patrickgold.florisboard.ime.keyboard.SpacebarMode
import dev.patrickgold.florisboard.lib.compose.FlorisScreen
import dev.patrickgold.florisboard.lib.util.launchUrl
import dev.patrickgold.florisboard.keyboardManager
import dev.patrickgold.florisboard.nlpManager
import dev.patrickgold.florisboard.app.FlorisPreferenceStore
import dev.patrickgold.jetpref.datastore.model.collectAsState
import dev.patrickgold.jetpref.datastore.ui.Preference
import dev.patrickgold.jetpref.datastore.ui.PreferenceGroup
import dev.patrickgold.jetpref.datastore.ui.SwitchPreference
import dev.patrickgold.jetpref.material.ui.JetPrefAlertDialog
import dev.patrickgold.jetpref.material.ui.JetPrefTextField
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.florisboard.lib.compose.FlorisIconButton
import org.florisboard.lib.compose.stringRes
import `is`.solberg.lyklabord.engine.learning.CoordinatedFileAccess
import `is`.solberg.lyklabord.engine.learning.EventLog
import `is`.solberg.lyklabord.engine.learning.PersonalModel
import `is`.solberg.lyklabord.engine.learning.SwiftKeyImport
import `is`.solberg.lyklabord.engine.learning.exportedJSONData
import `is`.solberg.lyklabord.engine.learning.importLearnedWords

private const val PERSONAL_MODEL_FILENAME = "personal-model.json"
private const val LEARNING_EVENTS_FILENAME = "learning-events.log"
private const val PRIVACY_URL = "https://lyklabord.solberg.is/privacy"
private const val SOURCE_URL = "https://github.com/jokull/LyklabordApp"

private data class UiMessage(val title: String, val body: String)
private data class ImportedModel(
    val model: PersonalModel,
    val parsedSkipped: Int,
    val summary: SwiftKeyImport.Summary,
)

private fun loadModel(file: File): PersonalModel = CoordinatedFileAccess.coordinateRead(file) {
    if (it.exists()) PersonalModel(contentsOf = it) else PersonalModel()
}

private fun updateModel(file: File, mutate: PersonalModel.() -> Unit): PersonalModel =
    CoordinatedFileAccess.coordinateWrite(file) {
        val model = if (it.exists()) PersonalModel(contentsOf = it) else PersonalModel()
        model.mutate()
        model.save(to = it)
        model
    }

@Composable
fun LyklabordDictionaryScreen() = FlorisScreen {
    title = stringRes(R.string.lyklabord__dictionary__title)
    previewFieldVisible = false
    scrollable = false

    val context = LocalContext.current
    val nlpManager by context.nlpManager()
    val scope = rememberCoroutineScope()
    val modelFile = remember(context) { File(context.filesDir, PERSONAL_MODEL_FILENAME) }

    var learnedWords by remember { mutableStateOf(emptyList<String>()) }
    var userAddedWords by remember { mutableStateOf(emptyList<String>()) }
    var search by rememberSaveable { mutableStateOf("") }
    var loading by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var menuExpanded by remember { mutableStateOf(false) }
    var showAddWord by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<UiMessage?>(null) }

    fun display(model: PersonalModel) {
        learnedWords = model.learnedWords
        userAddedWords = model.userAddedWords
    }

    fun mutateModel(successMessage: String, mutate: PersonalModel.() -> Unit) {
        if (busy) return
        busy = true
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { updateModel(modelFile, mutate) }
            }
            result.onSuccess { model ->
                display(model)
                runCatching { nlpManager.refreshLyklabordPersonalModel() }
                message = UiMessage(
                    context.getString(R.string.lyklabord__done),
                    successMessage,
                )
            }.onFailure { error ->
                message = UiMessage(
                    context.getString(R.string.lyklabord__error),
                    error.localizedMessage ?: context.getString(R.string.lyklabord__unknown_error),
                )
            }
            busy = false
        }
    }

    LaunchedEffect(modelFile) {
        val result = withContext(Dispatchers.IO) { runCatching { loadModel(modelFile) } }
        result.onSuccess(::display).onFailure { error ->
            message = UiMessage(
                context.getString(R.string.lyklabord__error),
                error.localizedMessage ?: context.getString(R.string.lyklabord__unknown_error),
            )
        }
        loading = false
    }

    val importVocabulary = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null || busy) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val text = context.contentResolver.openInputStream(uri)
                        ?.bufferedReader()
                        ?.use { it.readText() }
                        ?: error(context.getString(R.string.lyklabord__import__unreadable))
                    val parsed = SwiftKeyImport.parseVocabulary(text)
                    var summary: SwiftKeyImport.Summary? = null
                    val model = updateModel(modelFile) {
                        summary = importLearnedWords(parsed.words)
                    }
                    ImportedModel(model, parsed.skipped, checkNotNull(summary))
                }
            }
            result.onSuccess { imported ->
                display(imported.model)
                runCatching { nlpManager.refreshLyklabordPersonalModel() }
                val invalid = imported.parsedSkipped + imported.summary.skippedInvalid
                message = UiMessage(
                    context.getString(R.string.lyklabord__import__done),
                    context.getString(
                        R.string.lyklabord__import__summary,
                        imported.summary.imported,
                        invalid,
                        imported.summary.skippedTombstoned,
                    ),
                )
            }.onFailure { error ->
                message = UiMessage(
                    context.getString(R.string.lyklabord__import__failed),
                    error.localizedMessage ?: context.getString(R.string.lyklabord__import__unreadable),
                )
            }
            busy = false
        }
    }

    val exportDictionary = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/json"),
    ) { uri ->
        if (uri == null || busy) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val bytes = loadModel(modelFile).exportedJSONData()
                    context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                        ?: error(context.getString(R.string.lyklabord__export__failed))
                }
            }
            message = result.fold(
                onSuccess = {
                    UiMessage(
                        context.getString(R.string.lyklabord__done),
                        context.getString(R.string.lyklabord__export__done),
                    )
                },
                onFailure = { error ->
                    UiMessage(
                        context.getString(R.string.lyklabord__export__failed),
                        error.localizedMessage ?: context.getString(R.string.lyklabord__unknown_error),
                    )
                },
            )
            busy = false
        }
    }

    actions {
        FlorisIconButton(
            onClick = { menuExpanded = true },
            icon = Icons.Default.MoreVert,
        )
        DropdownMenu(
            expanded = menuExpanded,
            onDismissRequest = { menuExpanded = false },
        ) {
            DropdownMenuItem(
                text = { Text(stringRes(R.string.lyklabord__import__action)) },
                enabled = !busy,
                onClick = {
                    menuExpanded = false
                    importVocabulary.launch(arrayOf("text/plain", "text/*"))
                },
            )
            DropdownMenuItem(
                text = { Text(stringRes(R.string.lyklabord__export__action)) },
                enabled = !busy && (learnedWords.isNotEmpty() || userAddedWords.isNotEmpty()),
                onClick = {
                    menuExpanded = false
                    exportDictionary.launch("Lyklabord-ordasafn.json")
                },
            )
        }
    }

    floatingActionButton {
        ExtendedFloatingActionButton(
            onClick = { if (!busy) showAddWord = true },
            icon = { Icon(Icons.Default.Add, contentDescription = null) },
            text = { Text(stringRes(R.string.lyklabord__dictionary__add)) },
        )
    }

    content {
        val filteredLearned = remember(search, learnedWords) {
            if (search.isBlank()) learnedWords else learnedWords.filter { it.contains(search, ignoreCase = true) }
        }
        val filteredUserAdded = remember(search, userAddedWords) {
            if (search.isBlank()) userAddedWords else userAddedWords.filter { it.contains(search, ignoreCase = true) }
        }

        LazyColumn(modifier = Modifier.fillMaxSize()) {
            item {
                OutlinedTextField(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    value = search,
                    onValueChange = { search = it },
                    singleLine = true,
                    label = { Text(stringRes(R.string.lyklabord__dictionary__search)) },
                )
            }
            if (loading) {
                item {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(32.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator()
                    }
                }
            } else {
                if (filteredLearned.isNotEmpty()) {
                    item { DictionarySectionHeader(stringRes(R.string.lyklabord__dictionary__learned), learnedWords.size) }
                    items(filteredLearned, key = { "learned:$it" }) { word ->
                        DictionaryWordRow(word = word, enabled = !busy) {
                            mutateModel(context.getString(R.string.lyklabord__dictionary__deleted, word)) {
                                remove(word)
                            }
                        }
                    }
                }
                if (filteredUserAdded.isNotEmpty()) {
                    item { DictionarySectionHeader(stringRes(R.string.lyklabord__dictionary__mine), userAddedWords.size) }
                    items(filteredUserAdded, key = { "mine:$it" }) { word ->
                        DictionaryWordRow(word = word, enabled = !busy) {
                            mutateModel(context.getString(R.string.lyklabord__dictionary__deleted, word)) {
                                remove(word)
                            }
                        }
                    }
                }
                if (filteredLearned.isEmpty() && filteredUserAdded.isEmpty()) {
                    item {
                        Text(
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 24.dp),
                            text = stringRes(
                                if (search.isBlank()) {
                                    R.string.lyklabord__dictionary__empty
                                } else {
                                    R.string.lyklabord__dictionary__no_results
                                },
                            ),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontStyle = FontStyle.Italic,
                        )
                    }
                }
            }
        }

        if (showAddWord) {
            var word by rememberSaveable { mutableStateOf("") }
            var errorText by remember { mutableStateOf<String?>(null) }
            JetPrefAlertDialog(
                title = stringRes(R.string.lyklabord__dictionary__add),
                confirmLabel = stringRes(R.string.lyklabord__save),
                onConfirm = {
                    val trimmed = word.trim()
                    if (!EventLog.isLearnableWord(trimmed)) {
                        errorText = context.getString(R.string.lyklabord__dictionary__invalid)
                    } else {
                        showAddWord = false
                        mutateModel(context.getString(R.string.lyklabord__dictionary__added, trimmed)) {
                            addUserWord(trimmed)
                        }
                    }
                },
                dismissLabel = stringRes(R.string.lyklabord__cancel),
                onDismiss = { showAddWord = false },
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    JetPrefTextField(
                        value = word,
                        onValueChange = {
                            word = it
                            errorText = null
                        },
                        singleLine = true,
                    )
                    errorText?.let {
                        Text(text = it, color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }

        message?.let { current ->
            JetPrefAlertDialog(
                title = current.title,
                confirmLabel = stringRes(R.string.lyklabord__ok),
                onConfirm = { message = null },
                onDismiss = { message = null },
            ) {
                Text(current.body)
            }
        }
    }
}

@Composable
private fun DictionarySectionHeader(title: String, count: Int) {
    Text(
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 8.dp),
        text = "$title ($count)",
        color = MaterialTheme.colorScheme.primary,
        style = MaterialTheme.typography.titleSmall,
    )
}

@Composable
private fun DictionaryWordRow(word: String, enabled: Boolean, onDelete: () -> Unit) {
    ListItem(
        headlineContent = { Text(word) },
        trailingContent = {
            IconButton(onClick = onDelete, enabled = enabled) {
                Icon(
                    imageVector = Icons.Default.Delete,
                    contentDescription = stringRes(R.string.lyklabord__dictionary__delete),
                )
            }
        },
    )
    HorizontalDivider()
}

@Composable
fun LyklabordSettingsScreen() = FlorisScreen {
    title = stringRes(R.string.lyklabord__settings__title)
    previewFieldVisible = false

    val context = LocalContext.current
    val prefs by FlorisPreferenceStore
    val nlpManager by context.nlpManager()
    val scope = rememberCoroutineScope()
    val modelFile = remember(context) { File(context.filesDir, PERSONAL_MODEL_FILENAME) }
    val eventLogFile = remember(context) { File(context.filesDir, LEARNING_EVENTS_FILENAME) }
    var deleteStep by remember { mutableIntStateOf(0) }
    var deleting by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<UiMessage?>(null) }
    val keyboardManager by context.keyboardManager()
    val apiKey by prefs.voice.elevenLabsApiKey.collectAsState()
    val voiceId by prefs.voice.ttsVoiceId.collectAsState()
    val voiceName by prefs.voice.ttsVoiceName.collectAsState()
    var apiKeyInput by remember { mutableStateOf("") }
    var showApiKeyDialog by remember { mutableStateOf(false) }
    var showVoicePicker by remember { mutableStateOf(false) }
    var voicesLoading by remember { mutableStateOf(false) }
    var voicesError by remember { mutableStateOf<String?>(null) }
    var voices by remember { mutableStateOf<List<ElevenLabsClient.VoiceOption>>(emptyList()) }
    val voicePickerNoneText = stringRes(R.string.lyklabord__voice__none)
    val voicePickerErrorText = stringRes(R.string.lyklabord__voice__load_error)
    var microphonePermissionGranted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    val requestMicrophonePermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        microphonePermissionGranted = granted
    }

    fun loadVoices() {
        if (voicesLoading) return
        voicesLoading = true
        voicesError = null
        scope.launch {
            val keys = ElevenLabsClient.resolveKeys(prefs.voice.elevenLabsApiKey.get())
            ElevenLabsClient.listVoices(keys.first, keys.second)
                .onSuccess { list ->
                    voices = list
                    voicesError = if (list.isEmpty()) voicePickerNoneText else null
                }
                .onFailure { voicesError = voicePickerErrorText }
            voicesLoading = false
        }
    }

    fun deleteAllData() {
        if (deleting) return
        deleting = true
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    CoordinatedFileAccess.coordinateWrite(modelFile) { file ->
                        if (file.exists() && !file.delete()) error("Could not delete ${file.name}")
                    }
                    CoordinatedFileAccess.coordinateWrite(eventLogFile) { file ->
                        if (file.exists() && !file.delete()) error("Could not delete ${file.name}")
                    }
                }
            }
            result.onSuccess {
                runCatching { nlpManager.refreshLyklabordPersonalModel() }
                message = UiMessage(
                    context.getString(R.string.lyklabord__done),
                    context.getString(R.string.lyklabord__delete_all__done),
                )
            }.onFailure { error ->
                message = UiMessage(
                    context.getString(R.string.lyklabord__error),
                    error.localizedMessage ?: context.getString(R.string.lyklabord__unknown_error),
                )
            }
            deleting = false
        }
    }

    content {
        val spacebarMode by prefs.keyboard.spacebarMode.collectAsState()

        PreferenceGroup(title = stringRes(R.string.lyklabord__spacebar__title)) {
            SpacebarMode.entries.forEach { mode ->
                val (titleRes, summaryRes) = when (mode) {
                    SpacebarMode.completeCurrentWord ->
                        R.string.lyklabord__spacebar__complete to R.string.lyklabord__spacebar__complete_summary
                    SpacebarMode.alwaysInsertPrediction ->
                        R.string.lyklabord__spacebar__prediction to R.string.lyklabord__spacebar__prediction_summary
                    SpacebarMode.alwaysInsertSpace ->
                        R.string.lyklabord__spacebar__space to R.string.lyklabord__spacebar__space_summary
                }
                RadioListItem(
                    onClick = { scope.launch { prefs.keyboard.spacebarMode.set(mode) } },
                    selected = spacebarMode == mode,
                    text = stringRes(titleRes),
                    secondaryText = stringRes(summaryRes),
                )
            }
        }
        Text(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            text = stringRes(R.string.lyklabord__spacebar__footer),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
        )

        PreferenceGroup(title = stringRes(R.string.lyklabord__voice__title)) {
            Preference(
                title = stringRes(R.string.lyklabord__voice__api_key),
                summary = if (apiKey.isBlank()) {
                    stringRes(R.string.lyklabord__voice__not_set)
                } else {
                    "\u2022".repeat(12)
                },
                onClick = {
                    apiKeyInput = ""
                    showApiKeyDialog = true
                },
            )
            SwitchPreference(
                prefs.voice.voiceInputEnabled,
                title = stringRes(R.string.lyklabord__voice__dictation),
                summary = stringRes(R.string.lyklabord__voice__dictation_summary),
            )
            Preference(
                title = stringRes(R.string.lyklabord__voice__microphone_permission),
                summary = stringRes(
                    if (microphonePermissionGranted) {
                        R.string.lyklabord__voice__permission_granted
                    } else {
                        R.string.lyklabord__voice__permission_needed
                    },
                ),
                onClick = {
                    if (!microphonePermissionGranted) {
                        requestMicrophonePermission.launch(Manifest.permission.RECORD_AUDIO)
                    }
                },
            )
            SwitchPreference(
                prefs.voice.ttsEnabled,
                title = stringRes(R.string.lyklabord__voice__tts),
                summary = stringRes(R.string.lyklabord__voice__tts_summary),
            )
            Preference(
                title = stringRes(R.string.lyklabord__voice__select_voice),
                summary = voiceName.ifBlank { stringRes(R.string.lyklabord__voice__not_set) },
                onClick = {
                    showVoicePicker = true
                    loadVoices()
                },
            )
            Preference(
                title = stringRes(R.string.lyklabord__voice__speak_sample),
                summary = stringRes(R.string.lyklabord__voice__speak_sample_summary),
                onClick = {
                    keyboardManager.speak("Halló, þetta er Lyklaborð")
                },
            )
        }

        if (showApiKeyDialog) {
            JetPrefAlertDialog(
                title = stringRes(R.string.lyklabord__voice__api_key),
                confirmLabel = stringRes(R.string.lyklabord__save),
                onConfirm = {
                    scope.launch {
                        val entered = apiKeyInput.trim()
                        if (entered.isNotEmpty()) prefs.voice.elevenLabsApiKey.set(entered)
                    }
                    showApiKeyDialog = false
                },
                dismissLabel = stringRes(R.string.lyklabord__cancel),
                onDismiss = { showApiKeyDialog = false },
            ) {
                OutlinedTextField(
                    modifier = Modifier.fillMaxWidth(),
                    value = apiKeyInput,
                    onValueChange = { apiKeyInput = it },
                    label = { Text(stringRes(R.string.lyklabord__voice__api_key)) },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                )
            }
        }

        if (showVoicePicker) {
            JetPrefAlertDialog(
                title = stringRes(R.string.lyklabord__voice__select_voice),
                confirmLabel = stringRes(R.string.lyklabord__voice__refresh),
                onConfirm = { loadVoices() },
                dismissLabel = stringRes(R.string.lyklabord__cancel),
                onDismiss = { showVoicePicker = false },
            ) {
                when {
                    voicesLoading -> {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator()
                            Text(
                                modifier = Modifier.padding(start = 16.dp),
                                text = stringRes(R.string.lyklabord__voice__loading),
                            )
                        }
                    }
                    voicesError != null -> {
                        Text(text = voicesError!!)
                    }
                    else -> {
                        LazyColumn(modifier = Modifier.heightIn(max = 360.dp)) {
                            items(voices) { voice ->
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable {
                                            scope.launch {
                                                prefs.voice.ttsVoiceId.set(voice.id)
                                                prefs.voice.ttsVoiceName.set(voice.name)
                                            }
                                            showVoicePicker = false
                                        }
                                        .padding(vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    RadioButton(selected = voice.id == voiceId, onClick = null)
                                    Column(modifier = Modifier.padding(start = 8.dp)) {
                                        Text(text = voice.name)
                                        if (voice.language != null) {
                                            Text(
                                                text = voice.language,
                                                style = MaterialTheme.typography.bodySmall,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        PreferenceGroup(title = stringRes(R.string.lyklabord__data__title)) {
            Preference(
                icon = Icons.Default.Delete,
                title = stringRes(R.string.lyklabord__delete_all__action),
                summary = stringRes(R.string.lyklabord__delete_all__summary),
                onClick = { if (!deleting) deleteStep = 1 },
            )
        }

        PreferenceGroup(title = stringRes(R.string.lyklabord__about__title)) {
            Preference(
                icon = Icons.Outlined.Info,
                title = stringRes(R.string.lyklabord__version),
                summary = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
            )
            Preference(
                icon = Icons.Outlined.Policy,
                title = stringRes(R.string.lyklabord__privacy),
                summary = stringRes(R.string.lyklabord__privacy__summary),
                onClick = { context.launchUrl(PRIVACY_URL) },
            )
            Preference(
                icon = Icons.Default.Code,
                title = stringRes(R.string.lyklabord__source),
                summary = stringRes(R.string.lyklabord__source__summary),
                onClick = { context.launchUrl(SOURCE_URL) },
            )
        }

        when (deleteStep) {
            1 -> JetPrefAlertDialog(
                title = stringRes(R.string.lyklabord__delete_all__confirm1_title),
                confirmLabel = stringRes(R.string.lyklabord__continue),
                onConfirm = { deleteStep = 2 },
                dismissLabel = stringRes(R.string.lyklabord__cancel),
                onDismiss = { deleteStep = 0 },
            ) {
                Text(stringRes(R.string.lyklabord__delete_all__confirm1_body))
            }
            2 -> JetPrefAlertDialog(
                title = stringRes(R.string.lyklabord__delete_all__confirm2_title),
                confirmLabel = stringRes(R.string.lyklabord__delete_all__confirm2_action),
                onConfirm = {
                    deleteStep = 0
                    deleteAllData()
                },
                dismissLabel = stringRes(R.string.lyklabord__cancel),
                onDismiss = { deleteStep = 0 },
            ) {
                Text(stringRes(R.string.lyklabord__delete_all__confirm2_body))
            }
        }

        message?.let { current ->
            JetPrefAlertDialog(
                title = current.title,
                confirmLabel = stringRes(R.string.lyklabord__ok),
                onConfirm = { message = null },
                onDismiss = { message = null },
            ) {
                Text(current.body)
            }
        }
    }
}
