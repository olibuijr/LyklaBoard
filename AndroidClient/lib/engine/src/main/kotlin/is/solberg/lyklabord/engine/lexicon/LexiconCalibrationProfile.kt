package `is`.solberg.lyklabord.engine.lexicon

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Build-time frequency-distribution statistics shipped beside a lexicon. */
@Serializable
data class LexiconCalibrationProfile(
    val schema: String,
    val languageDataGeneration: String,
    val addK: Double,
    val meanLogFrequency: Double,
    val stdLogFrequency: Double,
    val warmupWords: List<String>,
) {
    /** Swift-compatible initializer; the schema is fixed by this type. */
    constructor(
        languageDataGeneration: String,
        addK: Double,
        meanLogFrequency: Double,
        stdLogFrequency: Double,
        warmupWords: List<String>,
    ) : this(SCHEMA, languageDataGeneration, addK, meanLogFrequency, stdLogFrequency, warmupWords)

    /** Whether this profile is safe to use for calibration. */
    val isValid: Boolean
        get() = schema == SCHEMA &&
            languageDataGeneration.isNotEmpty() &&
            addK.isFinite() &&
            meanLogFrequency.isFinite() &&
            stdLogFrequency.isFinite() &&
            stdLogFrequency >= MIN_STD_LOG_FREQUENCY &&
            warmupWords.isNotEmpty()

    companion object {
        const val SCHEMA: String = "lyklabord.lexicon-calibration.v1"

        /** Swift's `LexiconCalibrationProfile.schema` static property. */
        const val schema: String = SCHEMA

        private const val MIN_STD_LOG_FREQUENCY = 0.25
        private val json = Json {}

        /** Decode a profile with the strict default kotlinx.serialization JSON decoder. */
        fun decode(jsonText: String): LexiconCalibrationProfile =
            json.decodeFromString(jsonText)

        /** Alias for callers that prefer the source-file terminology. */
        fun fromJson(jsonText: String): LexiconCalibrationProfile = decode(jsonText)

        /** Decode a UTF-8 profile file. */
        fun fromFile(file: File): LexiconCalibrationProfile =
            decode(file.readText(Charsets.UTF_8))
    }
}
