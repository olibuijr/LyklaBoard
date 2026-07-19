package `is`.solberg.lyklabord.engine

import `is`.solberg.lyklabord.engine.config.CandidateProvider
import java.util.Locale

/**
 * Decision trace of one `Corrector.correct` call. Port of Swift
 * `Packages/TypeEngine/Sources/TypeEngine/CorrectionTrace.swift`.
 */
class CorrectionTrace {
    /** One scored candidate (top of the pool). */
    data class Candidate(
        val word: String,
        /** Every bounded generation pass that reached this word. */
        val providers: List<CandidateProvider>,
        /** Lane-priced channel cost (nats). */
        val costTotal: Double,
        /** Error-class ops on the optimal alignment. */
        val errorOps: Int,
        /** Restoration-class ops. */
        val restorationOps: Int,
        /** Additive channel contribution to the ranker (= -costTotal). */
        val channelContribution: Double,
        /** Blended language score S_lang. */
        val languageScore: Double,
        /** Additive weighted language contribution (= λ·S_lang). */
        val languageContribution: Double,
        /** Context-free blended language score, exposed for comparison. */
        val unigramLanguageScore: Double?,
        /** Contextual score minus the context-free score. */
        val contextEvidence: Double?,
        /** Additive personal prior before language weighting. */
        val personalEvidence: Double,
        /** Additive governor/case-fit contribution. */
        val morphologyContribution: Double,
        /** Additive compound-head typicality contribution. */
        val compoundContribution: Double,
        /** Additive hard-precedence adjustment. */
        val precedenceContribution: Double,
        /** Final ranking score. */
        val score: Double,
    )

    /** Pool-wide visibility into one provider, including an active ablation. */
    data class ProviderSummary(
        val provider: CandidateProvider,
        val admittedCandidateCount: Int,
        val disabled: Boolean,
    )

    /** One evaluated gate: value vs threshold, pass/fail. */
    data class Gate(
        val name: String,
        val detail: String,
        val pass: Boolean,
    )

    // Populated by Corrector.correct:
    var typed: String = ""
        internal set
    var previousWord: String? = null
        internal set
    var pIcelandic: Double = 0.5
        internal set
    var typedIsValid: Boolean = false
        internal set
    /** Which auto-apply rule the top candidate was judged under. */
    var rule: String = "none"
        internal set
    /** Score margin of the winner over the runner-up (nats). */
    var margin: Double? = null
        internal set
    /** The margin threshold actually required (before the tap veto factor). */
    var requiredMargin: Double? = null
        internal set
    /** Aggregate tap-confidence veto multiplier on the margin (1 = no taps). */
    var tapVetoFactor: Double = 1.0
        internal set
    var gates: List<Gate> = emptyList()
        internal set
    var autocorrect: Boolean = false
        internal set
    var notes: List<String> = emptyList()
        internal set
    var candidates: List<Candidate> = emptyList()
        internal set
    var providerSummaries: List<ProviderSummary> = emptyList()
        internal set

    internal fun gate(name: String, detail: String, pass: Boolean) {
        gates = gates + Gate(name = name, detail = detail, pass = pass)
    }

    internal fun note(text: String) {
        notes = notes + text
    }

    /** Multi-line human-readable dump (the REPL `:why` output). */
    val report: String
        get() {
            val lines = mutableListOf<String>()
            val prev = previousWord?.let { "\"$it\"" } ?: "-"
            lines += "decide \"$typed\"  prev=$prev  P(IS)=${format("%.3f", pIcelandic)}" +
                "  typedIsValid=$typedIsValid"
            if (candidates.isEmpty()) {
                lines += "  (no scored candidates)"
            }
            candidates.forEachIndexed { index, candidate ->
                val winnerMargin = margin
                val marginText = if (index == 0 && winnerMargin != null) {
                    "  margin=${format("%+.3f", winnerMargin)}"
                } else {
                    ""
                }
                lines += "  #${index + 1} ${candidate.word}" +
                    "  via=${candidate.providers.joinToString(",") { it.rawValue }}" +
                    "  cost=${format("%.3f", candidate.costTotal)}" +
                    " (err=${candidate.errorOps} rest=${candidate.restorationOps})" +
                    "  lang=${format("%+.3f", candidate.languageScore)}" +
                    "  score=${format("%+.3f", candidate.score)}" +
                    marginText
                lines += "       signals channel=${format("%+.3f", candidate.channelContribution)}" +
                    " language=${format("%+.3f", candidate.languageContribution)}" +
                    " morph=${format("%+.3f", candidate.morphologyContribution)}" +
                    " compound=${format("%+.3f", candidate.compoundContribution)}" +
                    " precedence=${format("%+.3f", candidate.precedenceContribution)}" +
                    "  evidence context=${candidate.contextEvidence?.let { format("%+.3f", it) } ?: "-"}" +
                    " personal=${format("%+.3f", candidate.personalEvidence)}"
            }
            val activeProviders = providerSummaries.filter { it.admittedCandidateCount > 0 }
            if (activeProviders.isNotEmpty()) {
                lines += "  providers " + activeProviders.joinToString(" ") {
                    "${it.provider.rawValue}=${it.admittedCandidateCount}"
                }
            }
            val disabled = providerSummaries.filter { it.disabled }.map { it.provider.rawValue }
            if (disabled.isNotEmpty()) {
                lines += "  ablated ${disabled.joinToString(",")}"
            }
            var decision = "  rule=$rule"
            val required = requiredMargin
            if (required != null) {
                decision += "  requiredMargin=${format("%.3f", required)}"
                if (tapVetoFactor != 1.0) {
                    decision += " x tapVeto ${format("%.2f", tapVetoFactor)}" +
                        " = ${format("%.3f", required * tapVetoFactor)}"
                }
            } else if (tapVetoFactor != 1.0) {
                decision += "  tapVeto=${format("%.2f", tapVetoFactor)}"
            }
            lines += decision
            gates.forEach { gate ->
                lines += "  ${if (gate.pass) "PASS" else "FAIL"}  ${gate.name}: ${gate.detail}"
            }
            notes.forEach { note ->
                lines += "  note  $note"
            }
            lines += "  => autocorrect ${if (autocorrect) "FIRES" else "does NOT fire"}"
            return lines.joinToString("\n")
        }

    private fun format(pattern: String, value: Any): String = String.format(Locale.ROOT, pattern, value)
}
