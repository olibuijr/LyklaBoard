package `is`.solberg.lyklabord.engine

/**
 * Ledger of proxy edits performed by the keyboard itself, used to distinguish
 * self-edits from external text changes.
 *
 * Faithful port of Swift `ExpectedEditLedger`.
 */
class ExpectedEditLedger {
    /** One self-caused edit and its truncated before-cursor window transform. */
    data class Record(
        val before: String,
        val after: String,
        var unconfirmedObservations: Int = 0,
    )

    /** How the ledger explains one observed window. */
    enum class Explanation {
        noRecords,
        matched,
        stale,
        unexplained,
    }

    /** More unobserved edits than this means observations stopped arriving. */
    companion object {
        const val capacity = 32
        const val expiryObservations = 3
    }

    private val pendingRecords = mutableListOf<Record>()
    val records: List<Record>
        get() = pendingRecords

    /** True when there are no pending records and no condemned chain. */
    val isEmpty: Boolean
        get() = pendingRecords.isEmpty() && !chainBroken

    /** Set when an edit failed to chain onto known reality. */
    private var chainBroken = false

    fun clear() {
        pendingRecords.clear()
        chainBroken = false
    }

    /**
     * Record one expected self-caused edit. [anchor] is the window last
     * observed by the session, or null before the first observation.
     */
    fun record(before: String, after: String, anchor: String?) {
        if (before == after) return
        if (chainBroken) return

        val tail = pendingRecords.lastOrNull()
        if (tail != null) {
            if (before != tail.after) {
                pendingRecords.clear()
                chainBroken = true
                return
            }
        } else if (anchor != null && before != anchor) {
            if (after == anchor) {
                // Retro-confirmed: the observation preceded the record.
                return
            }
            pendingRecords.clear()
            chainBroken = true
            return
        }

        if (pendingRecords.size >= capacity) {
            clear()
            chainBroken = true
            return
        }
        pendingRecords.add(Record(before = before, after = after))
    }

    /** Match one observed window against the pending expectations. */
    fun explain(observed: String, anchor: String?): Explanation {
        if (chainBroken) {
            clear()
            return Explanation.unexplained
        }

        // Records whose outcome the previous observation already saw.
        if (anchor != null) {
            while (pendingRecords.firstOrNull()?.after == anchor) {
                pendingRecords.removeAt(0)
            }
        }

        if (pendingRecords.isEmpty()) return Explanation.noRecords

        // The oldest pending edit must start from the previous observation.
        if (anchor != null && pendingRecords[0].before != anchor) {
            clear()
            return Explanation.unexplained
        }

        // The latest matching occurrence confirms all records through it.
        val index = pendingRecords.indexOfLast { it.after == observed }
        if (index >= 0) {
            pendingRecords.subList(0, index + 1).clear()
            tickExpiry()
            return Explanation.matched
        }

        // The observation still shows the pre-edit state.
        if (pendingRecords[0].before == observed) {
            tickExpiry()
            return Explanation.stale
        }

        clear()
        return Explanation.unexplained
    }

    /**
     * Non-consuming variant of [explain]. Returns whether this observation
     * would be explained by the pending expectations.
     */
    fun wouldExplain(observed: String, anchor: String?): Boolean {
        if (chainBroken) return false

        var start = 0
        if (anchor != null) {
            while (start < pendingRecords.size && pendingRecords[start].after == anchor) {
                start += 1
            }
        }
        if (start >= pendingRecords.size) return false
        if (anchor != null && pendingRecords[start].before != anchor) return false
        if (pendingRecords[start].before == observed) return true
        return pendingRecords.subList(start, pendingRecords.size).any { it.after == observed }
    }

    /** Age surviving records and drop the chain once its oldest expires. */
    private fun tickExpiry() {
        pendingRecords.forEach { it.unconfirmedObservations += 1 }
        val first = pendingRecords.firstOrNull()
        if (first != null && first.unconfirmedObservations >= expiryObservations) {
            clear()
        }
    }
}
