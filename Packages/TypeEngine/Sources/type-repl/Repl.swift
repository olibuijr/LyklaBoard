import Foundation
import TypeEngine

/// Interactive mode: whatever you type on a line is appended to the document
/// character-by-character through the proxy (trailing spaces survive, so
/// "hestur " commits the word). Lines starting with ':' are commands.
struct Repl {
    let engine: TypeEngine

    func run(limit: Int) {
        let typist = Typist(engine: engine, limit: limit)
        var showPerCharTiming = false

        print(
            """
            type-repl — interactive TypeEngine session (real artifacts)
            Input is appended to the document verbatim, one character at a
            time through the proxy window; end a line with a space (or type
            punctuation) to commit the word. Commands:
              :reset            fresh field (document, session, posterior)
              :posterior        print P(Icelandic)
              :timing           toggle per-keystroke latency listing
              :context          show proxy window vs full document
              :cursor <pos>     move caret (+n / -n relative, n absolute, start, end)
              :host <text>      host app replaces the document
              :truncate <n>     cap the context window at n chars
              :stale on|off     stale proxy reads after edits
              :backspace [n]    press backspace n times
              :quit
            """
        )

        while true {
            print("> ", terminator: "")
            guard let line = readLine(strippingNewline: true) else { break }

            if line.hasPrefix(":") {
                if handleCommand(
                    line, typist: typist, showPerCharTiming: &showPerCharTiming
                ) { break }
                continue
            }
            guard !line.isEmpty else {
                report(typist, lineLatencies: [], showPerChar: false)
                continue
            }

            let startIndex = typist.latenciesMicros.count
            typist.type(line)
            let lineLatencies = Array(typist.latenciesMicros[startIndex...])
            report(typist, lineLatencies: lineLatencies, showPerChar: showPerCharTiming)
        }
    }

    /// Returns true when the REPL should exit.
    private func handleCommand(
        _ line: String,
        typist: Typist,
        showPerCharTiming: inout Bool
    ) -> Bool {
        let (command, argument) = ScenarioRunner.split(line)
        switch command {
        case ":quit", ":q", ":exit":
            return true
        case ":reset":
            typist.reset()
            print("reset: empty document, P(IS)=0.500")
        case ":posterior":
            print("P(IS) = \(String(format: "%.3f", typist.session.probabilityIcelandic))")
        case ":timing":
            showPerCharTiming.toggle()
            print("per-keystroke timing \(showPerCharTiming ? "on" : "off")")
        case ":context":
            print("window : \"\(typist.lastContextBefore)\"")
            print("document: \"\(typist.proxy.document)\" (cursor at \(typist.proxy.cursor))")
        case ":cursor":
            switch argument {
            case "start": typist.proxy.moveCursor(to: 0)
            case "end": typist.proxy.moveCursor(to: typist.proxy.document.count)
            default:
                if argument.hasPrefix("+") || argument.hasPrefix("-") {
                    typist.proxy.moveCursor(by: Int(argument) ?? 0)
                } else {
                    typist.proxy.moveCursor(to: Int(argument) ?? typist.proxy.cursor)
                }
            }
            typist.externalChange()
            report(typist, lineLatencies: [], showPerChar: false)
        case ":host":
            typist.proxy.hostReplaceText(ScenarioRunner.unquote(argument))
            typist.externalChange()
            report(typist, lineLatencies: [], showPerChar: false)
        case ":truncate":
            typist.proxy.truncation.maxBeforeLength = Int(argument) ?? .max
            print("context window capped at \(typist.proxy.truncation.maxBeforeLength) chars")
        case ":stale":
            typist.proxy.staleReads = (argument == "on")
            print("stale reads \(typist.proxy.staleReads ? "on" : "off")")
        case ":backspace":
            typist.pressBackspace(Int(argument) ?? 1)
            report(typist, lineLatencies: [typist.lastLatencyMicros], showPerChar: false)
        default:
            print("unknown command: \(command)")
        }
        return false
    }

    private func report(_ typist: Typist, lineLatencies: [Double], showPerChar: Bool) {
        let window = typist.lastContextBefore
        let tail = window.count > 48 ? "…" + window.suffix(48) : window
        print("  window   \"\(tail)\"")
        if let applied = typist.lastAppliedAutocorrect {
            print("  applied  autocorrect \"\(applied.from)\" -> \"\(applied.to)\"")
        }
        print("  bar      \(typist.barDescription)")
        print("  space    \(typist.spaceCommitDescription)")
        let p = typist.session.probabilityIcelandic
        let last = typist.lastLatencyMicros
        let lineMax = lineLatencies.max() ?? last
        print(
            "  state    P(IS)=\(String(format: "%.3f", p))"
                + "  commits=\(typist.session.committedWordCount)"
                + "  suggestions()=\(String(format: "%.0f", last)) us"
                + (lineLatencies.count > 1
                    ? " (line max \(String(format: "%.0f", lineMax)) us)" : "")
        )
        if showPerChar, !lineLatencies.isEmpty {
            let listing = lineLatencies
                .map { String(format: "%.0f", $0) }
                .joined(separator: " ")
            print("  timing   [\(listing)] us")
        }
    }
}
