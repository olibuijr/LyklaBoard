import Foundation
import TypeEngine

/// Latency regression gate: replay a fixed mixed IS/EN text keystroke-by-
/// keystroke through the proxy + session (identical path to the extension)
/// and report per-keystroke `suggestions()` latency percentiles.
struct Bench {
    let engine: TypeEngine

    /// Built-in mixed Icelandic/English text, ~200 keystrokes. Chosen to
    /// exercise: IS morphology, EN words, posterior drift both ways, commits
    /// via space and period, and a few misspellings that walk the edits2
    /// path (worst case).
    static let text =
        "góðan daginn hvernig hefur þú það ég er að læra íslensku. "
        + "today was busy but the weather is nice. "
        + "ég ætla að borða hádegismat with my friends núna. "
        + "sjáumst síðar have a good day takk fyrir hjálpina. "
        + "þetta er frábært veðrur og ég er hamingjusamur bless"

    func run(limit: Int) {
        let typist = Typist(engine: engine, limit: limit)
        typist.reset()

        // Warm the mmap-backed artifacts a little so first-touch page faults
        // don't dominate the percentiles (the extension pays those once per
        // process too, not per keystroke).
        typist.type("aðal ")
        typist.reset()

        let total = ContinuousClock.now
        typist.type(Self.text)
        let wall = total.duration(to: .now)

        let latencies = typist.latenciesMicros.sorted()
        guard !latencies.isEmpty else {
            print("no keystrokes measured")
            return
        }

        func percentile(_ p: Double) -> Double {
            let rank = p * Double(latencies.count - 1)
            let low = Int(rank.rounded(.down))
            let high = Int(rank.rounded(.up))
            let fraction = rank - Double(low)
            return latencies[low] * (1 - fraction) + latencies[high] * fraction
        }

        print("type-repl bench — \(typist.latenciesMicros.count) keystrokes, limit \(limit)")
        print("  wall time          \(String(format: "%.1f", wall.milliseconds)) ms")
        print("  p50                \(String(format: "%8.0f", percentile(0.50))) us")
        print("  p95                \(String(format: "%8.0f", percentile(0.95))) us")
        print("  p99                \(String(format: "%8.0f", percentile(0.99))) us")
        print("  max                \(String(format: "%8.0f", latencies.last!)) us")
        print("  words committed    \(typist.session.committedWordCount)")
        print("  posterior updates  \(typist.session.posteriorUpdateCount)")
        print("  final P(IS)        \(String(format: "%.3f", typist.session.probabilityIcelandic))")

        // The slowest keystrokes, for eyeballing edits2 outliers.
        let slowest = latencies.suffix(5).map { String(format: "%.0f", $0) }
        print("  slowest 5          [\(slowest.joined(separator: " "))] us")

        // Separate worst-case gate: an unknown hyphenated word walks the
        // full edits2 generate-and-test path (maxEdits2Expansions) on nearly
        // every mid-word keystroke — the known latency landmine flagged in
        // PLAN.md (SymSpell delete-index follow-up). Kept out of the main
        // percentiles so those stay representative of typical typing.
        typist.reset()
        typist.type("vel-þekkt")
        let worst = typist.latenciesMicros.max() ?? 0
        print(
            "  edits2 worst case  \(String(format: "%8.0f", worst)) us"
                + "  (slowest keystroke while typing \"vel-þekkt\")"
        )
    }
}
