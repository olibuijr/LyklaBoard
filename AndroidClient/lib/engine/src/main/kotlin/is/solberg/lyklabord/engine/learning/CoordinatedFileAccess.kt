package `is`.solberg.lyklabord.engine.learning

import java.io.File
import java.io.RandomAccessFile

/** Cross-process coordination using a sibling lock file and java.nio FileLock. */
object CoordinatedFileAccess {
    fun <T> coordinateRead(at: File, byAccessor: (File) -> T): T = withLock(at, shared = true, byAccessor)
    fun <T> coordinateWrite(at: File, byAccessor: (File) -> T): T = withLock(at, shared = false, byAccessor)

    private fun <T> withLock(file: File, shared: Boolean, accessor: (File) -> T): T {
        file.parentFile?.mkdirs()
        val lockFile = File(file.parentFile ?: File("."), ".${file.name}.lock")
        return RandomAccessFile(lockFile, "rw").use { raf ->
            raf.channel.lock(0L, Long.MAX_VALUE, shared).use { accessor(file) }
        }
    }
}
