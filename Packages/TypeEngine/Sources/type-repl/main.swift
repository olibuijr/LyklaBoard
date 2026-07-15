import Foundation
import Learning
import TypeEngine

// type-repl: headless macOS harness for the TypeEngine typing pipeline,
// running the REAL data artifacts through the exact same TypingSession the
// keyboard extension uses (via a simulated UITextDocumentProxy window).
//
//   swift run -c release type-repl                       interactive REPL
//   swift run -c release type-repl run <file.scenarios>  batch expectations
//   swift run -c release type-repl bench                 latency percentiles
//
// Flags (all modes):
//   --en <path>      en.lex override        (default <repo>/data/en/en.lex)
//   --is <path>      is.lex override        (default <repo>/data/is/is.lex)
//   --lemma <path>   lemma-is.bin override  (default <repo>/data/is/lemma-is.bin)
//   --no-morph       skip BÍN morphology
//   --limit <n>      suggestion bar size    (default 5; bench default 3 = extension)
//   --personal <p>   personal-model JSON (Learning.PersonalModel file, the
//                    same personal-model.json the app writes to the App
//                    Group container) injected as the engine's personal
//                    vocabulary snapshot

var arguments = Array(CommandLine.arguments.dropFirst())

func takeFlag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func takeOption(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

let enOverride = takeOption("--en")
let isOverride = takeOption("--is")
let lemmaOverride = takeOption("--lemma")
let noMorph = takeFlag("--no-morph")
let limitOverride = takeOption("--limit").flatMap(Int.init)
let personalOverride = takeOption("--personal")

var resolvedPaths = Artifacts.defaultPaths()
if resolvedPaths == nil, let en = enOverride, let is_ = isOverride {
    // No repo root found: explicit overrides for both lexicons still work.
    resolvedPaths = Artifacts.Paths(
        english: URL(fileURLWithPath: en),
        icelandic: URL(fileURLWithPath: is_),
        morphology: lemmaOverride.map(URL.init(fileURLWithPath:))
    )
}
guard var paths = resolvedPaths else {
    warn("could not locate repo root (data/is/is.lex); pass --en and --is explicitly")
    exit(2)
}

if let en = enOverride { paths.english = URL(fileURLWithPath: en) }
if let is_ = isOverride { paths.icelandic = URL(fileURLWithPath: is_) }
if let lemma = lemmaOverride { paths.morphology = URL(fileURLWithPath: lemma) }

let engine: TypeEngine
do {
    engine = try Artifacts.loadEngine(paths: paths, morphologyEnabled: !noMorph)
} catch {
    warn("failed to load artifacts: \(error)")
    exit(2)
}

// Personal-learning snapshot (M2): same injection path as the extension.
var basePersonal: PersonalVocabulary?
if let personalOverride {
    do {
        let model = try PersonalModel(contentsOf: URL(fileURLWithPath: personalOverride))
        let snapshot = PersonalSnapshot(model: model)
        basePersonal = snapshot
        engine.setPersonalVocabulary(snapshot)
        warn("personal model loaded: \(engine.personalSnapshotWords.count) words")
    } catch {
        warn("failed to load personal model: \(error)")
        exit(2)
    }
}

switch arguments.first {
case "run":
    guard arguments.count >= 2 else {
        warn("usage: type-repl run <file.scenarios>")
        exit(2)
    }
    let runner = ScenarioRunner(
        engine: engine,
        defaultLimit: limitOverride ?? 5,
        basePersonal: basePersonal
    )
    exit(Int32(runner.run(fileAt: arguments[1])))

case "bench":
    // Default limit 3 = what the extension requests per keystroke.
    Bench(engine: engine).run(limit: limitOverride ?? 3)

case nil:
    Repl(engine: engine).run(limit: limitOverride ?? 5)

case let .some(unknown):
    warn("unknown subcommand: \(unknown) (expected: run, bench, or none for REPL)")
    exit(2)
}
