package `is`.solberg.lyklabord.engine

/**
 * Apply-time staleness guard for delimiter-triggered autocorrect.
 *
 * 1:1 port of Swift `AutocorrectApplyGuard` from
 * `Packages/TypeEngine/Sources/TypeEngine/AutocorrectApplyGuard.swift`.
 */
object AutocorrectApplyGuard {
    /**
     * Whether a delimiter keystroke may auto-apply the armed autocorrect
     * suggestion.
     *
     * A missing or empty stamp fails closed. The live token is extracted with
     * the same position-aware boundary used by the typing session, preserving
     * dotted and deferred-dot tokens.
     */
    fun shouldAutoApply(
        recordedPendingToken: String?,
        textBeforeCursor: String,
    ): Boolean {
        val recorded = recordedPendingToken ?: return false
        if (recorded.isEmpty()) return false
        val live = TypingSession.splitCurrentWord(textBeforeCursor).currentWord
        return recorded == live
    }

    /**
     * Whether a result for an older request with different input should be
     * published as superseded.
     */
    fun isSupersededResult(
        requestGeneration: ULong,
        requestText: String,
        latestGeneration: ULong,
        latestText: String,
    ): Boolean = latestGeneration != requestGeneration && latestText != requestText
}
