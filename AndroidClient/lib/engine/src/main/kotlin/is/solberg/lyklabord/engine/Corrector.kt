package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfig
import `is`.solberg.lyklabord.engine.lexicon.Lexicon
import `is`.solberg.lyklabord.engine.lexicon.PrefixSearchableLexicon
import `is`.solberg.lyklabord.engine.morph.MorphologyProviding
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

/** Result of correcting a single typed token. */
data class CorrectionResult(val suggestions: List<Suggestion>, val typedWordIsValid: Boolean)

/** Noisy-channel autocorrect core. */
class Corrector {
    companion object {
        val alphabet: List<Char> = "aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö'’".toList()
        val apostrophes: Set<Char> = setOf('\'', '’')
        val quotationMarks: Set<Char> = setOf('"', '“', '”', '„', '«', '»', '‹', '›')
        val linkingLetters: Set<Char> = setOf('s', 'a', 'r', 'u')
        val singleLetterAccentPairs: Map<Char, Char> = mapOf('a' to 'á', 'e' to 'é', 'i' to 'í', 'o' to 'ó', 'u' to 'ú', 'y' to 'ý')
        val restorationVariants: Map<Char, List<Char>> = mapOf('a' to listOf('á'), 'e' to listOf('é'), 'i' to listOf('í'), 'o' to listOf('ó', 'ö'), 'u' to listOf('ú'), 'y' to listOf('ý'), 'd' to listOf('ð'), 't' to listOf('þ'), 'v' to listOf('ð'))

        fun hasSingleLetterAccentEscape(token: String): Boolean = token.length == 1 && singleLetterAccentPairs[token.lowercase().first()] != null
        fun preservesApostrophes(typed: String, candidate: String): Boolean = typed.count { it in apostrophes } == 0 || candidate.count { it in apostrophes } >= typed.count { it in apostrophes }
        fun preservesQuotationMarks(typed: String, candidate: String): Boolean = typed.count { it in quotationMarks } == 0 || candidate.count { it in quotationMarks } >= typed.count { it in quotationMarks }
        fun preservesDeliberateCharacters(deliberate: List<Char>, typed: List<Char>, candidate: String): Boolean {
            if (deliberate.isEmpty()) return true
            val cc = candidate.toList()
            return deliberate.toSet().all { ch -> min(deliberate.count { it == ch }, typed.count { it == ch }) <= cc.count { it == ch } }
        }
        fun isRestorationPair(x: Char, y: Char): Boolean = SpatialModel.accentBase[x] == y || SpatialModel.accentBase[y] == x || SpatialModel.confusionPairs.contains("$x$y")
        fun rewriteDistance(a: List<Char>, b: List<Char>): Int {
            val n = a.size; val m = b.size; val w = m + 1
            if (n == 0) return b.count { it !in apostrophes }
            if (m == 0) return n
            val d = IntArray((n + 1) * w)
            for (i in 0..n) d[i * w] = i
            for (j in 1..m) d[j] = d[j - 1] + if (b[j - 1] in apostrophes) 0 else 1
            for (i in 1..n) for (j in 1..m) {
                val sub = d[(i - 1) * w + j - 1] + if (a[i - 1] == b[j - 1] || isRestorationPair(a[i - 1], b[j - 1])) 0 else 1
                val ins = d[(i - 1) * w + j] + 1
                val del = d[i * w + j - 1] + if (b[j - 1] in apostrophes) 0 else 1
                var best = min(sub, min(ins, del))
                if (i >= 2 && j >= 2 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] && a[i - 1] != a[i - 2]) best = min(best, d[(i - 2) * w + j - 2] + 1)
                d[i * w + j] = best
            }
            return d[n * w + m]
        }
        fun dedoubledVariants(chars: List<Char>): List<List<Char>> = if (chars.size < 2) emptyList() else (0 until chars.size - 1).filter { chars[it] == chars[it + 1] }.map { i -> chars.toMutableList().also { it.removeAt(i) } }
        fun isLinkingLetterRepair(typedChars: List<Char>, candidate: String, split: CompoundSplit): Boolean {
            val cc = candidate.toList()
            val bounds = split.modifiers.runningFold(0) { a: Int, s: String -> a + s.length }.drop(1)
            return bounds.any { b -> cc.size == typedChars.size + 1 && b < cc.size && cc[b] in linkingLetters && cc.take(b) == typedChars.take(b) && cc.drop(b + 1) == typedChars.drop(b) }
        }
        fun geminationVariants(chars: List<Char>): List<String> {
            if (chars.size < 2) return emptyList()
            val out = dedoubledVariants(chars).map { it.joinToString("") }.toMutableList()
            fun double(base: List<Char>) { for (i in base.indices) if (i == 0 || base[i] != base[i - 1]) out += (base.toMutableList().also { it.add(i, base[i]) }).joinToString("") }
            double(chars); dedoubledVariants(chars).forEach(::double); return out
        }
        fun diacriticVariants(chars: List<Char>, maxChanges: Int = 3): List<String> {
            val result = mutableListOf<String>(); val current = chars.toMutableList()
            fun rec(index: Int, left: Int) { if (left <= 0) return; for (i in index until current.size) { val vs = restorationVariants[current[i]] ?: continue; val old = current[i]; for (v in vs) { current[i] = v; result += current.joinToString(""); rec(i + 1, left - 1) }; current[i] = old } }
            rec(0, maxChanges); return result
        }
        fun edits1Costed(chars: List<Char>, spatial: SpatialModel): Map<String, Double> {
            val out = linkedMapOf<String, Double>(); fun add(c: List<Char>, cost: Double) { val s = c.joinToString(""); if (out[s] == null || out[s]!! > cost) out[s] = cost }
            chars.indices.forEach { i -> add(chars.toMutableList().also { it.removeAt(i) }, spatial.costs.insertion) }
            if (chars.size > 1) for (i in 0 until chars.size - 1) if (chars[i] != chars[i + 1]) add(chars.toMutableList().also { it[i] = chars[i + 1]; it[i + 1] = chars[i] }, spatial.costs.transposition)
            chars.indices.forEach { i -> alphabet.filter { it != chars[i] }.forEach { ch -> add(chars.toMutableList().also { it[i] = ch }, spatial.substitutionCost(chars[i], ch)) } }
            for (i in 0..chars.size) alphabet.forEach { ch -> add(chars.toMutableList().also { it.add(i, ch) }, spatial.costs.deletion) }
            return out
        }
    }

    val spatial: SpatialModel
    val model: BlendedLanguageModel
    val config: EngineConfig
    val beam: BeamDecoder
    val positionCosts: PositionCostProvider

    constructor(icelandic: Lexicon, english: Lexicon, morphology: MorphologyProviding? = null, config: EngineConfig = EngineConfig()) : this(BlendedLanguageModel(icelandic, english, morphology, config), config)
    constructor(model: BlendedLanguageModel, config: EngineConfig) { this.model = model; this.config = config; spatial = SpatialModel(config.spatialCosts); beam = BeamDecoder(config, spatial); positionCosts = StaticSpatialCostProvider(spatial) }

    private fun disabled(provider: CandidateProvider): Boolean = config.disabledCandidateProviders.providers.any { it.rawValue == provider.rawValue }
    private fun candidateWord(word: String, morph: Boolean): Boolean = !model.isPersonalTombstoned(word) && (model.isPersonalValid(word) || model.icelandic.frequency(word) != null || model.english.frequency(word) != null || (morph && model.morphology?.isKnown(word) == true))
    private fun isValidHyphenated(word: String): Boolean = word.contains('-') && word.split('-').filter { it.isNotEmpty() }.all { model.isValidTypedWord(it) }

    fun correct(typed: String, previousWord: String? = null, pIcelandic: Double = .5, limit: Int = 3, deliberateCharacters: List<Char> = emptyList(), taps: List<TapSample?> = emptyList(), capitalizedMidSentence: Boolean = false, trace: CorrectionTrace? = null): CorrectionResult {
        val raw = typed; val t = raw.lowercase(); val chars = t.toList()
        trace?.apply { this.typed = t; this.previousWord = previousWord; this.pIcelandic = pIcelandic }
        if (chars.isEmpty() || limit <= 0) return CorrectionResult(emptyList(), false)
        if (isValidHyphenated(t)) return CorrectionResult(emptyList(), true)
        val valid = model.isValidTypedWord(t); val compound = if (valid) null else model.compoundSplit(t); val protected = valid || compound != null
        trace?.typedIsValid = valid
        if (chars.size == 1) return singleLetter(chars[0], previousWord, pIcelandic, valid, trace)
        val pricing = FoldPricing(config, pIcelandic, deliberateCharacters.isNotEmpty())
        val perTap = if (taps.size == chars.size && taps.any { it != null }) PerTapCostProvider(taps, spatial, config, model.touch.snapshot) else null
        val prev = if (config.bigramContextFoldBackoffEnabled) model.effectiveBigramContext(previousWord) else previousWord
        val pool = CandidateAdmissionPool(trace != null)
        fun admit(word: String, provider: CandidateProvider, cost: ChannelCost = channelCost(chars, word, pricing, perTap)): Boolean { if (word == t || disabled(provider) || model.isPersonalTombstoned(word)) return false; return pool.admit(word, cost, provider) }
        fun runBeam(maxEdits: Int, provider: CandidateProvider, cap: Double? = null) { if (disabled(provider)) return; listOf(model.icelandic, model.english).forEachIndexed { slot, lex -> val p = lex as? PrefixSearchableLexicon ?: return@forEachIndexed; beam.decode(chars, p, slot, perTap ?: positionCosts, pricing, maxEdits, cap).forEach { admit(it.word, provider) } } }
        runBeam(config.beamShortMaxEdits, CandidateProvider.shortBeam)
        edits1Costed(chars, spatial).forEach { (word, cost) -> if (model.isPersonalValid(word) || model.morphology?.isKnown(word) == true) admit(word, CandidateProvider.edits1Residue, ChannelCost(cost, 1, 0)) }
        diacriticVariants(chars).filter { candidateWord(it, true) }.forEach { admit(it, CandidateProvider.diacriticRestoration) }
        geminationVariants(chars).filter { candidateWord(it, true) }.forEach { admit(it, CandidateProvider.gemination) }
        dedoubledVariants(chars).forEach { base -> diacriticVariants(base, 2).filter { candidateWord(it, true) }.forEach { admit(it, CandidateProvider.geminationRestoration) } }
        if (!valid && chars.size >= config.beamLongMinLength) runBeam(config.beamMaxEdits, CandidateProvider.deepBeam)
        if (config.contextContinuationEnabled && !valid && prev != null && chars.size < config.beamLongMinLength) {
            listOf(model.icelandic, model.english).forEachIndexed { slot, lex -> model.continuationProposals.continuations(prev, slot) { lex.continuations(prev, config.contextContinuationPoolLimit) }.filter { it.word != t && abs(it.word.length - t.length) <= 1 && (it.word.firstOrNull() == chars.first() || isRestorationPair(it.word.firstOrNull() ?: ' ', chars.first())) }.forEach { if (model.calibratedUnigramScore(it.word, if (slot == 0) Language.icelandic else Language.english) >= config.shortDoubleSubContextMinZ) admit(it.word, CandidateProvider.contextContinuation) } }
        }
        if (config.foldProfileENEnabled && 1 - pIcelandic >= config.accentOfferMinPosterior && chars.last() == 's' && chars.size >= 4 && chars.all { it.isLetter() } && !chars.any { it in apostrophes }) model.derivedPossessiveBase(t.dropLast(1) + "'s")?.let { stem -> if (!valid || model.calibratedUnigramScore(stem, Language.english) >= config.possessiveOfferMinBaseZ) admit(t.dropLast(1) + "'s", CandidateProvider.possessiveRestoration) }
        val completionLimit = config.completionPoolLimit
        if (!disabled(CandidateProvider.lexiconCompletion)) listOf(model.icelandic, model.english).forEach { lex -> lex.completions(t, completionLimit).forEach { admit(it.word, CandidateProvider.lexiconCompletion) } }
        if (!disabled(CandidateProvider.personalCompletion)) model.personal.completions(t, config.personalCompletionPoolLimit).forEach { admit(it.word, CandidateProvider.personalCompletion) }
        if (config.compoundRepairEnabled && !valid && chars.size >= config.compoundRepairMinLength) {
            val paradigms = model.inflection.model?.paradigms
            val morph = model.morphology
            if (paradigms != null && morph != null) {
                for (splitAt in (config.compoundMinModifierLength..(chars.size - config.compoundMinHeadLength)).reversed()) {
                    val modifier = t.take(splitAt)
                    if (!model.compounds.isModifier(modifier, paradigms, config.compoundMinModifierLength)) continue
                    val head = t.drop(splitAt)
                    val variants = linkedMapOf<String, Double>()
                    edits1Costed(head.toList(), spatial).forEach { (v, c) -> if (model.compounds.isHead(v, morph, config.compoundMinHeadLength)) variants[v] = min(variants[v] ?: Double.POSITIVE_INFINITY, c) }
                    diacriticVariants(head.toList()).forEach { v -> if (model.compounds.isHead(v, morph, config.compoundMinHeadLength)) variants[v] = min(variants[v] ?: Double.POSITIVE_INFINITY, spatialCost(head.toList(), v)) }
                    variants.forEach { (v, c) -> admit(modifier + v, CandidateProvider.compoundRepair, ChannelCost(c, 1, 0)) }
                    if (config.compoundCompletionEnabled) {
                        model.icelandic.completions(head, config.completionPoolLimit).forEach { e ->
                            if (model.compounds.isHead(e.word, morph, config.compoundMinHeadLength) && e.word.length > head.length) {
                                admit(modifier + e.word, CandidateProvider.compoundCompletion, ChannelCost(config.compoundCompletionBasePenalty + (e.word.length - head.length) * config.completionCharCost, e.word.length - head.length + 1, 0))
                            }
                        }
                    }
                    break
                }
            }
        }
        if (chars.size >= 5 && pool.keys.none { !it.startsWith(t) && it.isNotEmpty() && isAttestedOrPersonal(it) && pool[it]!!.total <= config.closeCandidateGate }) for (len in (chars.size - 1).downTo(maxOf(3, chars.size - 4))) { val prefix = t.take(len); listOf(model.icelandic, model.english).forEach { lex -> lex.completions(prefix, completionLimit).forEach { admit(it.word, CandidateProvider.shorterPrefixCompletion) } } }
        if (!valid && chars.size >= config.beamLongMinLength && bestAttestedCost(pool.costs) > config.beamDeepGate) runBeam(config.beamMaxEdits, CandidateProvider.deepBeam, config.mashRecoveryCostCap)
        val scored = pool.map { (word, cost) -> val lang = model.blendedScore(word, prev, pIcelandic); RankedCandidate(word, cost, pool.providers(word), lang, -cost.total, config.languageWeight * lang, 0.0, 0.0, 0.0, -cost.total + config.languageWeight * lang) }.toMutableList()
        if (!disabled(CandidateProvider.spaceMissSplit) && !valid && chars.size >= config.splitMinLength && chars.all { it.isLetter() } && (pool.valuesMinCost() > config.splitGate)) splitCandidates(chars, prev, pIcelandic, if (taps.size == chars.size) taps else emptyList(), if (raw.length == chars.size) raw.toList() else emptyList()).forEach { (word, cost, lang, score) -> scored += RankedCandidate(word, ChannelCost(cost, 1, 0), CandidateProviderSet(CandidateProvider.spaceMissSplit), lang, -cost, config.languageWeight * lang, 0.0, 0.0, 0.0, score) }
        scored.sortWith(compareByDescending<RankedCandidate> { it.score }.thenBy { it.word })
        val input = AutocorrectPolicyInput(t, chars, deliberateCharacters, previousWord, prev, pIcelandic, capitalizedMidSentence, valid, protected, compound, perTap, pricing, pool, emptySet(), emptySet(), scored)
        val auto = if (scored.isNotEmpty()) decideAutocorrect(input, trace) else false
        trace?.apply { autocorrect = auto; margin = if (scored.size > 1) scored[0].score - scored[1].score else Double.POSITIVE_INFINITY; candidates = scored.take(8).map { c -> CorrectionTrace.Candidate(c.word, c.providers.providers.mapNotNull { p -> `is`.solberg.lyklabord.engine.config.CandidateProvider.entries.find { it.rawValue == p.rawValue } }, c.cost.total, c.cost.errorOps, c.cost.restorationOps, c.channelContribution, c.languageScore, c.languageContribution, model.calibratedUnigramScore(c.word, Language.icelandic), null, model.personalBoost(c.word, prev), c.morphologyContribution, c.compoundContribution, c.precedenceContribution, c.score) }; providerSummaries = CandidateProvider.entries.map { p -> CorrectionTrace.ProviderSummary(`is`.solberg.lyklabord.engine.config.CandidateProvider.entries.first { it.rawValue == p.rawValue }, scored.count { c -> c.providers.providers.any { it.rawValue == p.rawValue } }, disabled(p)) } }
        if (scored.isEmpty()) return CorrectionResult(emptyList(), protected)
        val maxScore = scored.take(8).maxOf { it.score }; val denom = scored.take(8).sumOf { exp(it.score - maxScore) }
        val suggestions = scored.take(limit).mapIndexed { i, c -> Suggestion(c.word, i == 0 && auto, if (denom > 0) exp(c.score - maxScore) / denom else 0.0, isRestoration = c.cost.isRestorationOnly) }
        return CorrectionResult(suggestions, protected)
    }

    private fun singleLetter(letter: Char, previous: String?, p: Double, valid: Boolean, trace: CorrectionTrace?): CorrectionResult {
        val out = mutableListOf<Suggestion>(); val accented = singleLetterAccentPairs[letter]
        if (config.foldProfileISEnabled && accented != null && p >= config.accentOfferMinPosterior && model.icelandic.frequency(accented.toString()) != null && model.calibratedUnigramScore(accented.toString(), Language.icelandic) >= config.accentRestoreMinZ && !model.isPersonalTombstoned(accented.toString())) {
            val bare = letter.toString(); val s1 = model.blendedScore(accented.toString(), previous, p); val s2 = model.blendedScore(bare, previous, p); val z = exp(s1 - max(s1, s2)) / (exp(s1 - max(s1, s2)) + exp(s2 - max(s1, s2))); val allowed = p >= config.accentAutoApplyMinPosterior && !model.isPersonalProtected(bare) && model.icelandic.frequency(bare) == null; out += Suggestion(accented.toString(), allowed, z, isRestoration = true)
        }
        if (config.foldProfileENEnabled && letter == 'i' && 1 - p >= config.accentOfferMinPosterior && model.english.frequency("i") != null && model.calibratedUnigramScore("i", Language.english) >= config.accentRestoreMinZ && !model.isPersonalTombstoned("i")) out += Suggestion("I", 1 - p >= config.accentAutoApplyMinPosterior && !model.isPersonalProtected("i"), 1 - p, isRestoration = true)
        return CorrectionResult(out.sortedWith(compareByDescending<Suggestion> { it.isAutocorrect }.thenByDescending { it.confidence }), valid)
    }

    fun spatialCost(typedChars: List<Char>, candidate: String): Double { val cc = candidate.toList(); var c = spatial.typingCost(typedChars, cc); if (cc.size > typedChars.size && cc.subList(0, typedChars.size) == typedChars) c = min(c, (cc.size - typedChars.size) * config.completionCharCost); return c }
    fun channelCost(typedChars: List<Char>, candidate: String, pricing: FoldPricing, perTap: PerTapCostProvider? = null): ChannelCost { var c = if (perTap != null) spatial.channelCost(typedChars, candidate.toList(), pricing, perTap, config.tapFoldConfidenceMaxPenalty) else spatial.channelCost(typedChars, candidate.toList(), pricing); if (candidate.length > typedChars.size && candidate.startsWith(typedChars.joinToString(""))) { val x = (candidate.length - typedChars.size) * config.completionCharCost; if (x < c.total) c = ChannelCost(x, candidate.length - typedChars.size, 0) }; return c }
    fun speculativeCompletionCost(typedChars: List<Char>, candidate: String, pricing: FoldPricing, perTap: PerTapCostProvider? = null): ChannelCost = channelCost(typedChars, candidate, pricing, perTap)
    fun isAttestedOrPersonal(word: String): Boolean = !model.isPersonalTombstoned(word) && (model.isPersonalValid(word) || model.icelandic.frequency(word) != null || model.english.frequency(word) != null || model.derivedPossessiveBase(word) != null)
    fun attestedTypicality(word: String): Double? { var z: Double? = null; if (model.icelandic.frequency(word) != null) z = model.calibratedUnigramScore(word, Language.icelandic); if (model.english.frequency(word) != null || model.derivedPossessiveBase(word) != null) z = max(z ?: Double.NEGATIVE_INFINITY, model.calibratedUnigramScore(word, Language.english)); return z }
    fun bestAttestedCost(candidates: Map<String, ChannelCost>, excluding: Set<String> = emptySet()): Double = candidates.filter { (w, c) -> w !in excluding && isAttestedOrPersonal(w) }.minOfOrNull { it.value.total } ?: Double.POSITIVE_INFINITY
    fun tapVetoFactor(typedChars: List<Char>, candidate: String, perTap: PerTapCostProvider?, isRestorationOnly: Boolean = false, winnerTypicality: Double = Double.NEGATIVE_INFINITY): Double { if (perTap == null || isRestorationOnly) return 1.0; return min(config.tapVetoMaxFactor, 1 + config.tapVetoStrength * max(0.0, (perTap.meanTapConfidence ?: 0.0) - config.tapVetoBaseline)) }
    fun restorationProfileWeight(typed: String, candidate: String, pricing: FoldPricing): Double = if (candidate.count { it in apostrophes } > typed.count { it in apostrophes }) pricing.weightEN else pricing.weightIS
    fun passesRestorationTripleGate(typed: String, candidate: String, previousWord: String?, pIcelandic: Double, trace: CorrectionTrace? = null): Boolean {
        var pass = true
        fun gate(name: String, detail: String, ok: Boolean) { trace?.gate(name, detail, ok); pass = pass && ok }
        val addsApostrophe = candidate.count { it in apostrophes } > typed.count { it in apostrophes }
        val lane = if (addsApostrophe) Language.english else Language.icelandic
        val other = if (addsApostrophe) Language.icelandic else Language.english
        val pLane = if (addsApostrophe) 1 - pIcelandic else pIcelandic
        gate("no-personal-skeleton", "skeleton is not personal/tombstoned", !model.isPersonalProtected(typed) && !model.isPersonalTombstoned(typed))
        gate("lane-posterior", "P(lane) $pLane >= ${config.accentAutoApplyMinPosterior}", pLane >= config.accentAutoApplyMinPosterior)
        val candidateFrequency = model.lexicon(lane).frequency(candidate)
        val skeletonFrequency = model.lexicon(lane).frequency(typed)
        if (candidateFrequency == null) gate("dominance-ratio", "candidate unattested in lane lexicon", false)
        else if (skeletonFrequency != null) gate("dominance-ratio", "candidate frequency dominates skeleton", candidateFrequency.toDouble() >= config.restorationDominanceRatio * skeletonFrequency.toDouble())
        else if (lane == Language.icelandic && model.morphology?.isKnown(typed) == true) {
            val cases = model.morphology?.nounAdjectiveCases(typed).orEmpty()
            val oblique = cases.isNotEmpty() && "nf" !in cases
            val minimum = if (oblique) config.restorationDominanceObliqueMinZ else config.restorationDominanceMinZ
            gate("dominance-minZ", "BÍN-valid skeleton, candidate z", model.calibratedUnigramScore(candidate, lane) >= minimum)
        }
        val candidateContext = model.calibratedScore(candidate, previousWord, lane)
        val skeletonContext = model.calibratedScore(typed, previousWord, lane)
        gate("context-advantage", "candidate context advantage", candidateContext - skeletonContext >= config.restorationContextMinAdvantage)
        if (model.lexicon(other).frequency(typed) != null) {
            val clamped = pLane.coerceIn(1e-6, 1 - 1e-6)
            val advantage = ln(clamped / (1 - clamped)) + config.calibrationTemperature * (candidateContext - model.calibratedScore(typed, previousWord, other))
            gate("sletta-guard", "cross-language skeleton reading", advantage >= config.slettaGuardBlendThreshold)
        }
        return pass
    }
    fun halfHypotheses(chars: List<Char>): List<Pair<String, Double>> { val out = mutableMapOf<String, Double>(); val text = chars.joinToString(""); if (model.isKnownAnywhere(text) || model.isPersonalValid(text)) out[text] = 0.0; diacriticVariants(chars).filter { candidateWord(it, true) }.forEach { out[it] = min(out[it] ?: Double.POSITIVE_INFINITY, spatialCost(chars, it)) }; geminationVariants(chars).filter { candidateWord(it, true) }.forEach { out[it] = min(out[it] ?: Double.POSITIVE_INFINITY, spatialCost(chars, it)) }; if (out.isEmpty() && chars.size in 3..config.splitHalfEdits1MaxLength) edits1Costed(chars, spatial).filter { it.value <= config.splitHalfRepairMaxCost && candidateWord(it.key, true) }.forEach { out[it.key] = it.value }; return out.entries.sortedWith(compareBy({ it.value }, { it.key })).take(config.splitHalfHypothesisLimit).map { it.key to it.value } }

    fun splitCandidates(typedChars: List<Char>, previousWord: String?, pIcelandic: Double, taps: List<TapSample?> = emptyList(), rawChars: List<Char> = emptyList()): List<SplitCandidate> {
        val out = mutableMapOf<String, SplitCandidate>(); val n = typedChars.size; if (n < config.splitMinLength) return emptyList(); val positions = (1 until n).sortedBy { abs(2 * it - n) }.take(config.splitMaxPositions)
        for (i in positions) for ((left, lc) in halfHypotheses(typedChars.take(i))) for ((right, rc) in halfHypotheses(typedChars.drop(i))) { val text = "$left $right"; val cost = config.splitInsertionPenalty + lc + rc; val lang = model.blendedPairScore(left, right, previousWord, pIcelandic); val c = SplitCandidate(text, cost, lang, -cost + config.languageWeight * lang); if (out[text] == null || out[text]!!.spatialCost > cost) out[text] = c }
        return out.values.sortedWith(compareByDescending<SplitCandidate> { it.score }.thenBy { it.word })
    }
    data class SplitCandidate(val word: String, val spatialCost: Double, val languageScore: Double, val score: Double)
    fun bestSingleWordRepairCost(typed: String): Double { if (model.isValidTypedWord(typed)) return 0.0; var best = Double.POSITIVE_INFINITY; edits1Costed(typed.toList(), spatial).forEach { if (isAttestedOrPersonal(it.key)) best = min(best, it.value) }; return best }
    fun dotSplitSuggestion(left: String, right: String, previousWord: String?, pIcelandic: Double): Suggestion? { val z = listOf(Language.icelandic, Language.english).mapNotNull { l -> if (model.lexicon(l).frequency(left) != null && model.lexicon(l).frequency(right) != null) min(model.calibratedUnigramScore(left, l), model.calibratedUnigramScore(right, l)) else null }.maxOrNull() ?: return null; if (z < config.dottedEscapeMinHalfZ || model.isPersonalTombstoned(left) || model.isPersonalTombstoned(right)) return null; val score = -config.dottedEscapePenalty + config.languageWeight * model.blendedPairScore(left, right, previousWord, pIcelandic); return Suggestion("$left $right", z >= config.dottedEscapeAutoApplyMinHalfZ && bestSingleWordRepairCost(left + right) > config.splitAutoApplySingleWordCutoff, 1 / (1 + exp(-score))) }
}

private fun CandidateAdmissionPool.valuesMinCost(): Double = this.map { it.value.total }.minOrNull() ?: Double.POSITIVE_INFINITY
