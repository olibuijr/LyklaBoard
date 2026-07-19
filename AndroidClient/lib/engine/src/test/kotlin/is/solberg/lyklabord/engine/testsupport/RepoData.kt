package `is`.solberg.lyklabord.engine.testsupport

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/**
 * Locates the repository `data/` tree from the host JVM test working directory
 * and memory-maps runtime artifacts into little-endian [ByteBuffer]s — the same
 * shape the Android provider produces from `AssetManager.openFd`.
 *
 * The parity harness and reader tests run on the host JVM (no device), so they
 * read the real shipped artifacts straight from the repo checkout.
 */
object RepoData {
    /** Repository root: nearest ancestor of the test working dir containing `data/is/is.lex`. */
    val root: File by lazy {
        // The reference iOS/Swift tree (data/ + scenario suites) is kept out of the
        // distributed repo, under the gitignored .refrepos/lyklabord-ios. Search each
        // ancestor both directly and under that reference path.
        val candidates = listOf("data/is/is.lex", ".refrepos/lyklabord-ios/data/is/is.lex")
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            for (rel in candidates) {
                val marker = File(dir, rel)
                if (marker.isFile) return@lazy marker.parentFile.parentFile.parentFile
            }
            dir = dir.parentFile
        }
        error(
            "Could not locate the reference data/ tree (looked for data/is/is.lex and " +
                ".refrepos/lyklabord-ios/data/is/is.lex) upward from ${System.getProperty("user.dir")}. " +
                "These host-JVM tests require the reference iOS data tree, which is not part of the " +
                "distributed source.",
        )
    }

    fun file(relativePath: String): File = File(root, relativePath)

    /** Memory-map [relativePath] read-only as a little-endian buffer. */
    fun mapLE(relativePath: String): ByteBuffer {
        val f = file(relativePath)
        require(f.isFile) { "Missing data file: ${f.absolutePath}" }
        RandomAccessFile(f, "r").use { raf ->
            val buf = raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, raf.length())
            return buf.order(ByteOrder.LITTLE_ENDIAN)
        }
    }
}
