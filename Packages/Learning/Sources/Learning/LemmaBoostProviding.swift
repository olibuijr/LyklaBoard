/// Wave-2 seam for lemma-level ranking boosts — deliberately just a
/// protocol stub in this package.
///
/// ## The hard constraint (PLAN, "Lemma-level learning constraint")
///
/// Icelandic surface forms overlap heavily across lemmas (avg 1.57 candidate
/// lemmas per form in lemma-is; "á" = preposition | river | eiga-form), so
/// **surface forms are the ground truth** for every count in this package.
/// `PersonalModel` performs NO lemma-level merging, ever — homograph credit
/// must never leak across lemmas.
///
/// Lemma generalization (e.g. learning "Jökull" should lift "Jökuls") is
/// allowed only as a ranking *boost*, computed OUTSIDE this package by
/// wave-2 engine code that has LemmaCore available, and only when:
/// - (a) the surface form is lemma-unambiguous, or
/// - (b) context (bigram/POS) disambiguates it,
/// otherwise distribute fractional credit or don't lift at all.
///
/// The engine's blender may hold a `LemmaBoostProviding` next to the
/// `PersonalLexicon`; this package ships no conformance. Counts stay
/// surface-keyed either way — the boost is additive scoring, never a merge.
public protocol LemmaBoostProviding: Sendable {
    /// Multiplicative ranking boost (1.0 = neutral) for a candidate surface
    /// form, derived from learned surface forms that share an UNAMBIGUOUS
    /// lemma with it. Implementations must return 1.0 whenever lemma
    /// attribution is ambiguous.
    func lemmaBoost(forCandidate surfaceForm: String) -> Double
}
