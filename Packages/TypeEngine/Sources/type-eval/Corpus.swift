import EvalKit
import Foundation
import TypeEngine

func stderr(_ message: String) {
    FileHandle.standardError.write(Data("[type-eval] \(message)\n".utf8))
}

/// `type-eval corpus <dev|heldout>` — replay a corpus split through the real
/// artifacts and print the per-category / per-language / overall table.
///
/// Debug flags (dev-iteration tooling, no effect on the table):
///   --dump <failures|false-ac>   per-pair dump instead of the table
///   --category <name>            restrict the dump to one category
func runCorpusCommand(_ args: [String]) {
    guard let split = args.first, split == "dev" || split == "heldout" else {
        stderr("usage: type-eval corpus <dev|heldout> [--dump failures|false-ac] [--category c]")
        exit(2)
    }
    var dumpMode: String?
    var dumpCategory: String?
    var baseConfig = EngineConfig()
    var rest = Array(args.dropFirst())
    while let flag = rest.first {
        rest.removeFirst()
        switch flag {
        case "--dump": dumpMode = rest.isEmpty ? "failures" : rest.removeFirst()
        case "--category": dumpCategory = rest.isEmpty ? nil : rest.removeFirst()
        case "--config":
            guard !rest.isEmpty else {
                stderr("--config requires a path")
                exit(2)
            }
            do {
                (baseConfig, _) = try ConfigOverrides.load(
                    from: URL(fileURLWithPath: rest.removeFirst()))
            } catch {
                stderr("config error: \(error)")
                exit(2)
            }
        default:
            stderr("unknown flag \(flag)")
            exit(2)
        }
    }
    if split == "heldout" {
        stderr(
            "REPORT-ONLY: heldout.jsonl must never be tuned against — only reported "
                + "(see scores/README.md).")
    }
    guard let url = ArtifactLoader.corpusURL(split: split) else {
        stderr("cannot locate repo root (data/eval/\(split).jsonl)")
        exit(2)
    }
    let pairs: [CorpusPair]
    do {
        pairs = try Corpus.loadCorpus(at: url)
    } catch {
        stderr("\(error)")
        exit(2)
    }
    let engine: TypeEngine
    do {
        engine = try ArtifactLoader.loadEngine(
            config: ArtifactLoader.deterministicConfig(base: baseConfig), log: { stderr($0) })
    } catch {
        stderr("\(error)")
        exit(2)
    }
    engine.warmUp()
    if let dumpMode {
        dumpCorpusPairs(engine: engine, pairs: pairs, mode: dumpMode, category: dumpCategory)
        return
    }
    let result = CorpusEval.run(engine: engine, pairs: pairs, split: split)
    printCorpusResult(result)
}

/// Per-pair debug dump (mirrors CorpusEval.run's replay exactly): one line
/// per selected pair with the typo, intended, tail context and the top
/// suggestions (with autocorrect flags). `mode` selects which pairs print:
///   failures  — top-1 misses
///   false-ac  — auto-apply fired on a wrong top candidate
func dumpCorpusPairs(engine: TypeEngine, pairs: [CorpusPair], mode: String, category: String?) {
    for pair in pairs {
        if let category, pair.category != category { continue }
        engine.resetLanguagePosterior()
        for word in pair.context { engine.confirmWord(word) }
        let context = pair.context.joined(separator: " ")
        let suggestions = engine.suggestions(context: context, currentWord: pair.typo, limit: 3)
        let texts = suggestions.map(\.text)
        let fired = suggestions.first?.isAutocorrect == true
        let top1 = texts.first == pair.intended
        switch mode {
        case "failures": if top1 { continue }
        case "false-ac": if !(fired && !top1) { continue }
        default:
            stderr("unknown dump mode \(mode)")
            exit(2)
        }
        let rendered = suggestions.map { s in
            "\(s.text)\(s.isAutocorrect ? "*" : "")\(s.isRestoration ? "~" : "")"
        }.joined(separator: " | ")
        let tail = pair.context.suffix(3).joined(separator: " ")
        print(
            "[\(pair.category)/\(pair.lang)]\(fired ? " AC" : "") "
                + "typo=\(pair.typo) intended=\(pair.intended) ctx=…\(tail) -> \(rendered)")
    }
}

func pct(_ tally: CorpusTally, _ n: Int) -> String {
    tally.total == 0 ? "  n/a" : String(format: "%5.1f%%", tally.percent(n))
}

func printCorpusResult(_ result: CorpusResult, label: String? = nil) {
    let header = label ?? "corpus \(result.split)"
    print(
        "\(header) — \(result.overall.total) pairs, "
            + "\(String(format: "%.1f", result.runtimeSeconds)) s "
            + "(\(String(format: "%.2f", result.runtimeSeconds * 1000 / Double(max(result.overall.total, 1)))) ms/pair)")
    print("")
    print("category              n   top-1    top-3   ac-fired  false-ac")
    for category in result.byCategory.keys.sorted() {
        let t = result.byCategory[category]!
        print(
            "\(category.padding(toLength: 18, withPad: " ", startingAt: 0))"
                + String(format: "%5d", t.total)
                + "  \(pct(t, t.top1))  \(pct(t, t.top3))"
                + "   \(pct(t, t.autocorrectFired))   \(pct(t, t.falseAutocorrect))")
    }
    print(String(repeating: "-", count: 60))
    for lang in result.byLang.keys.sorted() {
        let t = result.byLang[lang]!
        print(
            "lang \(lang.padding(toLength: 13, withPad: " ", startingAt: 0))"
                + String(format: "%5d", t.total)
                + "  \(pct(t, t.top1))  \(pct(t, t.top3))"
                + "   \(pct(t, t.autocorrectFired))   \(pct(t, t.falseAutocorrect))")
    }
    let o = result.overall
    print(
        "all               "
            + String(format: "%5d", o.total)
            + "  \(pct(o, o.top1))  \(pct(o, o.top3))"
            + "   \(pct(o, o.autocorrectFired))   \(pct(o, o.falseAutocorrect))")
}
