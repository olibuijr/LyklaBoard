package `is`.solberg.lyklabord.engine.learning

/** Wave-2 seam for additive lemma-level ranking boosts. */
fun interface LemmaBoostProviding {
    fun lemmaBoost(forCandidate: String): Double
}
