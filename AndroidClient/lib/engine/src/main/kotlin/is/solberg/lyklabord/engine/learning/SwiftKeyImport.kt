package `is`.solberg.lyklabord.engine.learning

import java.io.File
import java.text.Normalizer

object SwiftKeyImport {
    data class Summary(var imported: Int, var skippedInvalid: Int, var skippedTombstoned: Int)
    data class ParseResult(val words: List<String>, val skipped: Int)

    fun parseVocabulary(text: String): ParseResult {
        val seen = linkedSetOf<String>()
        val words = mutableListOf<String>()
        var skipped = 0
        text.split("\n", limit = Int.MAX_VALUE).forEach { raw ->
            var line = raw.trim()
            if (line.isEmpty()) return@forEach
            if (line.startsWith('#')) {
                val stripped = line.drop(1)
                if (stripped.isEmpty() || stripped.startsWith(' ')) return@forEach
                line = stripped
            }
            line = Normalizer.normalize(line.replace('\u2019', '\''), Normalizer.Form.NFC)
            if (!isImportableWord(line)) { skipped++; return@forEach }
            if (seen.add(line)) words += line
        }
        return ParseResult(words, skipped)
    }

    fun parseVocabulary(at: File): ParseResult = parseVocabulary(at.readText(Charsets.UTF_8))

    fun isImportableWord(word: String): Boolean {
        if (word.codePointCount(0, word.length) < 2 || !EventLog.isLearnableWord(word)) return false
        val cps = word.codePoints().toArray()
        if (!Character.isLetter(cps.first()) || !Character.isLetter(cps.last())) return false
        return cps.all { Character.isLetter(it) || it == '\''.code || it == '-'.code }
    }
}

fun PersonalModel.importLearnedWords(candidates: List<String>, seedCount: UInt = 3u): SwiftKeyImport.Summary {
    val summary = SwiftKeyImport.Summary(0, 0, 0)
    candidates.forEach { word ->
        if (!SwiftKeyImport.isImportableWord(word)) { summary.skippedInvalid++; return@forEach }
        if (isTombstoned(word)) { summary.skippedTombstoned++; return@forEach }
        upsertExplicitEntry(word, seedCount)
        summary.imported++
    }
    return summary
}
