import Foundation
import TypeEngine

// type-eval: micro-evaluation harness for the TypeEngine corrector.
//
// Reads a TSV of (typo, expected, lang[, context]) rows — bundled fixture
// by default, or a path passed as argv[1] — runs each typo through a
// TypeEngine seeded with small realistic DictLexicon doubles, and reports:
//   * top-1 / top-3 accuracy (per language/category and overall)
//   * autocorrect firing rate and false-autocorrect rate
//     (autocorrect fired but the replacement is not the expected word)
//   * valid-word safety: every *expected* word typed verbatim must produce
//     zero isAutocorrect=true suggestions (the conservatism invariant)
//
// Lane-relaxation categories (PLAN.md "Lane relaxation profiles"):
//   accentlazy   — accent-stripped Icelandic words (generated from
//                  data/eval/sentences.is.txt, see AccentWordlists docs),
//                  judged inside a SATURATED Icelandic lane (P(IS) primed
//                  to the 0.9 ceiling); ac-fired here IS the restoration
//                  rate. Rows may carry a 4th column: previous-word context.
//   accentguard  — collision skeletons in skeleton-meaning contexts
//                  (typo == expected): any autocorrect fired is a FALSE
//                  RESTORATION (target: 0), the row passes when nothing
//                  fires. Same saturated IS lane.
//   apos         — English contraction folding (dont→don't), saturated EN
//                  lane; aposguard mirrors accentguard (cant, ill, well).
// These categories run on a SECOND engine (base + AccentWordlists) so the
// original categories stay byte-identical — extending a lexicon moves its
// calibration sample. This harness grows with the project; nothing here
// touches real .lex files.

struct EvalCase {
    let typo: String
    let expected: String
    let lang: String
    let context: String
}

func loadCases() -> [EvalCase] {
    let url: URL
    if CommandLine.arguments.count > 1 {
        url = URL(fileURLWithPath: CommandLine.arguments[1])
    } else if let bundled = Bundle.module.url(forResource: "eval-fixture", withExtension: "tsv") {
        url = bundled
    } else {
        FileHandle.standardError.write(Data("error: bundled eval-fixture.tsv not found\n".utf8))
        exit(1)
    }
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
        FileHandle.standardError.write(Data("error: cannot read \(url.path)\n".utf8))
        exit(1)
    }
    var cases: [EvalCase] = []
    for line in raw.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let cols = trimmed.split(separator: "\t").map(String.init)
        guard cols.count == 3 || cols.count == 4 else {
            FileHandle.standardError.write(Data("warning: skipping malformed line: \(trimmed)\n".utf8))
            continue
        }
        cases.append(
            EvalCase(
                typo: cols[0], expected: cols[1], lang: cols[2],
                context: cols.count == 4 ? cols[3] : ""
            )
        )
    }
    return cases
}

struct Tally {
    var total = 0
    var top1 = 0
    var top3 = 0
    var autocorrectFired = 0
    var falseAutocorrect = 0

    func pct(_ n: Int) -> String {
        total == 0 ? "  n/a" : String(format: "%5.1f%%", 100.0 * Double(n) / Double(total))
    }
}

let cases = loadCases()

// Base engine: original categories, neutral posterior throughout — each row
// judged language-blind exactly like the first word in a fresh text field.
let baseEngine = TypeEngine(
    icelandic: DictLexicon(
        unigrams: EvalWordlists.icelandic,
        bigrams: EvalWordlists.icelandicBigrams
    ),
    english: DictLexicon(
        unigrams: EvalWordlists.english,
        bigrams: EvalWordlists.englishBigrams
    ),
    morphologyProvider: nil
)

// Accent engine: base + lane-relaxation pack (separate engine — see header).
let accentEngine = TypeEngine(
    icelandic: DictLexicon(
        unigrams: AccentWordlists.merged(EvalWordlists.icelandic, AccentWordlists.icelandic),
        bigrams: AccentWordlists.merged(
            EvalWordlists.icelandicBigrams, AccentWordlists.icelandicBigrams)
    ),
    english: DictLexicon(
        unigrams: AccentWordlists.merged(EvalWordlists.english, AccentWordlists.english),
        bigrams: AccentWordlists.merged(
            EvalWordlists.englishBigrams, AccentWordlists.englishBigrams)
    ),
    morphologyProvider: nil
)

enum LanePriming: Equatable {
    case neutral
    case icelandic
    case english
}

/// Engine + lane priming per category.
func setup(for lang: String) -> (engine: TypeEngine, lane: LanePriming) {
    switch lang {
    case "accentlazy", "accentguard": return (accentEngine, .icelandic)
    case "apos", "aposguard": return (accentEngine, .english)
    default: return (baseEngine, .neutral)
    }
}

/// Drive the lane posterior to its ceiling/floor with strong-lane commits
/// (the harness twin of "typing an Icelandic/English sentence first").
func prime(_ engine: TypeEngine, lane: LanePriming) {
    engine.resetLanguagePosterior()
    let words: [String]
    switch lane {
    case .neutral: return
    case .icelandic: words = ["og", "að", "er", "og", "að"]
    case .english: words = ["the", "and", "with", "the", "and"]
    }
    for word in words { engine.confirmWord(word) }
}

var perLang: [String: Tally] = [:]
var failures: [(EvalCase, [String])] = []
var currentSetup: (engine: TypeEngine, lane: LanePriming) = (baseEngine, .neutral)
prime(baseEngine, lane: .neutral)

let clock = ContinuousClock()
let elapsed = clock.measure {
    for c in cases {
        let wanted = setup(for: c.lang)
        if wanted.engine !== currentSetup.engine || wanted.lane != currentSetup.lane {
            currentSetup = wanted
            prime(wanted.engine, lane: wanted.lane)
        }
        let suggestions = wanted.engine.suggestions(
            context: c.context, currentWord: c.typo, limit: 3)
        var tally = perLang[c.lang, default: Tally()]
        tally.total += 1
        let texts = suggestions.map(\.text)
        let fired = suggestions.first?.isAutocorrect == true
        if c.typo == c.expected {
            // Collision-guard row (skeleton-meaning context): the row
            // passes when NOTHING auto-applies; any firing is a false
            // restoration.
            if fired {
                tally.autocorrectFired += 1
                tally.falseAutocorrect += 1
                failures.append((c, texts))
            } else {
                tally.top1 += 1
                tally.top3 += 1
            }
        } else {
            if texts.first == c.expected { tally.top1 += 1 }
            if texts.contains(c.expected) { tally.top3 += 1 }
            if fired {
                tally.autocorrectFired += 1
                if texts.first != c.expected { tally.falseAutocorrect += 1 }
            }
            if texts.first != c.expected {
                failures.append((c, texts))
            }
        }
        perLang[c.lang] = tally
    }
}

// Conservatism control: type every expected word verbatim; none may
// auto-replace (they are all in-lexicon). Multi-word expectations (the
// "split" category: "hello world") are checked word-by-word — each half is
// a valid word the user could type on its own. Lane-relaxation categories
// are checked on THEIR engine at THEIR primed lane — the stricter reading
// of the invariant ("exact input wins by ε" must hold inside a saturated
// lane too).
var validWordViolations: [String] = []
var safetyChecked = 0
var safetySetups: [String: (engine: TypeEngine, lane: LanePriming, words: Set<String>)] = [:]
for c in cases {
    let key = "\(setup(for: c.lang).lane)"
    let s = setup(for: c.lang)
    var entry = safetySetups[key] ?? (s.engine, s.lane, [])
    for word in c.expected.split(separator: " ").map(String.init) {
        entry.words.insert(word)
    }
    safetySetups[key] = entry
}
for (_, entry) in safetySetups.sorted(by: { $0.key < $1.key }) {
    prime(entry.engine, lane: entry.lane)
    for word in entry.words.sorted() {
        safetyChecked += 1
        let suggestions = entry.engine.suggestions(context: "", currentWord: word, limit: 3)
        if suggestions.contains(where: { $0.isAutocorrect }) {
            validWordViolations.append(word)
        }
    }
}

// ---- Report ----------------------------------------------------------------

var overall = Tally()
for tally in perLang.values {
    overall.total += tally.total
    overall.top1 += tally.top1
    overall.top3 += tally.top3
    overall.autocorrectFired += tally.autocorrectFired
    overall.falseAutocorrect += tally.falseAutocorrect
}

let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
print("type-eval — \(overall.total) cases, \(String(format: "%.1f", ms)) ms total")
print("")
print("lang     n   top-1    top-3   ac-fired  false-ac")
for (lang, tally) in perLang.sorted(by: { $0.key < $1.key }) {
    print(
        "\(lang.padding(toLength: 5, withPad: " ", startingAt: 0)) "
            + String(format: "%4d", tally.total)
            + "  \(tally.pct(tally.top1))  \(tally.pct(tally.top3))"
            + "   \(tally.pct(tally.autocorrectFired))   \(tally.pct(tally.falseAutocorrect))"
    )
}
print(
    "all   "
        + String(format: "%4d", overall.total)
        + "  \(overall.pct(overall.top1))  \(overall.pct(overall.top3))"
        + "   \(overall.pct(overall.autocorrectFired))   \(overall.pct(overall.falseAutocorrect))"
)
print("")
if let lazy = perLang["accentlazy"] {
    let guardTally = perLang["accentguard"] ?? Tally()
    print(
        "accent restoration rate \(lazy.pct(lazy.autocorrectFired)) "
            + "(top-1 \(lazy.pct(lazy.top1))); "
            + "false restoration on \(guardTally.total) collision skeletons: "
            + "\(guardTally.pct(guardTally.falseAutocorrect))"
    )
}
if validWordViolations.isEmpty {
    print(
        "valid-word safety: OK — 0/\(safetyChecked) expected words auto-replaced when typed verbatim (incl. at primed lanes)"
    )
} else {
    print("valid-word safety: VIOLATIONS — \(validWordViolations.sorted().joined(separator: ", "))")
}

if !failures.isEmpty {
    print("\ntop-1 misses:")
    for (c, texts) in failures {
        let got = texts.isEmpty ? "(none)" : texts.joined(separator: ", ")
        print("  [\(c.lang)] \(c.typo) -> expected \(c.expected), got \(got)")
    }
}

exit(validWordViolations.isEmpty ? 0 : 1)
