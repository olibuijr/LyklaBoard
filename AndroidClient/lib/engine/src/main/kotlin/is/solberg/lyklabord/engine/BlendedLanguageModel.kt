package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.EngineConfig
import `is`.solberg.lyklabord.engine.lexicon.LexEntry
import `is`.solberg.lyklabord.engine.lexicon.Lexicon
import `is`.solberg.lyklabord.engine.lexicon.LexiconCalibrationProfile
import `is`.solberg.lyklabord.engine.morph.MorphologyProviding
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/** Per-context memo of bigram-continuation proposal pools. */
class ContinuationProposalCache {
    private val lock = Any()
    private var key: String? = null
    private var pools: Array<List<LexEntry>> = arrayOf(emptyList(), emptyList())

    /** Followers of [previous] in lexicon slot 0 (IS) or 1 (EN). */
    fun continuations(
        previous: String,
        slot: Int,
        fetch: () -> List<LexEntry>,
    ): List<LexEntry> = synchronized(lock) {
        require(slot in 0..1) { "continuation slot must be 0 or 1" }
        if (key != previous) {
            key = previous
            pools = arrayOf(emptyList(), emptyList())
        }
        if (pools[slot].isEmpty()) pools[slot] = fetch()
        pools[slot]
    }
}

/** Shared bilingual probability model. */
class BlendedLanguageModel(
    val icelandic: Lexicon,
    val english: Lexicon,
    val morphology: MorphologyProviding?,
    val config: EngineConfig,
    icelandicCalibrationProfile: LexiconCalibrationProfile? = null,
    englishCalibrationProfile: LexiconCalibrationProfile? = null,
    val personal: PersonalStore = PersonalStore(),
    val inflection: InflectionStore = InflectionStore(),
    val touch: TouchModelStore = TouchModelStore(),
) {
    val icelandicCalibration: LexiconCalibration =
        calibrationFor(icelandicCalibrationProfile, icelandic, config.addK)
    val englishCalibration: LexiconCalibration =
        calibrationFor(englishCalibrationProfile, english, config.addK)
    val compounds: CompoundAnalyzer = CompoundAnalyzer()
    val continuationProposals: ContinuationProposalCache = ContinuationProposalCache()

    fun lexicon(language: Language): Lexicon =
        if (language == Language.icelandic) icelandic else english

    fun calibration(language: Language): LexiconCalibration =
        if (language == Language.icelandic) icelandicCalibration else englishCalibration

    fun isKnownAnywhere(word: String): Boolean =
        icelandic.frequency(word) != null ||
            english.frequency(word) != null ||
            morphology?.isKnown(word) == true ||
            derivedPossessiveBase(word) != null

    fun derivedPossessiveBase(word: String): String? {
        if (word.length < 4) return null
        val chars = word.toMutableList()
        if (chars.removeAt(chars.size - 1) != 's') return null
        val apostrophe = chars.lastOrNull() ?: return null
        if (apostrophe !in APOSTROPHES) return null
        chars.removeAt(chars.size - 1)
        if (chars.size < 2 || !chars.all { it.isLetter() }) return null
        if (chars.last() == 's') return null
        val base = chars.joinToString("")
        return if (english.frequency(base) != null) base else null
    }

    fun isPersonalValid(word: String): Boolean = personal.isValidWord(word)

    fun acuteFoldSkeleton(word: String): String? {
        val folded = word.map { SpatialModel.accentBase[it] ?: it }.joinToString("")
        return if (folded != word) folded else null
    }

    fun acuteFoldShadowTwin(word: String): String? {
        val chars = word.toMutableList()
        val positions = chars.indices.filter { SpatialModel.acuteOfBase[chars[it]] != null }
        if (positions.isEmpty() || positions.size > 5) return null
        var bestWord: String? = null
        var bestFrequency = 0u
        for (mask in 1 until (1 shl positions.size)) {
            val variant = chars.toMutableList()
            for ((bit, position) in positions.withIndex()) {
                if ((mask and (1 shl bit)) != 0) {
                    variant[position] = SpatialModel.acuteOfBase[chars[position]]!!
                }
            }
            val twin = variant.joinToString("")
            val frequency = icelandic.frequency(twin) ?: continue
            if (bestWord == null || frequency > bestFrequency) {
                bestWord = twin
                bestFrequency = frequency
            }
        }
        val twin = bestWord ?: return null
        val ownIS = (icelandic.frequency(word) ?: 0u).toDouble()
        if (bestFrequency.toDouble() < config.personalFoldShadowDominanceRatio * max(ownIS, 1.0)) return null
        val twinZ = calibratedUnigramScore(twin, Language.icelandic)
        if (twinZ < config.personalFoldShadowMinTwinZ) return null
        if (twinZ <= calibratedUnigramScore(word, Language.english)) return null
        return twin
    }

    fun isPersonalProtected(word: String): Boolean {
        if (!personal.isValidWord(word)) return false
        if (personal.isExplicitWord(word)) return true
        return acuteFoldShadowTwin(word) == null
    }

    fun isCapArtifactBase(lower: String): Boolean =
        calibratedUnigramScore(lower, Language.icelandic) >= config.personalCapArtifactMinZ ||
            calibratedUnigramScore(lower, Language.english) >= config.personalCapArtifactMinZ

    fun isPersonalTombstoned(word: String): Boolean = personal.isTombstoned(word)

    fun isValidTypedWord(word: String): Boolean =
        isKnownAnywhere(word) || isPersonalProtected(word) || personal.isTombstoned(word)

    fun compoundSplit(word: String): CompoundSplit? {
        if (!config.compoundValidityEnabled) return null
        val morph = morphology ?: return null
        val paradigms = inflection.model?.paradigms ?: return null
        return compounds.split(word, morph, paradigms, config)
    }

    fun isProtectedTypedWord(word: String): Boolean =
        isValidTypedWord(word) || compoundSplit(word) != null

    fun personalBoost(word: String, previous: String?): Double {
        if (!personal.isActive) return 0.0
        var boost = 0.0
        if (personal.isValidWord(word) && !personal.isTombstoned(word)) {
            val count = personal.count(word).toDouble()
            boost = min(config.personalBoostCap, config.personalBoostBase + config.personalBoostScale * ln(1 + count))
        } else {
            val skeleton = acuteFoldSkeleton(word)
            if (
                skeleton != null && personal.isValidWord(skeleton) && !personal.isTombstoned(skeleton) &&
                !personal.isExplicitWord(skeleton) && !personal.isTombstoned(word) &&
                acuteFoldShadowTwin(skeleton) == word
            ) {
                val count = personal.count(skeleton).toDouble()
                boost = min(config.personalBoostCap, config.personalBoostBase + config.personalBoostScale * ln(1 + count))
            } else {
                val lift = inflection.lift
                if (lift != null && !personal.isTombstoned(word)) {
                    boost = ln(lift.lemmaBoost(word))
                }
            }
        }
        if (previous != null) {
            val pairCount = personal.bigramCount(previous, word)
            if (pairCount != null && !personal.isTombstoned(word)) {
                boost += min(config.personalBigramBoostCap, config.personalBigramBoostScale * ln(1 + pairCount.toDouble()))
            }
        }
        return boost
    }

    fun effectiveFrequency(word: String, language: Language): UInt? {
        val attested = lexicon(language).frequency(word)
        if (language == Language.english) {
            val base = derivedPossessiveBase(word)
            val baseFrequency = base?.let { english.frequency(it) }
            if (baseFrequency != null) {
                val derived = min(
                    max(1.0, (baseFrequency.toDouble() * config.possessiveFrequencyFraction).roundToLong().toDouble()),
                    UInt.MAX_VALUE.toDouble(),
                ).toLong().toUInt()
                return maxOf(attested ?: 0u, derived)
            }
        }
        if (attested != null) return attested
        if (language == Language.icelandic && morphology?.isKnown(word) == true) return config.binFloorFrequency
        if (language == Language.icelandic && compoundSplit(word) != null) return config.compoundFloorFrequency
        return null
    }

    fun unigramProbability(word: String, language: Language): Double {
        val f = (effectiveFrequency(word, language) ?: 0u).toDouble()
        val total = lexicon(language).totalUnigramTokens.toDouble()
        return (f + config.addK) / (total + config.addK * config.assumedVocabularySize)
    }

    fun contextualProbability(word: String, previous: String?, language: Language): Double {
        val uni = unigramProbability(word, language)
        val prev = previous ?: return uni
        val prevFreq = lexicon(language).frequency(prev) ?: return uni
        if (prevFreq == 0u) return uni
        val bigram = (lexicon(language).bigramFrequency(prev, word) ?: 0u).toDouble()
        val mle = bigram / prevFreq.toDouble()
        val beta = config.bigramInterpolation
        return beta * mle + (1 - beta) * uni
    }

    private fun referenceLogProbability(language: Language): Double {
        val cal = calibration(language)
        val total = lexicon(language).totalUnigramTokens.toDouble()
        return cal.meanLogFrequency - ln(total + config.addK * config.assumedVocabularySize)
    }

    fun calibratedScore(word: String, previous: String?, language: Language): Double {
        val p = contextualProbability(word, previous, language)
        val cal = calibration(language)
        return (ln(p) - referenceLogProbability(language)) / cal.stdLogFrequency
    }

    fun calibratedUnigramScore(word: String, language: Language): Double = calibratedScore(word, null, language)

    fun laneEvidence(word: String): Double {
        val floor = config.laneEvidenceFloor
        val zIS = if (icelandic.frequency(word) != null) max(calibratedUnigramScore(word, Language.icelandic), floor) else floor
        val zEN = if (english.frequency(word) != null) max(calibratedUnigramScore(word, Language.english), floor) else floor
        val margin = zIS - zEN
        val graded = max(0.0, abs(margin) - config.laneEvidenceDeadZone)
        if (graded <= 0.0) return 0.0
        val nats = min(config.laneEmissionTemperature * graded, config.laneEmissionMaxLogRatio)
        return if (margin > 0.0) nats else -nats
    }

    fun effectiveBigramContext(previous: String?): String? {
        val prev = previous ?: return null
        if (icelandic.frequency(prev) != null || english.frequency(prev) != null) return prev
        return acuteFoldShadowTwin(prev) ?: prev
    }

    fun contextualLift(word: String, previous: String?, language: Language): Double? {
        val prev = previous ?: return null
        val lexicon = lexicon(language)
        if (lexicon.frequency(prev) == null || lexicon.bigramFrequency(prev, word) == null) return null
        return calibratedScore(word, prev, language) - calibratedUnigramScore(word, language)
    }

    fun blendedScore(word: String, previous: String?, pIcelandic: Double): Double {
        val p = min(max(pIcelandic, 1e-6), 1 - 1e-6)
        val tau = config.calibrationTemperature
        val boost = personalBoost(word, previous)
        var zIS = calibratedScore(word, previous, Language.icelandic)
        var zEN = calibratedScore(word, previous, Language.english)
        if (boost > 0.0) {
            zIS = max(zIS, config.personalScoreFloor)
            zEN = max(zEN, config.personalScoreFloor)
        }
        val a = ln(p) + tau * zIS
        val b = ln(1 - p) + tau * zEN
        val m = max(a, b)
        return m + ln(exp(a - m) + exp(b - m)) + boost
    }

    fun blendedPairScore(first: String, second: String, previous: String?, pIcelandic: Double): Double {
        val p = min(max(pIcelandic, 1e-6), 1 - 1e-6)
        val tau = config.calibrationTemperature
        val firstBoost = personalBoost(first, previous)
        val secondBoost = personalBoost(second, first)
        fun z(word: String, prev: String?, language: Language, floored: Boolean): Double {
            val score = calibratedScore(word, prev, language)
            return if (floored) max(score, config.personalScoreFloor) else score
        }
        val a = ln(p) + tau * (z(first, previous, Language.icelandic, firstBoost > 0.0) + z(second, first, Language.icelandic, secondBoost > 0.0))
        val b = ln(1 - p) + tau * (z(first, previous, Language.english, firstBoost > 0.0) + z(second, first, Language.english, secondBoost > 0.0))
        val m = max(a, b)
        return m + ln(exp(a - m) + exp(b - m)) + firstBoost + secondBoost
    }

    fun warmUp() {
        for ((lexicon, cal) in listOf(icelandic to icelandicCalibration, english to englishCalibration)) {
            var previous: String? = null
            for ((index, word) in cal.sampleWords.withIndex()) {
                lexicon.frequency(word)
                previous?.let { lexicon.bigramFrequency(it, word) }
                if (index % 8 == 0) lexicon.continuations(word, 2)
                previous = word
            }
        }
        val paradigms = inflection.model?.paradigms
        if (paradigms != null) {
            for (word in icelandicCalibration.sampleWords) paradigms.bundles(word)
            for (first in WARMUP_ALPHABET) for (second in WARMUP_ALPHABET) paradigms.bundles("$first$second")
        }
        val morph = morphology
        if (morph != null) {
            for (word in icelandicCalibration.sampleWords) morph.isKnown(word)
            for (first in WARMUP_ALPHABET) for (second in WARMUP_ALPHABET) morph.isKnown("$first$second")
        }
    }

    private fun calibrationFor(profile: LexiconCalibrationProfile?, lexicon: Lexicon, addK: Double): LexiconCalibration =
        if (profile != null && profile.isValid && abs(profile.addK - addK) < 1e-12) LexiconCalibration(profile)
        else LexiconCalibration.measure(lexicon, addK)

    companion object {
        private val APOSTROPHES = setOf('\'', '\u2019')
        private val WARMUP_ALPHABET = "aábcdðeéfghiíjklmnoópqrstuúvwxyýzþæö".toList()
    }
}
