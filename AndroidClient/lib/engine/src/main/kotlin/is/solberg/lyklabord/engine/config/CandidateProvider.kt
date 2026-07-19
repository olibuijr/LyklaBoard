package `is`.solberg.lyklabord.engine.config

/** Independent bounded candidate sources used by the engine. */
enum class CandidateProvider(val rawValue: String, internal val bit: Int) {
    shortBeam("short-beam", 1 shl 0),
    edits1Residue("edits1-residue", 1 shl 1),
    diacriticRestoration("diacritic-restoration", 1 shl 2),
    gemination("gemination", 1 shl 3),
    geminationRestoration("gemination-restoration", 1 shl 4),
    shortDoubleSubstitution("short-double-substitution", 1 shl 5),
    contextContinuation("context-continuation", 1 shl 6),
    possessiveRestoration("possessive-restoration", 1 shl 7),
    lexiconCompletion("lexicon-completion", 1 shl 8),
    personalCompletion("personal-completion", 1 shl 9),
    caseCompletion("case-completion", 1 shl 10),
    caseSibling("case-sibling", 1 shl 11),
    shorterPrefixCompletion("shorter-prefix-completion", 1 shl 12),
    diacriticPrefixCompletion("diacritic-prefix-completion", 1 shl 13),
    deepBeam("deep-beam", 1 shl 14),
    mashRecoveryBeam("mash-recovery-beam", 1 shl 15),
    compoundRepair("compound-repair", 1 shl 16),
    compoundCompletion("compound-completion", 1 shl 17),
    spaceMissSplit("space-miss-split", 1 shl 18),
}

/** Allocation-free mask used by evaluation ablations; empty enables every provider. */
data class CandidateProviderSet(val rawValue: Int = 0) {
    constructor(provider: CandidateProvider) : this(provider.bit)

    operator fun contains(provider: CandidateProvider): Boolean = rawValue and provider.bit == provider.bit
    fun contains(other: CandidateProviderSet): Boolean = rawValue and other.rawValue == other.rawValue
    fun union(other: CandidateProviderSet): CandidateProviderSet = CandidateProviderSet(rawValue or other.rawValue)
    operator fun plus(other: CandidateProviderSet): CandidateProviderSet = union(other)
    operator fun plus(provider: CandidateProvider): CandidateProviderSet = union(CandidateProviderSet(provider))

    val providers: List<CandidateProvider>
        get() = CandidateProvider.entries.filter { contains(it) }

    companion object {
        val all: CandidateProviderSet = CandidateProviderSet(CandidateProvider.entries.sumOf { it.bit })
        val empty: CandidateProviderSet = CandidateProviderSet()
        fun of(vararg providers: CandidateProvider): CandidateProviderSet =
            CandidateProviderSet(providers.fold(0) { mask, provider -> mask or provider.bit })
    }
}

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
            beam -> CandidateProviderSet.of(CandidateProvider.shortBeam, CandidateProvider.deepBeam, CandidateProvider.mashRecoveryBeam)
            lexicalRepair -> CandidateProviderSet.of(CandidateProvider.edits1Residue, CandidateProvider.gemination, CandidateProvider.shortDoubleSubstitution)
            restoration -> CandidateProviderSet.of(CandidateProvider.diacriticRestoration, CandidateProvider.geminationRestoration, CandidateProvider.possessiveRestoration, CandidateProvider.diacriticPrefixCompletion)
            `context` -> CandidateProviderSet(CandidateProvider.contextContinuation)
            completion -> CandidateProviderSet.of(CandidateProvider.lexiconCompletion, CandidateProvider.personalCompletion, CandidateProvider.shorterPrefixCompletion)
            morphology -> CandidateProviderSet.of(CandidateProvider.caseCompletion, CandidateProvider.caseSibling)
            compound -> CandidateProviderSet.of(CandidateProvider.compoundRepair, CandidateProvider.compoundCompletion)
            split -> CandidateProviderSet(CandidateProvider.spaceMissSplit)
        }
}
