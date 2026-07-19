package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfig
import `is`.solberg.lyklabord.engine.lexicon.LexiconPrefixCursor
import `is`.solberg.lyklabord.engine.lexicon.PrefixSearchableLexicon

/** Per-position character-level likelihood seam for beam decoding. */
interface PositionCostProvider {
    /** -log P(typed | intended), in nats; zero when the characters match. */
    fun substitutionCost(position: Int, typed: Char, intended: Char): Double

    /** Confidence that the tap at [position] selected its resolved character. */
    fun confidence(position: Int): Double

    /** Whether [position] has usable per-tap evidence. */
    fun hasTap(position: Int): Boolean = false
}

/** Static key-center provider: no per-tap evidence, confidence is always one. */
class StaticSpatialCostProvider(
    val spatial: SpatialModel,
) : PositionCostProvider {
    override fun substitutionCost(position: Int, typed: Char, intended: Char): Double =
        spatial.substitutionCost(typed, intended)

    override fun confidence(position: Int): Double = 1.0
}

/** A word and its beam-search channel cost, emitted cheapest first. */
data class BeamCandidate(val word: String, val cost: Double)

/**
 * Spatial lexicon beam search. The search walks typed characters and a lexicon
 * prefix cursor in lockstep, visiting only prefixes present in the lexicon.
 */
class BeamDecoder(
    val config: EngineConfig,
    spatial: SpatialModel,
) {
    private data class AlphabetEntry(val char: Char, val bytes: ByteArray)

    /** Full candidate alphabet used for first substitutions and insertions. */
    private val alphabet: List<AlphabetEntry> = candidateAlphabet.map {
        AlphabetEntry(it, it.toString().toByteArray(Charsets.UTF_8))
    }

    /** Cheap static neighbors used for subsequent substitutions. */
    private val cheapNeighbors: Map<Char, List<AlphabetEntry>> =
        candidateAlphabet.associateWith { typed ->
            alphabet.filter { entry ->
                entry.char != typed &&
                    spatial.substitutionCost(typed, entry.char) <= config.beamNeighborMaxCost
            }
        }

    private data class ShallowKey(
        val lexicon: Int,
        val lowerBound: Int,
        val byteDepth: Int,
        val char: Char,
    )

    private val shallowCache = HashMap<ShallowKey, LexiconPrefixCursor>()

    private data class State(
        val cursor: LexiconPrefixCursor,
        val consumed: Int,
        val cost: Double,
        val edits: Int,
    )

    private data class VisitKey(
        val lowerBound: Int,
        val byteDepth: Int,
        val consumed: Int,
    )

    /** Decode [typed] against one lexicon, up to the configured candidate cap. */
    fun decode(
        typed: List<Char>,
        lexicon: PrefixSearchableLexicon,
        lexiconIndex: Int,
        costs: PositionCostProvider,
        pricing: FoldPricing,
        maxEdits: Int,
        multiEditCostCap: Double? = null,
    ): List<BeamCandidate> {
        val n = typed.size
        if (n == 0 || maxEdits < 0) return emptyList()

        val costCap = config.beamCostCap
        val insertionCost = config.spatialCosts.deletion
        val deletionCost = config.spatialCosts.insertion
        val transpositionCost = config.spatialCosts.transposition
        val typedBytes = typed.map { it.toString().toByteArray(Charsets.UTF_8) }
        val foldPenaltyCap = config.tapFoldConfidenceMaxPenalty

        fun substitutionPrice(position: Int, typedChar: Char, intended: Char): Double {
            val base = costs.substitutionCost(position, typedChar, intended)
            val lane = pricing.substitutionPrice(typedChar, intended, confusionBase = base)
                ?: return base
            val evidence = costs.foldEvidencePenalty(position, foldPenaltyCap)
            return minOf(lane + evidence, base)
        }

        fun descend(
            cursor: LexiconPrefixCursor,
            char: Char,
            bytes: ByteArray,
        ): LexiconPrefixCursor {
            if (cursor.byteDepth > 2 || cursor.isEmpty) {
                return lexicon.descend(cursor, bytes)
            }
            val key = ShallowKey(lexiconIndex, cursor.lowerBound, cursor.byteDepth, char)
            shallowCache[key]?.let { return it }
            val result = lexicon.descend(cursor, bytes)
            shallowCache[key] = result
            return result
        }

        val startNanos = System.nanoTime()
        val heap = StateHeap()
        val visited = HashMap<VisitKey, Double>()
        val results = ArrayList<BeamCandidate>()
        val emitted = HashSet<String>()
        val multiEditCap = minOf(costCap, multiEditCostCap ?: config.beamMultiEditCostCap)

        fun push(state: State) {
            val cap = if (state.edits >= 2) multiEditCap else costCap
            if (state.cost > cap || state.cursor.isEmpty) return
            val key = VisitKey(state.cursor.lowerBound, state.cursor.byteDepth, state.consumed)
            val best = visited[key]
            if (best != null && best <= state.cost) return
            visited[key] = state.cost
            heap.push(state)
        }

        push(State(lexicon.prefixRootCursor(), consumed = 0, cost = 0.0, edits = 0))

        val deadline = startNanos + (config.beamTimeBudget * 1_000_000_000.0).toLong()
        var expansions = 0
        while (true) {
            val state = heap.pop() ?: break
            val key = VisitKey(state.cursor.lowerBound, state.cursor.byteDepth, state.consumed)
            val best = visited[key]
            if (best != null && best < state.cost) continue

            if (state.consumed == n) {
                val entry = lexicon.exactEntry(state.cursor)
                if (entry != null && emitted.add(entry.word)) {
                    results += BeamCandidate(entry.word, state.cost)
                    if (results.size >= config.beamMaxCandidates) break
                }
            }

            val cheapest = results.firstOrNull()
            if (cheapest != null && state.cost > cheapest.cost + config.beamEmitCostMargin) break

            expansions++
            if (expansions > config.beamMaxExpansions) break
            if (expansions % 64 == 0 && System.nanoTime() >= deadline) break

            val editsLeft = state.edits < maxEdits
            val childList = lexicon.childCursors(state.cursor, childScanLimit)
            val childMap = childList?.associate { it.character to it.cursor }
            fun step(char: Char, bytes: ByteArray): LexiconPrefixCursor? =
                if (childMap != null) childMap[char]
                else descend(state.cursor, char, bytes).takeUnless { it.isEmpty }

            if (state.consumed < n) {
                val typedChar = typed[state.consumed]
                val match = step(typedChar, typedBytes[state.consumed])
                if (match != null) {
                    push(State(match, state.consumed + 1, state.cost, state.edits))
                }

                if (editsLeft) {
                    val subCap = if (state.edits == 0) {
                        costCap
                    } else {
                        minOf(costCap, config.beamNeighborMaxCost + state.cost)
                    }
                    if (childList != null) {
                        for (child in childList) {
                            if (child.character == typedChar) continue
                            val cost = state.cost + substitutionPrice(
                                state.consumed, typedChar, child.character,
                            )
                            if (cost > subCap) continue
                            push(State(child.cursor, state.consumed + 1, cost, state.edits + 1))
                        }
                    } else {
                        val candidates = if (state.edits == 0) {
                            alphabet
                        } else {
                            cheapNeighbors[typedChar].orEmpty()
                        }
                        for (entry in candidates) {
                            if (entry.char == typedChar) continue
                            val cost = state.cost + substitutionPrice(
                                state.consumed, typedChar, entry.char,
                            )
                            if (cost > subCap) continue
                            push(
                                State(
                                    descend(state.cursor, entry.char, entry.bytes),
                                    state.consumed + 1,
                                    cost,
                                    state.edits + 1,
                                ),
                            )
                        }
                    }

                    if (state.cost + deletionCost <= costCap) {
                        push(
                            State(
                                state.cursor,
                                state.consumed + 1,
                                state.cost + deletionCost,
                                state.edits + 1,
                            ),
                        )
                    }

                    if (
                        state.consumed + 1 < n &&
                        typed[state.consumed] != typed[state.consumed + 1] &&
                        state.cost + transpositionCost <= costCap
                    ) {
                        val first = step(typed[state.consumed + 1], typedBytes[state.consumed + 1])
                        if (first != null) {
                            val second = descend(
                                first,
                                typedChar,
                                typedBytes[state.consumed],
                            )
                            push(
                                State(
                                    second,
                                    state.consumed + 2,
                                    state.cost + transpositionCost,
                                    state.edits + 1,
                                ),
                            )
                        }
                    }
                }
            }

            if (editsLeft) {
                if (childList != null) {
                    for (child in childList) {
                        val cost = state.cost + pricing.omissionPrice(
                            child.character,
                            base = insertionCost,
                        )
                        if (cost > costCap) continue
                        push(State(child.cursor, state.consumed, cost, state.edits + 1))
                    }
                } else {
                    for (entry in alphabet) {
                        val cost = state.cost + pricing.omissionPrice(
                            entry.char,
                            base = insertionCost,
                        )
                        if (cost > costCap) continue
                        push(
                            State(
                                descend(state.cursor, entry.char, entry.bytes),
                                state.consumed,
                                cost,
                                state.edits + 1,
                            ),
                        )
                    }
                }
            }
        }

        if (debugEnabled) {
            val elapsed = (System.nanoTime() - startNanos) / 1_000_000.0
            println(
                "beam: typed=${typed.joinToString("")} lex=$lexiconIndex " +
                    "expansions=$expansions visited=${visited.size} " +
                    "results=${results.size} t=${elapsed}ms",
            )
        }
        return results
    }

    private class StateHeap {
        private val storage = ArrayList<State>()

        fun push(element: State) {
            storage += element
            var child = storage.lastIndex
            while (child > 0) {
                val parent = (child - 1) shr 1
                if (storage[child].cost >= storage[parent].cost) break
                storage.swap(child, parent)
                child = parent
            }
        }

        fun pop(): State? {
            if (storage.isEmpty()) return null
            val first = storage[0]
            val last = storage.removeAt(storage.lastIndex)
            if (storage.isNotEmpty()) {
                storage[0] = last
                var parent = 0
                while (true) {
                    val left = parent * 2 + 1
                    if (left >= storage.size) break
                    val right = left + 1
                    var smallest = left
                    if (right < storage.size && storage[right].cost < storage[left].cost) {
                        smallest = right
                    }
                    if (storage[smallest].cost >= storage[parent].cost) break
                    storage.swap(parent, smallest)
                    parent = smallest
                }
            }
            return first
        }

        private fun ArrayList<State>.swap(a: Int, b: Int) {
            val value = this[a]
            this[a] = this[b]
            this[b] = value
        }
    }

    private companion object {
        const val childScanLimit = 48
        val candidateAlphabet: List<Char> =
            "aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö'’".toList()
        val debugEnabled: Boolean = System.getenv("TYPE_BEAM_DEBUG") != null
    }
}
