package dev.patrickgold.florisboard.ime.voice

import android.content.Context
import android.media.MediaPlayer
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Plays one ElevenLabs MP3 at a time and releases the temporary file afterward. */
object TtsPlayer {
    private val lock = Any()
    private var player: MediaPlayer? = null
    private var playerFile: File? = null

    suspend fun play(context: Context, bytes: ByteArray) = withContext(Dispatchers.IO) {
        if (bytes.isEmpty()) return@withContext
        val file = File.createTempFile("lyklabord-tts-", ".mp3", context.cacheDir)
        var nextPlayer: MediaPlayer? = null
        try {
            file.outputStream().use { it.write(bytes) }
            val createdPlayer = MediaPlayer()
            nextPlayer = createdPlayer
            synchronized(lock) {
                stopLocked()
                createdPlayer.setDataSource(file.absolutePath)
                createdPlayer.setOnCompletionListener { completed ->
                    synchronized(lock) {
                        if (player === completed) {
                            player = null
                            playerFile?.delete()
                            playerFile = null
                        }
                    }
                    runCatching { completed.release() }
                }
                createdPlayer.setOnErrorListener { failed, _, _ ->
                    synchronized(lock) {
                        if (player === failed) {
                            player = null
                            playerFile?.delete()
                            playerFile = null
                        }
                    }
                    runCatching { failed.release() }
                    true
                }
                createdPlayer.prepare()
                player = createdPlayer
                playerFile = file
                createdPlayer.start()
            }
        } catch (error: Exception) {
            synchronized(lock) {
                if (player === nextPlayer) {
                    player = null
                    playerFile = null
                }
            }
            runCatching { nextPlayer?.release() }
            runCatching { file.delete() }
            throw error
        }
    }

    fun stop() = synchronized(lock) {
        stopLocked()
    }

    private fun stopLocked() {
        player?.let { active ->
            runCatching {
                if (active.isPlaying) active.stop()
            }
            runCatching { active.release() }
        }
        player = null
        playerFile?.delete()
        playerFile = null
    }
}
