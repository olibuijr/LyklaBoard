package `is`.solberg.lyklabord.engine

/** Bounded source that can place a word hypothesis into the correction pool. */
enum class CandidateProvider(
    val rawValue: String,
    internal val bit: ULong,
) {
    shortBeam("short-beam", 1uL shl 0),
    edits1Residue("edits1-residue", 1uL shl 1),
    diacriticRestoration("diacritic-restoration", 1uL shl 2),
    gemination("gemination", 1uL shl 3),
    geminationRestoration("gemination-restoration", 1uL shl 4),
    shortDoubleSubstitution("short-double-substitution", 1uL shl 5),
    contextContinuation("context-continuation", 1uL shl 6),
    possessiveRestoration("possessive-restoration", 1uL shl 7),
    lexiconCompletion("lexicon-completion", 1uL shl 8),
    personalCompletion("personal-completion", 1uL shl 9),
    caseCompletion("case-completion", 1uL shl 10),
    caseSibling("case-sibling", 1uL shl 11),
    shorterPrefixCompletion("shorter-prefix-completion", 1uL shl 12),
    diacriticPrefixCompletion("diacritic-prefix-completion", 1uL shl 13),
    deepBeam("deep-beam", 1uL shl 14),
    mashRecoveryBeam("mash-recovery-beam", 1uL shl 15),
    compoundRepair("compound-repair", 1uL shl 16),
    compoundCompletion("compound-completion", 1uL shl 17),
    spaceMissSplit("space-miss-split", 1uL shl 18),
}

/** Allocation-free candidate-provider mask used by evaluation ablations. */
data class CandidateProviderSet(val rawValue: ULong = 0uL) {
    constructor(provider: CandidateProvider) : this(provider.bit)

    operator fun contains(provider: CandidateProvider): Boolean =
        (rawValue and provider.bit) == provider.bit

    fun contains(other: CandidateProviderSet): Boolean =
        (rawValue and other.rawValue) == other.rawValue

    fun union(other: CandidateProviderSet): CandidateProviderSet =
        CandidateProviderSet(rawValue or other.rawValue)

    operator fun plus(other: CandidateProviderSet): CandidateProviderSet = union(other)

    operator fun plus(provider: CandidateProvider): CandidateProviderSet =
        union(CandidateProviderSet(provider))

    val providers: List<CandidateProvider>
        get() = CandidateProvider.entries.filter { it in this }

    companion object {
        val all: CandidateProviderSet = CandidateProviderSet(
            CandidateProvider.entries.fold(0uL) { mask, provider -> mask or provider.bit },
        )
        val empty: CandidateProviderSet = CandidateProviderSet()

        fun of(vararg providers: CandidateProvider): CandidateProviderSet =
            CandidateProviderSet(
                providers.fold(0uL) { mask, provider -> mask or provider.bit },
            )
    }
}

/** Coarse switches for candidate-source ablation. */
enum class CandidateProviderFamily(val rawValue: String) {
    beam("beam"),
    lexicalRepair("lexical-repair"),
    restoration("restoration"),
    `context`("context"),
    completion("completion"),
    morphology("morphology"),
    compound("compound"),
    split("split");

    val providers: CandidateProviderSet
        get() = when (this) {
            beam -> CandidateProviderSet.of(
                CandidateProvider.shortBeam,
                CandidateProvider.deepBeam,
                CandidateProvider.mashRecoveryBeam,
            )
            lexicalRepair -> CandidateProviderSet.of(
                CandidateProvider.edits1Residue,
                CandidateProvider.gemination,
                CandidateProvider.shortDoubleSubstitution,
            )
            restoration -> CandidateProviderSet.of(
                CandidateProvider.diacriticRestoration,
                CandidateProvider.geminationRestoration,
                CandidateProvider.possessiveRestoration,
                CandidateProvider.diacriticPrefixCompletion,
            )
            `context` -> CandidateProviderSet.of(CandidateProvider.contextContinuation)
            completion -> CandidateProviderSet.of(
                CandidateProvider.lexiconCompletion,
                CandidateProvider.personalCompletion,
                CandidateProvider.shorterPrefixCompletion,
            )
            morphology -> CandidateProviderSet.of(
                CandidateProvider.caseCompletion,
                CandidateProvider.caseSibling,
            )
            compound -> CandidateProviderSet.of(
                CandidateProvider.compoundRepair,
                CandidateProvider.compoundCompletion,
            )
            split -> CandidateProviderSet.of(CandidateProvider.spaceMissSplit)
        }
}

/** First-wins candidate admission with optional provenance capture. */
class CandidateAdmissionPool(
    captureProvenance: Boolean,
) : Iterable<Map.Entry<String, ChannelCost>> {
    val costs = LinkedHashMap<String, ChannelCost>()
    private val provenance: MutableMap<String, CandidateProviderSet>? =
        if (captureProvenance) LinkedHashMap() else null
    operator fun get(word: String): ChannelCost? = costs[word]

    val keys: Set<String>
        get() = costs.keys

    fun admit(word: String, cost: () -> ChannelCost, provider: CandidateProvider): Boolean {
        if (costs.containsKey(word)) {
            val old = provenance?.get(word) ?: CandidateProviderSet.empty
            provenance?.set(word, old + provider)
            return false
        }
        costs[word] = cost()
        provenance?.set(word, CandidateProviderSet(provider))
        return true
    }

    fun admit(word: String, cost: ChannelCost, provider: CandidateProvider): Boolean =
        admit(word, { cost }, provider)

    fun providers(word: String): CandidateProviderSet =
        provenance?.get(word) ?: CandidateProviderSet.empty

    override fun iterator(): Iterator<Map.Entry<String, ChannelCost>> = costs.entries.iterator()
}

/** Ranker's additive signal ledger. */
data class RankedCandidate(
    val word: String,
    val cost: ChannelCost,
    val providers: CandidateProviderSet,
    val languageScore: Double,
    val channelContribution: Double,
    val languageContribution: Double,
    var morphologyContribution: Double,
    var compoundContribution: Double,
    var precedenceContribution: Double,
    var score: Double,
)
