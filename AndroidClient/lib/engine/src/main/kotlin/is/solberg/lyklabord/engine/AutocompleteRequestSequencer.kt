package `is`.solberg.lyklabord.engine

/**
 * Thread-safe monotonic autocomplete request sequencing.
 *
 * A ticket captures the input generation at request time. A result may replace
 * the published suggestion bar only while its request is still current.
 */
class AutocompleteRequestSequencer {

    data class Ticket internal constructor(
        val generation: ULong,
        val text: String,
    )

    private val lock = Any()
    private var generation: ULong = 0uL
    private var latestText = ""

    /** Register a request before it is enqueued on the serial engine queue. */
    fun accept(text: String): Ticket = synchronized(lock) {
        generation += 1uL
        latestText = text
        Ticket(generation = generation, text = text)
    }

    /**
     * Whether [ticket] has been superseded by a newer request for different
     * proxy text and must therefore be delivered as outdated.
     */
    fun isSuperseded(ticket: Ticket): Boolean = synchronized(lock) {
        AutocorrectApplyGuard.isSupersededResult(
            requestGeneration = ticket.generation,
            requestText = ticket.text,
            latestGeneration = generation,
            latestText = latestText,
        )
    }
}
