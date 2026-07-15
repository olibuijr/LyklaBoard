// lex-bench: loads a .lex file, runs mixed frequency/bigram/completions
// lookups, and reports process memory (mach task_info) + per-call latency.
// Mirrors Packages/LemmaCore/Sources/lemma-bench/main.swift.
//
// Usage:
//   swift run -c release lex-bench <path-to-en.lex-or-is.lex> [iterations]

import Foundation
import Lexicon

struct MemorySample {
    let residentBytes: UInt64
    let physFootprintBytes: UInt64

    static func current() -> MemorySample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return MemorySample(residentBytes: 0, physFootprintBytes: 0) }
        return MemorySample(
            residentBytes: info.resident_size, physFootprintBytes: UInt64(info.phys_footprint))
    }
}

func mb(_ bytes: UInt64) -> String {
    String(format: "%.2f MB", Double(bytes) / 1024 / 1024)
}

func us(_ totalMs: Double, _ iterations: Int) -> String {
    String(format: "%.1f", totalMs / Double(iterations) * 1000)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: lex-bench <path-to-.lex> [iterations]")
    exit(1)
}
let lexPath = args[1]
let iterations = args.count >= 3 ? (Int(args[2]) ?? 1000) : 1000

// A representative mix of words — some frequent function words, some rarer
// content words, some prefixes for completions, plus a couple of
// deliberately unknown tokens. Works for either language's artifact: unknown
// lookups just return nil/empty, which is itself a real workload the
// keyboard hits constantly (every OOV keystroke sequence).
let words = [
    "the", "quick", "brown", "fox", "over", "dog", "og", "að", "er", "í", "á",
    "þetta", "þeirra", "börnin", "æðislegur", "öðruvísi", "ánægður",
    "morguninn", "xyzzyunknown", "javascript",
]
let bigramPairs = [
    ("the", "quick"), ("quick", "brown"), ("brown", "fox"), ("over", "the"),
    ("þetta", "er"), ("og", "þetta"), ("það", "er"), ("xyzzy", "unknown"),
]
let prefixes = ["th", "qu", "þ", "æ", "a", "b", "m", "xyz"]

let before = MemorySample.current()
print("before load:      resident=\(mb(before.residentBytes))  footprint=\(mb(before.physFootprintBytes))")

let t0 = Date()
let lexicon = try FrequencyLexicon(contentsOf: URL(fileURLWithPath: lexPath))
let loadMs = Date().timeIntervalSince(t0) * 1000

let afterLoad = MemorySample.current()
print(
    "after mmap load:  resident=\(mb(afterLoad.residentBytes))  footprint=\(mb(afterLoad.physFootprintBytes))  (load \(String(format: "%.2f", loadMs)) ms)"
)
print(
    "file: \(mb(UInt64(lexicon.bufferSize)))  unigrams=\(lexicon.unigramCount)  bigrams=\(lexicon.bigramCount)  totalUnigramTokens=\(lexicon.totalUnigramTokens)"
)

// frequency(of:)
var freqAcc: UInt64 = 0
let tFreq0 = Date()
for i in 0..<iterations {
    if let f = lexicon.frequency(of: words[i % words.count]) { freqAcc += UInt64(f) }
}
let freqMs = Date().timeIntervalSince(tFreq0) * 1000

// bigramFrequency(_:_:)
var bigramAcc: UInt64 = 0
let tBigram0 = Date()
for i in 0..<iterations {
    let (a, b) = bigramPairs[i % bigramPairs.count]
    if let f = lexicon.bigramFrequency(a, b) { bigramAcc += UInt64(f) }
}
let bigramMs = Date().timeIntervalSince(tBigram0) * 1000

// completions(of:limit:)
var completionsAcc = 0
let tCompletions0 = Date()
for i in 0..<iterations {
    completionsAcc += lexicon.completions(of: prefixes[i % prefixes.count], limit: 5).count
}
let completionsMs = Date().timeIntervalSince(tCompletions0) * 1000

let afterCalls = MemorySample.current()

print(
    "frequency:    \(iterations) calls, \(us(freqMs, iterations)) µs/call  (sum=\(freqAcc))"
)
print(
    "bigramFreq:   \(iterations) calls, \(us(bigramMs, iterations)) µs/call  (sum=\(bigramAcc))"
)
print(
    "completions:  \(iterations) calls, \(us(completionsMs, iterations)) µs/call  (results=\(completionsAcc))"
)
print(
    "after \(iterations * 3) mixed calls: resident=\(mb(afterCalls.residentBytes))  footprint=\(mb(afterCalls.physFootprintBytes))"
)
print(
    "delta from start: resident=+\(mb(afterCalls.residentBytes - min(afterCalls.residentBytes, before.residentBytes)))  footprint=+\(mb(afterCalls.physFootprintBytes - min(afterCalls.physFootprintBytes, before.physFootprintBytes)))"
)
