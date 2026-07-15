import TypeEngine

/// Dictionary-backed morphology fake (stands in for BÍN's BinaryLemmatizer).
final class FakeMorphology: MorphologyProviding {
    private let words: Set<String>
    init(_ words: Set<String>) { self.words = words }
    func isKnown(_ word: String) -> Bool { words.contains(word) }
}

enum Fixtures {
    /// Small Icelandic lexicon.
    static let icelandic = DictLexicon(
        unigrams: [
            "og": 2000,
            "að": 1800,
            "er": 1500,
            "ekki": 900,
            "borða": 300,
            "hestur": 500,
            "hestar": 100,
            "hesti": 60,
            "hús": 400,
            "íslenska": 250,
            "góðan": 200,
            "dag": 100,
            "daginn": 90,
            "takk": 350,
            "gott": 150,
            "veður": 200,
            "vetur": 300,
            "greeþ": 100,  // synthetic: bilingual-ambiguity twin of "green"
        ],
        bigrams: [
            "góðan dag": 50,
            "gott veður": 30,
        ]
    )

    /// Small English lexicon (same total as icelandic is not required; the
    /// bilingual test uses the dedicated twins below).
    static let english = DictLexicon(
        unigrams: [
            "the": 2000,
            "and": 1500,
            "with": 900,
            "which": 600,
            "ten": 50,
            "he": 700,
            "hello": 200,
            "green": 100,  // synthetic twin of "greeþ"
        ],
        bigrams: [
            "with the": 120
        ]
    )

    static func engine(
        morphology: MorphologyProviding? = nil,
        config: EngineConfig = EngineConfig()
    ) -> TypeEngine {
        TypeEngine(
            icelandic: icelandic,
            english: english,
            morphologyProvider: morphology,
            config: config
        )
    }
}
