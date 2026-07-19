package `is`.solberg.lyklabord.engine

/**
 * Headless model of the iOS UITextDocumentProxy contract used by the parity
 * harness. Context before the cursor is truncated, while edits are limited to
 * insertText/deleteBackward at the caret.
 */
class ProxySimulator(
    document: String = "",
    cursorAt: Int? = null,
    truncation: TruncationPolicy = TruncationPolicy(),
) {

    /** Policy used to truncate the text before the cursor. */
    class TruncationPolicy(
        var maxBeforeLength: Int = 200,
        var cutAtSentenceBoundary: Boolean = true,
        var custom: ((String) -> String)? = null,
    ) {
        /** The whole text before the cursor, without truncation. */
        companion object {
            val none: TruncationPolicy
                get() = TruncationPolicy(
                    maxBeforeLength = Int.MAX_VALUE,
                    cutAtSentenceBoundary = false,
                )
        }

        internal fun apply(to: String): String {
            val override = custom
            if (override != null) return override(to)
            var window = to
            if (cutAtSentenceBoundary) {
                window = currentSentence(window)
            }
            return if (window.length > maxBeforeLength) {
                window.takeLast(maxBeforeLength)
            } else {
                window
            }
        }

        /** Text after the most recent terminator or newline. */
        private fun currentSentence(text: String): String {
            var boundary: Int? = null
            var previous: Char? = null
            for (index in text.indices) {
                val ch = text[index]
                if (ch.isNewline()) {
                    boundary = index + 1
                } else if (ch == ' ' && previous != null && previous in ".!?") {
                    boundary = index + 1
                }
                previous = ch
            }
            return boundary?.let { text.substring(it) } ?: text
        }

        private fun Char.isNewline(): Boolean = when (this) {
            '\n', '\r', '\u0085', '\u2028', '\u2029' -> true
            else -> false
        }
    }

    /** A named pair mirroring Swift's `(before: String, after: String)` tuple. */
    data class ContextWindows(val before: String, val after: String)

    /** The full host document. */
    var document: String = document
        private set
    /** Caret offset into [document]. */
    var cursor: Int = minOf(cursorAt ?: document.length, document.length)
        private set

    var truncation: TruncationPolicy = truncation

    /** Return one pre-edit observation after each keyboard edit when enabled. */
    var staleReads: Boolean = false
    private var staleSnapshot: ContextWindows? = null

    /** Restore keyboard edits on the next observation read when enabled. */
    var swallowEdits: Boolean = false
    private var swallowRestore: SwallowRestore? = null

    /** Snapshot captured before a swallowed edit batch. */
    private data class SwallowRestore(val document: String, val cursor: Int)

    /** Truncated analogue of UITextDocumentProxy.documentContextBeforeInput. */
    val contextBeforeInput: String
        get() {
            applySwallowRestoreIfPending()
            takeStaleSnapshotIfPending()?.let { return it.before }
            return truncation.apply(to = fullTextBeforeCursor)
        }

    /** Analogue of UITextDocumentProxy.documentContextAfterInput. */
    val contextAfterInput: String
        get() {
            applySwallowRestoreIfPending()
            takeStaleSnapshotIfPending()?.let { return it.after }
            return fullTextAfterCursor
        }

    /** Read both context windows from one consistent snapshot. */
    fun contextWindows(): ContextWindows {
        applySwallowRestoreIfPending()
        return takeStaleSnapshotIfPending()
            ?: ContextWindows(truncation.apply(to = fullTextBeforeCursor), fullTextAfterCursor)
    }

    /** Ground-truth truncated before-window after the keyboard's own edits. */
    val trueContextBeforeInput: String
        get() = truncation.apply(to = fullTextBeforeCursor)

    fun insertText(text: String) {
        captureStaleSnapshotIfEnabled()
        captureSwallowRestoreIfEnabled()
        val index = characterIndex(at = cursor)
        document = document.substring(0, index) + text + document.substring(index)
        cursor += text.length
    }

    fun deleteBackward() {
        if (cursor <= 0) return
        captureStaleSnapshotIfEnabled()
        captureSwallowRestoreIfEnabled()
        val index = characterIndex(at = cursor - 1)
        document = document.removeRange(index, index + 1)
        cursor -= 1
    }

    /** Move the caret to an absolute offset or by a relative delta. */
    fun moveCursor(to: Int? = null, by: Int? = null) {
        require((to == null) xor (by == null)) { "exactly one cursor movement must be specified" }
        val offset = to ?: (cursor + by!!)
        cursor = minOf(maxOf(offset, 0), document.length)
        staleSnapshot = null
        swallowRestore = null
    }

    /** Replace the host document and optionally choose the new caret offset. */
    fun hostReplaceText(newDocument: String, cursorAt: Int? = null) {
        document = newDocument
        cursor = minOf(cursorAt ?: newDocument.length, newDocument.length)
        staleSnapshot = null
        swallowRestore = null
    }

    private val fullTextBeforeCursor: String
        get() = document.substring(0, cursor)

    private val fullTextAfterCursor: String
        get() = document.substring(cursor)

    private fun characterIndex(at: Int): Int = at

    private fun captureStaleSnapshotIfEnabled() {
        if (!staleReads) return
        staleSnapshot = ContextWindows(
            before = truncation.apply(to = fullTextBeforeCursor),
            after = fullTextAfterCursor,
        )
    }

    private fun captureSwallowRestoreIfEnabled() {
        if (!swallowEdits || swallowRestore != null) return
        swallowRestore = SwallowRestore(document, cursor)
    }

    private fun applySwallowRestoreIfPending() {
        val restore = swallowRestore ?: return
        swallowRestore = null
        document = restore.document
        cursor = restore.cursor
    }

    private fun takeStaleSnapshotIfPending(): ContextWindows? {
        val snapshot = staleSnapshot ?: return null
        staleSnapshot = null
        return snapshot
    }
}
