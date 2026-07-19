package dev.patrickgold.florisboard.ime.voice

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaRecorder
import androidx.core.content.ContextCompat
import java.io.File

/** Owns the short-lived microphone recording used by voice dictation. */
class VoiceInputManager {
    private val lock = Any()
    private var recorder: MediaRecorder? = null
    private var outputFile: File? = null
    private var recording = false

    val isRecording: Boolean
        get() = synchronized(lock) { recording }

    fun start(context: Context): Boolean = synchronized(lock) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return@synchronized false
        }
        if (recording) return@synchronized true

        val file = File(context.cacheDir, FILE_NAME)
        runCatching { file.delete() }
        val nextRecorder = MediaRecorder()
        return@synchronized try {
            nextRecorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            nextRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            nextRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            nextRecorder.setAudioSamplingRate(SAMPLE_RATE)
            nextRecorder.setAudioEncodingBitRate(BIT_RATE)
            nextRecorder.setOutputFile(file.absolutePath)
            nextRecorder.prepare()
            nextRecorder.start()
            recorder = nextRecorder
            outputFile = file
            recording = true
            true
        } catch (_: Exception) {
            runCatching { nextRecorder.reset() }
            runCatching { nextRecorder.release() }
            false
        }
    }

    fun stop(): File? = synchronized(lock) {
        val activeRecorder = recorder ?: return@synchronized null
        val file = outputFile
        recorder = null
        outputFile = null
        recording = false
        var stopped = false
        try {
            activeRecorder.stop()
            stopped = true
        } catch (_: Exception) {
            runCatching { file?.delete() }
        } finally {
            runCatching { activeRecorder.release() }
        }
        file?.takeIf { stopped && it.isFile && it.length() > 0L }
    }

    private companion object {
        const val FILE_NAME = "lyklabord-voice.m4a"
        const val SAMPLE_RATE = 44_100
        const val BIT_RATE = 128_000
    }
}
