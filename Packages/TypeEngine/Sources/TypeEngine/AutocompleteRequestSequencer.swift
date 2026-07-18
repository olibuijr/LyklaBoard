//
//  AutocompleteRequestSequencer.swift
//  TypeEngine
//
//  Shared request/delivery ordering for the keyboard extension and the
//  headless last-mile replay gate. KeyboardKit starts one unstructured task
//  per autocomplete request, so the result that reaches the toolbar can lag
//  behind newer proxy text. A ticket captures the input generation at request
//  time; completion asks this same object whether a different input has since
//  superseded it.
//

import Foundation

/// Thread-safe monotonic autocomplete request sequencing.
///
/// The extension and the timed headless embedder both use this exact type.
/// Engine execution remains serial and stateful—every window is observed in
/// order—but only a result that is still current may replace the published
/// suggestion bar. Repeated requests for identical text may both publish;
/// doing so is harmless and avoids treating a refresh as a semantic change.
public final class AutocompleteRequestSequencer: @unchecked Sendable {

    public struct Ticket: Equatable, Sendable {
        public let generation: UInt64
        public let text: String

        fileprivate init(generation: UInt64, text: String) {
            self.generation = generation
            self.text = text
        }
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var latestText = ""

    public init() {}

    /// Register a request at the caller boundary, before it is enqueued on the
    /// serial engine queue.
    public func accept(text: String) -> Ticket {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        latestText = text
        return Ticket(generation: generation, text: text)
    }

    /// Whether `ticket` has been superseded by a newer request for different
    /// proxy text and must therefore be delivered as outdated.
    public func isSuperseded(_ ticket: Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return AutocorrectApplyGuard.isSupersededResult(
            requestGeneration: ticket.generation,
            requestText: ticket.text,
            latestGeneration: generation,
            latestText: latestText
        )
    }
}
