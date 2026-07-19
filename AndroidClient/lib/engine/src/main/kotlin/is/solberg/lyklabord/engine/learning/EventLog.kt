package `is`.solberg.lyklabord.engine.learning

import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.Locale
import java.util.UUID

sealed class EventLogError(message: String) : Exception(message) {
    class InvalidContent(detail: String) : EventLogError("Invalid event content: $detail")
    class IoError(detail: String) : EventLogError("Event log I/O error: $detail")
}

/** Append-only, crash-tolerant schema-v1 event log. */
class EventLog(
    val file: File,
    val dayProvider: () -> Int = { DayBucket.current() },
) {
    val url: File get() = file

    data class ConsumedMarker(val generation: UUID, val offset: Long) {
        companion object {
            val none: ConsumedMarker = ConsumedMarker(UUID(0L, 0L), 0L)
        }
    }

    data class ReadResult(val events: List<LoggedEvent>, val endMarker: ConsumedMarker, val skippedLines: Int)

    companion object {
        const val maxWordLength: Int = 64

        fun isLearnableWord(word: String): Boolean {
            val cps = word.codePoints().toArray()
            if (cps.isEmpty() || cps.size > maxWordLength) return false
            var hasLetter = false
            for (cp in cps) {
                if (Character.isWhitespace(cp) || Character.isISOControl(cp)) return false
                if (isEmoji(cp)) return false
                if (Character.isLetter(cp)) hasLetter = true
            }
            return hasLetter
        }

        private fun isEmoji(cp: Int): Boolean =
            cp in 0x1F000..0x1FAFF || cp in 0x2600..0x27BF || cp in 0x2300..0x23FF ||
                cp in 0x00A9..0x00AE || cp == 0x203C || cp == 0x2049 || cp == 0x2122 ||
                cp == 0x2139 || cp in 0x3030..0x303D || cp in 0x3297..0x3299

        internal fun headerLine(generation: UUID): String = "#gen\t$generation\n"

        internal fun parseHeader(bytes: ByteArray): Pair<UUID, Int?> {
            val prefix = "#gen\t".toByteArray(StandardCharsets.UTF_8)
            if (bytes.size < prefix.size || !bytes.copyOfRange(0, prefix.size).contentEquals(prefix)) {
                return ConsumedMarker.none.generation to 0
            }
            val newline = bytes.indexOf(0x0A.toByte())
            if (newline < 0) return ConsumedMarker.none.generation to null
            val uuidText = String(bytes, prefix.size, newline - prefix.size, StandardCharsets.UTF_8)
            val uuid = runCatching { UUID.fromString(uuidText) }.getOrNull() ?: ConsumedMarker.none.generation
            return uuid to (newline + 1)
        }
        private fun nextNewline(bytes: ByteArray, start: Int): Int {
            for (index in start until bytes.size) if (bytes[index] == 0x0A.toByte()) return index
            return -1
        }

        internal fun escape(field: String): String = buildString(field.length) {
            for (ch in field) when (ch) {
                '\\' -> append("\\\\")
                '\t' -> append("\\t")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                else -> append(ch)
            }
        }

        internal fun unescape(field: String): String {
            if (!field.contains('\\')) return field
            val out = StringBuilder(field.length)
            var i = 0
            while (i < field.length) {
                val ch = field[i]
                if (ch == '\\' && i + 1 < field.length) {
                    when (val next = field[i + 1]) {
                        '\\' -> out.append('\\')
                        't' -> out.append('\t')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        else -> { out.append(ch); out.append(next) }
                    }
                    i += 2
                } else { out.append(ch); i++ }
            }
            return out.toString()
        }
    }

    fun append(event: LearningEvent) = append(contentsOf = listOf(event))

    fun append(contentsOf: List<LearningEvent>) {
        if (contentsOf.isEmpty()) return
        val day = dayProvider()
        val payload = buildString { contentsOf.forEach { append(encodeLine(it, day)) } }
        appendRaw(payload)
    }

    fun read(after: ConsumedMarker? = null): ReadResult {
        if (!file.exists()) return ReadResult(emptyList(), ConsumedMarker.none, 0)
        val bytes = try { file.readBytes() } catch (e: Exception) { throw EventLogError.IoError("read failed: $e") }
        val (generation, headerEnd) = parseHeader(bytes)
        val header = headerEnd ?: return ReadResult(emptyList(), ConsumedMarker.none, 0)
        var start = header
        if (after != null && after.generation == generation && after.offset >= header && after.offset <= bytes.size) {
            start = after.offset.toInt()
        }
        val events = mutableListOf<LoggedEvent>()
        var skipped = 0
        var cursor = start
        var consumedEnd = start
        while (cursor < bytes.size) {
            val newline = nextNewline(bytes, cursor)
            if (newline < 0) break
            val line = String(bytes, cursor, newline - cursor, StandardCharsets.UTF_8)
            val decoded = decodeLine(line)
            if (decoded != null) events += decoded else if (line.isNotEmpty()) skipped++
            cursor = newline + 1
            consumedEnd = cursor
        }
        return ReadResult(events, ConsumedMarker(generation, consumedEnd.toLong()), skipped)
    }

    fun truncate(consumedUpTo: ConsumedMarker): ConsumedMarker {
        if (!file.exists()) return consumedUpTo
        val bytes = try { file.readBytes() } catch (e: Exception) { throw EventLogError.IoError("read for truncate failed: $e") }
        val (generation, headerEnd) = parseHeader(bytes)
        if (headerEnd == null || generation != consumedUpTo.generation) return consumedUpTo
        val tailStart = consumedUpTo.offset.coerceIn(0L, bytes.size.toLong()).toInt()
        val newGeneration = UUID.randomUUID()
        val header = headerLine(newGeneration).toByteArray(StandardCharsets.UTF_8)
        val output = ByteArray(header.size + bytes.size - tailStart)
        header.copyInto(output)
        if (tailStart < bytes.size) bytes.copyInto(output, header.size, tailStart)
        atomicWrite(output)
        return ConsumedMarker(newGeneration, header.size.toLong())
    }

    private fun encodeLine(event: LearningEvent, day: Int): String {
        fun validated(word: String, field: String): String {
            if (!isLearnableWord(word)) throw EventLogError.InvalidContent("$field is not a learnable word")
            return escape(word)
        }
        val fields = when (event) {
            is LearningEvent.WordCommitted -> listOf("wc", validated(event.word, "word"),
                if (event.previousWord != null && isLearnableWord(event.previousWord)) escape(event.previousWord) else "",
                event.languageHint.rawValue)
            is LearningEvent.SuggestionAccepted -> listOf("sa", validated(event.typed, "typed"), validated(event.accepted, "accepted"))
            is LearningEvent.CorrectionReverted -> listOf("cr", validated(event.original, "original"), validated(event.applied, "applied"))
            is LearningEvent.WordTapped -> listOf("wt", validated(event.word, "word"))
            is LearningEvent.TouchSample -> listOf("ts", escape(event.keyChar.toString()),
                String.format(Locale.ROOT, "%.4f", event.dx), String.format(Locale.ROOT, "%.4f", event.dy))
        }
        return "1\t$day\t${fields.joinToString("\t")}\n"
    }

    private fun decodeLine(line: String): LoggedEvent? {
        val fields = line.split("\t", ignoreCase = false, limit = Int.MAX_VALUE)
        if (fields.size < 3 || fields[0] != "1") return null
        val day = fields[1].toIntOrNull() ?: return null
        return when (fields[2]) {
            "wc" -> if (fields.size == 6) {
                val word = unescape(fields[3]); val prev = fields[4].takeIf { it.isNotEmpty() }?.let(::unescape)
                val hint = when (fields[5]) { "is" -> LanguageHint.ICELANDIC; "en" -> LanguageHint.ENGLISH; "un" -> LanguageHint.UNKNOWN; else -> return null }
                if (word.isEmpty()) null else LoggedEvent(day, LearningEvent.WordCommitted(word, prev, hint))
            } else null
            "sa" -> if (fields.size == 5) {
                val typed = unescape(fields[3]); val accepted = unescape(fields[4])
                if (typed.isEmpty() || accepted.isEmpty()) null else LoggedEvent(day, LearningEvent.SuggestionAccepted(typed, accepted))
            } else null
            "cr" -> if (fields.size == 5) {
                val original = unescape(fields[3]); val applied = unescape(fields[4])
                if (original.isEmpty() || applied.isEmpty()) null else LoggedEvent(day, LearningEvent.CorrectionReverted(original, applied))
            } else null
            "wt" -> if (fields.size == 4) unescape(fields[3]).takeIf { it.isNotEmpty() }?.let { LoggedEvent(day, LearningEvent.WordTapped(it)) } else null
            "ts" -> if (fields.size == 6) {
                val key = unescape(fields[3]); val dx = fields[4].toDoubleOrNull(); val dy = fields[5].toDoubleOrNull()
                if (key.codePointCount(0, key.length) != 1 || dx == null || dy == null) null
                else LoggedEvent(day, LearningEvent.TouchSample(key[0], dx, dy))
            } else null
            else -> null
        }
    }

    private fun appendRaw(lines: String) {
        file.parentFile?.mkdirs()
        try {
            java.nio.channels.FileChannel.open(file.toPath(), StandardOpenOption.CREATE, StandardOpenOption.WRITE, StandardOpenOption.READ).use { channel ->
                val size = channel.size()
                val prefix = when {
                    size == 0L -> headerLine(UUID.randomUUID())
                    else -> {
                        val one = ByteBuffer.allocate(1)
                        channel.position(size - 1L); channel.read(one); one.flip()
                        if (one.get().toInt() != 0x0A) "\n" else ""
                    }
                }
                val data = (prefix + lines).toByteArray(StandardCharsets.UTF_8)
                channel.position(channel.size())
                var written = 0
                while (written < data.size) written += channel.write(ByteBuffer.wrap(data, written, data.size - written))
            }
        } catch (e: EventLogError) { throw e } catch (e: Exception) { throw EventLogError.IoError("append failed: $e") }
    }

    private fun atomicWrite(bytes: ByteArray) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile ?: File("."), ".${file.name}.${UUID.randomUUID()}.tmp")
        try {
            Files.write(tmp.toPath(), bytes, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)
            try { Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
            catch (_: Exception) { Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING) }
        } catch (e: Exception) { tmp.delete(); throw EventLogError.IoError("truncate rewrite failed: $e") }
    }
}
