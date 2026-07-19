package dev.patrickgold.florisboard.ime.voice

import android.net.Uri
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.concurrent.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Minimal ElevenLabs REST client using the Android/JDK HTTP stack. */
object ElevenLabsClient {
    private const val BASE_URL = "https://api.elevenlabs.io/v1"
    private const val MULTIPART_BOUNDARY = "----LyklabordVoiceBoundary"
    private const val CONNECT_TIMEOUT_MS = 15_000
    private const val READ_TIMEOUT_MS = 90_000

    private data class Attempt<T>(val result: Result<T>, val statusCode: Int)

    /**
     * The API key comes solely from the on-device setting the user enters — no
     * key is ever bundled in the app or repository. Returns (primary, fallback);
     * the second slot is unused unless a future build supplies one.
     */
    fun resolveKeys(prefKey: String): Pair<String, String> = prefKey.trim() to ""

    suspend fun transcribe(
        audio: File,
        languageCode: String?,
        primaryKey: String,
        fallbackKey: String,
    ): Result<String> = withContext(Dispatchers.IO) {
        withApiKeys(primaryKey, fallbackKey) { key -> transcribeOnce(audio, languageCode, key) }
    }

    suspend fun synthesize(
        text: String,
        voiceId: String,
        primaryKey: String,
        fallbackKey: String,
        modelId: String = "eleven_multilingual_v2",
    ): Result<ByteArray> = withContext(Dispatchers.IO) {
        withApiKeys(primaryKey, fallbackKey) { key -> synthesizeOnce(text, voiceId, modelId, key) }
    }

    /** A selectable ElevenLabs voice, as shown in the settings picker. */
    data class VoiceOption(val id: String, val name: String, val language: String?)

    /** Fetch the account's current voices (live, so admin changes reflect immediately). */
    suspend fun listVoices(primaryKey: String, fallbackKey: String): Result<List<VoiceOption>> =
        withContext(Dispatchers.IO) {
            withApiKeys(primaryKey, fallbackKey) { key -> listVoicesOnce(key) }
        }

    private fun listVoicesOnce(key: String): Attempt<List<VoiceOption>> {
        val connection = (URL("$BASE_URL/voices").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("xi-api-key", key)
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            useCaches = false
        }
        return try {
            val status = connection.responseCode
            if (status !in 200..299) {
                Attempt(Result.failure(IllegalStateException("ElevenLabs request failed (HTTP $status)")), status)
            } else {
                val json = connection.inputStream.bufferedReader(StandardCharsets.UTF_8).use { it.readText() }
                val arr = JSONObject(json).optJSONArray("voices")
                val out = ArrayList<VoiceOption>()
                if (arr != null) {
                    for (i in 0 until arr.length()) {
                        val v = arr.getJSONObject(i)
                        val id = v.optString("voice_id")
                        if (id.isBlank()) continue
                        val name = v.optString("name").ifBlank { id }
                        val language = v.optJSONObject("labels")?.optString("language")?.takeIf { it.isNotBlank() }
                        out.add(VoiceOption(id, name, language))
                    }
                }
                Attempt(Result.success(out), status)
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun <T> withApiKeys(
        primaryKey: String,
        fallbackKey: String,
        request: (String) -> Attempt<T>,
    ): Result<T> {
        val keys = listOf(primaryKey, fallbackKey).filter(String::isNotBlank).distinct()
        if (keys.isEmpty()) {
            return Result.failure(IllegalStateException("ElevenLabs API key is not configured"))
        }

        var lastAttempt = Attempt(
            Result.failure<T>(IllegalStateException("ElevenLabs request failed")),
            0,
        )
        keys.forEachIndexed { index, key ->
            lastAttempt = try {
                request(key)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                Attempt(Result.failure(IllegalStateException("ElevenLabs request failed", error)), 0)
            }
            if (lastAttempt.result.isSuccess) return lastAttempt.result
            if (index == 0 && lastAttempt.statusCode !in RETRYABLE_STATUS_CODES) return lastAttempt.result
        }
        return lastAttempt.result
    }

    private fun transcribeOnce(audio: File, languageCode: String?, key: String): Attempt<String> {
        if (!audio.isFile) {
            return Attempt(Result.failure(IllegalArgumentException("Voice recording is unavailable")), 0)
        }
        val connection = openConnection("$BASE_URL/speech-to-text", key)
        return try {
            connection.setRequestProperty("Content-Type", "multipart/form-data; boundary=$MULTIPART_BOUNDARY")
            connection.doOutput = true
            connection.outputStream.use { output ->
                writeMultipartField(output, "model_id", "scribe_v1")
                if (!languageCode.isNullOrBlank()) writeMultipartField(output, "language_code", languageCode)
                output.write("--$MULTIPART_BOUNDARY\r\n".toByteArray(StandardCharsets.UTF_8))
                output.write(
                    "Content-Disposition: form-data; name=\"file\"; filename=\"${audio.name}\"\r\n".toByteArray(
                        StandardCharsets.UTF_8,
                    ),
                )
                output.write("Content-Type: audio/mp4\r\n\r\n".toByteArray(StandardCharsets.UTF_8))
                audio.inputStream().use { it.copyTo(output) }
                output.write("\r\n--$MULTIPART_BOUNDARY--\r\n".toByteArray(StandardCharsets.UTF_8))
            }
            val status = connection.responseCode
            if (status !in 200..299) {
                Attempt(Result.failure(IllegalStateException("ElevenLabs request failed (HTTP $status)")), status)
            } else {
                val text = connection.inputStream.bufferedReader(StandardCharsets.UTF_8).use { reader ->
                    JSONObject(reader.readText()).optString("text")
                }
                if (text.isBlank()) {
                    Attempt(Result.failure(IllegalStateException("ElevenLabs returned no transcript")), status)
                } else {
                    Attempt(Result.success(text), status)
                }
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun synthesizeOnce(text: String, voiceId: String, modelId: String, key: String): Attempt<ByteArray> {
        if (text.isBlank()) return Attempt(Result.failure(IllegalArgumentException("Text to speak is empty")), 0)
        if (voiceId.isBlank()) return Attempt(Result.failure(IllegalArgumentException("TTS voice is not configured")), 0)
        val encodedVoiceId = Uri.encode(voiceId)
        val connection = openConnection("$BASE_URL/text-to-speech/$encodedVoiceId", key)
        return try {
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.setRequestProperty("Accept", "audio/mpeg")
            connection.doOutput = true
            val body = JSONObject().apply {
                put("text", text)
                put("model_id", modelId)
            }.toString().toByteArray(StandardCharsets.UTF_8)
            connection.outputStream.use { it.write(body) }
            val status = connection.responseCode
            if (status !in 200..299) {
                Attempt(Result.failure(IllegalStateException("ElevenLabs request failed (HTTP $status)")), status)
            } else {
                Attempt(Result.success(connection.inputStream.use { it.readBytes() }), status)
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun openConnection(endpoint: String, key: String): HttpURLConnection =
        (URL(endpoint).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            setRequestProperty("xi-api-key", key)
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            useCaches = false
        }

    private fun writeMultipartField(output: java.io.OutputStream, name: String, value: String) {
        output.write("--$MULTIPART_BOUNDARY\r\n".toByteArray(StandardCharsets.UTF_8))
        output.write("Content-Disposition: form-data; name=\"$name\"\r\n\r\n".toByteArray(StandardCharsets.UTF_8))
        output.write(value.toByteArray(StandardCharsets.UTF_8))
        output.write("\r\n".toByteArray(StandardCharsets.UTF_8))
    }

    private val RETRYABLE_STATUS_CODES = setOf(401, 403, 429)
}
