import EvalKit
import Foundation
import TypeEngine

/// `type-eval generate-safety` — derive a deterministic real-artifact safety
/// slice from dev rows. Clean identities prove known corpus words remain
/// byte-exact; hard negatives are generated typos that are themselves valid
/// words in the shipping language artifacts and therefore must be preserved
/// even when their original sentence context prefers another word.
func runGenerateSafetyCommand(_ args: [String]) {
    guard let repoRoot = ArtifactLoader.repoRoot() else {
        stderr("cannot locate repo root")
        exit(2)
    }
    var output = repoRoot.appendingPathComponent("data/eval/safety.jsonl")
    if let index = args.firstIndex(of: "--output"), index + 1 < args.count {
        output = URL(fileURLWithPath: args[index + 1])
    }

    let dev = loadSplit("dev", repoRoot)
    let engine: TypeEngine
    do {
        engine = try ArtifactLoader.loadEngine(
            config: ArtifactLoader.deterministicConfig(), log: { stderr($0) })
    } catch {
        stderr("\(error)")
        exit(2)
    }
    engine.warmUp()

    var candidates: [CorpusPair] = []
    for pair in dev where !pair.intended.contains(where: \.isWhitespace) {
        if isArtifactValid(pair.intended, lang: pair.lang, engine: engine) {
            candidates.append(
                CorpusPair(
                    typo: pair.intended,
                    intended: pair.intended,
                    context: pair.context,
                    lang: pair.lang,
                    category: "clean_identity",
                    expectation: .preserve
                ))
        }
        if !pair.typo.contains(where: \.isWhitespace),
            pair.typo.caseInsensitiveCompare(pair.intended) != .orderedSame,
            isArtifactValid(pair.typo, lang: pair.lang, engine: engine)
        {
            candidates.append(
                CorpusPair(
                    typo: pair.typo,
                    intended: pair.intended,
                    context: pair.context,
                    lang: pair.lang,
                    category: "valid_word_hard_negative",
                    expectation: .preserve
                ))
        }
    }

    var selected: [CorpusPair] = []
    for lang in ["is", "en"] {
        selected += sample(
            candidates.filter { $0.lang == lang && $0.category == "clean_identity" },
            limit: 200)
        selected += sample(
            candidates.filter {
                $0.lang == lang && $0.category == "valid_word_hard_negative"
            },
            limit: 100)
    }
    selected.sort { stableKey($0) < stableKey($1) }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        let lines = try selected.map { pair in
            String(decoding: try encoder.encode(pair), as: UTF8.self)
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(
            to: output, options: .atomic)
    } catch {
        stderr("cannot write safety corpus: \(error)")
        exit(2)
    }

    for lang in ["is", "en"] {
        let clean = selected.filter { $0.lang == lang && $0.category == "clean_identity" }.count
        let hard = selected.filter {
            $0.lang == lang && $0.category == "valid_word_hard_negative"
        }.count
        stderr("  \(lang): \(clean) clean identities, \(hard) valid-word hard negatives")
    }
    print("wrote \(selected.count) rows to \(output.path)")
}

private func isArtifactValid(_ word: String, lang: String, engine: TypeEngine) -> Bool {
    let diagnostics = engine.laneDiagnostics(for: word)
    switch lang {
    case "is": return diagnostics.frequencyIS != nil || diagnostics.binKnown
    case "en": return diagnostics.frequencyEN != nil
    default: return false
    }
}

private func sample(_ pairs: [CorpusPair], limit: Int) -> [CorpusPair] {
    var seen = Set<String>()
    let unique = pairs.filter { pair in seen.insert(stableKey(pair)).inserted }
    return Array(
        unique.sorted {
            let left = stableHash(stableKey($0))
            let right = stableHash(stableKey($1))
            return left == right ? stableKey($0) < stableKey($1) : left < right
        }.prefix(limit))
}

private func stableKey(_ pair: CorpusPair) -> String {
    [pair.lang, pair.category, pair.typo.lowercased(), pair.intended.lowercased()]
        .joined(separator: "\u{1f}")
        + "\u{1e}" + pair.context.map { $0.lowercased() }.joined(separator: "\u{1f}")
}

/// FNV-1a is sufficient here: deterministic ordering, not cryptography.
private func stableHash(_ text: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash
}
