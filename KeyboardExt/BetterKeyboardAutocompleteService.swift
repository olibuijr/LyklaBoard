//
//  BetterKeyboardAutocompleteService.swift
//  BetterKeyboardExt
//
//  M1: bridges TypeEngine (bilingual IS/EN corrector + predictor) into
//  KeyboardKit's `AutocompleteService`. KeyboardKit calls
//  `autocomplete(_:)` with all text before the input cursor
//  (`documentContextBeforeInput`) on every text change; the returned
//  `Autocomplete.ServiceResult` is synced into `AutocompleteContext`, which
//  the standard `Autocomplete.Toolbar` renders, and suggestions marked
//  `.autocorrect` are auto-applied by `KeyboardAction.StandardActionHandler`
//  when the user types a word/sentence delimiter (space etc.).
//
//  Privacy: no networking, no typed content in logs (only timings/counts).
//

import Foundation
import KeyboardKit
import LemmaCore
import Lexicon
import TypeEngine

final class BetterKeyboardAutocompleteService: AutocompleteService {

    // MARK: - Threading

    /// All engine access is funneled through this serial queue:
    ///
    /// - `TypeEngine` is NOT thread-safe (it owns a mutable running language
    ///   posterior that `confirmWord` updates), so every call — bootstrap,
    ///   suggestions, confirmWord — happens on this one queue.
    /// - Utility QoS keeps the mmap bootstrap and per-keystroke work off the
    ///   main thread. This is the launch-flicker mitigation recorded in
    ///   PLAN.md: `viewDidLoad` only enqueues the loader; no mmap open or
    ///   file I/O ever runs on the main thread.
    private let queue = DispatchQueue(
        label: "is.betterkeyboard.typeengine",
        qos: .utility
    )

    // MARK: - Queue-confined state (touch ONLY on `queue`)

    private var engine: TypeEngine?
    private var bootstrapFailed = false
    /// The `currentWord` parsed from the previous `autocomplete(_:)` call,
    /// used to detect the word-commit transition (see `confirmIfCommitted`).
    private var previousCurrentWord = ""

    // MARK: - Init

    init() {
        // Kick the bootstrap immediately (but asynchronously, off-main) so
        // the engine is usually ready by the first keystroke. Until it is,
        // `autocomplete(_:)` just returns empty suggestions.
        queue.async { [weak self] in
            self?.bootstrapIfNeeded()
        }
    }

    // MARK: - AutocompleteService

    /// Single Icelandic layout; mixed IS/EN typing is handled inside
    /// TypeEngine's bilingual blender, not via locale switching.
    var locale: Locale = .init(identifier: "is")

    func autocomplete(_ text: String) async throws -> Autocomplete.ServiceResult {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    return continuation.resume(
                        returning: .init(inputText: text, suggestions: [])
                    )
                }
                continuation.resume(returning: self.performAutocomplete(text))
            }
        }
    }

    // Word learning/ignoring is M2 (LearningStore + personal dictionary).
    // `StandardActionHandler` auto-learns tapped `.unknown` suggestions via
    // `learnWord`, so these must exist but stay no-ops for now.
    var canIgnoreWords: Bool { false }
    var canLearnWords: Bool { false }
    var ignoredWords: [String] { [] }
    var learnedWords: [String] { [] }
    func hasIgnoredWord(_ word: String) -> Bool { false }
    func hasLearnedWord(_ word: String) -> Bool { false }
    func ignoreWord(_ word: String) {}
    func learnWord(_ word: String) {}
    func removeIgnoredWord(_ word: String) {}
    func unlearnWord(_ word: String) {}

    // MARK: - Bootstrap (on `queue`)

    /// Open the language artifacts from the extension bundle and build the
    /// engine. mmap-backed (`.alwaysMapped`) — file pages are clean/lazily
    /// paged, so this is fast (~1ms per artifact) and nearly free against
    /// the extension's dirty-memory jetsam cap (see data/README.md).
    private func bootstrapIfNeeded() {
        guard engine == nil, !bootstrapFailed else { return }
        let bundle = Bundle(for: Self.self)
        let start = CFAbsoluteTimeGetCurrent()
        do {
            guard
                let enURL = bundle.url(forResource: "en", withExtension: "lex"),
                let isURL = bundle.url(forResource: "is", withExtension: "lex")
            else {
                bootstrapFailed = true
                NSLog("[better-keyboard] autocomplete bootstrap FAILED: .lex artifacts missing from extension bundle")
                return
            }
            let english = try FrequencyLexicon(contentsOf: enURL)
            let icelandic = try FrequencyLexicon(contentsOf: isURL)

            // BÍN morphology is optional for the engine; degrade gracefully
            // (frequency-only validation) if the binary is missing/corrupt.
            var morphology: BinaryLemmatizer?
            if let binURL = bundle.url(forResource: "lemma-is", withExtension: "bin") {
                morphology = try? BinaryLemmatizer(contentsOf: binURL)
                if morphology == nil {
                    NSLog("[better-keyboard] lemma-is.bin failed to load; continuing without morphology")
                }
            } else {
                NSLog("[better-keyboard] lemma-is.bin missing from extension bundle; continuing without morphology")
            }

            engine = TypeEngine(
                icelandic: icelandic,
                english: english,
                morphology: morphology
            )
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            NSLog(
                "[better-keyboard] TypeEngine ready in %.1f ms (is: %d unigrams, en: %d unigrams, morphology: %@)",
                ms,
                icelandic.unigramCount,
                english.unigramCount,
                morphology == nil ? "off" : "on"
            )
        } catch {
            bootstrapFailed = true
            NSLog("[better-keyboard] autocomplete bootstrap FAILED: %@", String(describing: error))
        }
    }

    // MARK: - Autocomplete (on `queue`)

    private func performAutocomplete(_ text: String) -> Autocomplete.ServiceResult {
        bootstrapIfNeeded()
        // Engine still loading (or permanently failed): stay silent. The
        // toolbar simply shows no suggestions for the first keystroke(s).
        guard let engine else {
            return .init(inputText: text, suggestions: [])
        }

        let (context, currentWord) = Self.splitCurrentWord(of: text)
        confirmIfCommitted(context: context, currentWord: currentWord, engine: engine)
        previousCurrentWord = currentWord

        // Require ≥2 typed characters before completion/correction-style
        // suggestions: single-letter prefixes hit the 20k-entry completion
        // scan cap on is.lex (~2.8 ms/call — data/README.md bench); 2+ char
        // prefixes have far smaller ranges. Empty word = next-word
        // prediction, which is cheap.
        if currentWord.count == 1 {
            return .init(inputText: text, suggestions: [])
        }

        let suggestions = engine.suggestions(
            context: context,
            currentWord: currentWord,
            limit: 3
        )
        return .init(
            inputText: text,
            suggestions: suggestions.map(Self.bridge)
        )
    }

    /// Map a TypeEngine suggestion onto KeyboardKit's model. `.autocorrect`
    /// is what makes `StandardActionHandler` auto-apply the suggestion when
    /// the user types a word delimiter (space-commit); TypeEngine only sets
    /// `isAutocorrect` on its top candidate under its conservatism rules, so
    /// the mapping is direct.
    private static func bridge(_ suggestion: Suggestion) -> Autocomplete.Suggestion {
        Autocomplete.Suggestion(
            text: suggestion.text,
            type: suggestion.isAutocorrect ? .autocorrect : .regular,
            additionalInfo: ["confidence": String(format: "%.3f", suggestion.confidence)]
        )
    }

    // MARK: - Word commit (on `queue`)

    /// Minimal word-commit detection for the language posterior (full
    /// learning integration is M2): a word counts as committed when the
    /// previous call had a word in progress and this call doesn't — i.e. the
    /// user just typed a delimiter (space/period/…) after it, or applied a
    /// toolbar suggestion / autocorrect (both insert the word + a space,
    /// which lands here on the next text change). The confirmed word is read
    /// back out of the committed text so it reflects any applied correction,
    /// not the raw typed fragment.
    private func confirmIfCommitted(
        context: String,
        currentWord: String,
        engine: TypeEngine
    ) {
        guard currentWord.isEmpty, !previousCurrentWord.isEmpty else { return }
        guard let committed = Self.lastWord(in: context) else { return }
        engine.confirmWord(committed)
    }

    // MARK: - Text parsing

    /// Word delimiters: KeyboardKit's canonical set (punctuation, brackets,
    /// whitespace, newlines). Note apostrophes are NOT delimiters, so
    /// English contractions stay one word.
    private static let delimiters: Set<Character> = Set(
        String.wordDelimiters.compactMap(\.first)
    )

    /// Split the proxy-provided text (everything before the cursor) into
    /// (committed context, word currently being typed). The current word is
    /// the trailing run of non-delimiter characters; empty when the text
    /// ends with a delimiter (word just committed / sentence start).
    static func splitCurrentWord(of text: String) -> (context: String, currentWord: String) {
        guard let index = text.lastIndex(where: { delimiters.contains($0) }) else {
            return (context: "", currentWord: text)
        }
        let wordStart = text.index(after: index)
        return (
            context: String(text[..<wordStart]),
            currentWord: String(text[wordStart...])
        )
    }

    /// Trailing word of committed text, with surrounding delimiters
    /// stripped; nil if there is none.
    static func lastWord(in text: String) -> String? {
        let word = text
            .split(whereSeparator: { delimiters.contains($0) })
            .last
            .map(String.init)
        guard let word, !word.isEmpty else { return nil }
        return word
    }
}
