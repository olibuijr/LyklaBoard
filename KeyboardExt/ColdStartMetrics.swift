//
//  ColdStartMetrics.swift
//  LyklabordKeyboard
//
//  Privacy-safe measurement for the keyboard's activation -> first usable
//  autocomplete path. No proxy text, key values, suggestions, or user ids are
//  captured. Samples stay in the App Group and are pulled explicitly by the
//  developer; the extension still contains no network code.
//

import Foundation
import os

/// One service lifetime's cold-path state machine. Every method is lock-safe:
/// requests originate from KeyboardKit Tasks while bootstrap/completion run on
/// the engine queue.
final class AutocompleteColdStartTracker {

    private static let processLock = NSLock()
    private static var processServiceCount = 0

    static func nextProcessServiceOrdinal() -> Int {
        processLock.lock()
        defer { processLock.unlock() }
        processServiceCount += 1
        return processServiceCount
    }

    /// Monotonic process time: unlike wall-clock dates this cannot jump when
    /// the system clock changes during a measurement.
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    struct Metrics: Encodable, Equatable {
        let processServiceOrdinal: Int
        let activationToServiceCreationMs: Double
        let activationToEngineReadyMs: Double
        let activationToStableResultMs: Double
        let serviceToBootstrapStartMs: Double
        let bootstrapDurationMs: Double
        let serviceToEngineReadyMs: Double
        let serviceToFirstRequestMs: Double
        let firstRequestToStableResultMs: Double
        let serviceToStableResultMs: Double
        let engineReadyBacklogDepth: Int
        let maxQueuedWindowDepth: Int
        let requestsAcceptedBeforeReady: Int
        let requestsCompletedBeforeStable: Int
        let outdatedResultsBeforeStable: Int
        let backlogDrainMs: Double

        var isProcessCold: Bool { processServiceOrdinal == 1 }
    }

    private let lock = NSLock()
    private let activationStartedAt: TimeInterval
    private let serviceCreatedAt: TimeInterval
    private let processServiceOrdinal: Int

    private var bootstrapStartedAt: TimeInterval?
    private var engineReadyAt: TimeInterval?
    private var firstRequestAt: TimeInterval?
    private var firstStableResultAt: TimeInterval?
    private var backlogDrainedAt: TimeInterval?
    private var preReadyGenerations = Set<UInt64>()
    private var outstandingRequests = 0
    private var maxQueuedWindowDepth = 0
    private var engineReadyBacklogDepth = 0
    private var requestsAcceptedBeforeReady = 0
    private var requestsCompletedBeforeStable = 0
    private var outdatedResultsBeforeStable = 0
    private var didEmitMetrics = false

    init(
        serviceCreatedAt: TimeInterval,
        activationStartedAt: TimeInterval? = nil,
        processServiceOrdinal: Int
    ) {
        self.activationStartedAt = min(activationStartedAt ?? serviceCreatedAt, serviceCreatedAt)
        self.serviceCreatedAt = serviceCreatedAt
        self.processServiceOrdinal = processServiceOrdinal
    }

    func bootstrapStarted(at now: TimeInterval = AutocompleteColdStartTracker.now) {
        lock.lock()
        defer { lock.unlock() }
        if bootstrapStartedAt == nil { bootstrapStartedAt = now }
    }

    /// Call while assigning the request generation so accepted-request order
    /// and generation order remain identical.
    func requestAccepted(
        generation: UInt64,
        at now: TimeInterval = AutocompleteColdStartTracker.now
    ) {
        lock.lock()
        defer { lock.unlock() }
        if firstRequestAt == nil { firstRequestAt = now }
        outstandingRequests += 1
        maxQueuedWindowDepth = max(maxQueuedWindowDepth, outstandingRequests)
        if engineReadyAt == nil {
            requestsAcceptedBeforeReady += 1
            preReadyGenerations.insert(generation)
        }
    }

    func engineReady(at now: TimeInterval = AutocompleteColdStartTracker.now) {
        lock.lock()
        defer { lock.unlock() }
        guard engineReadyAt == nil else { return }
        engineReadyAt = now
        engineReadyBacklogDepth = outstandingRequests
        if preReadyGenerations.isEmpty {
            // Nothing waited behind bootstrap, so the cold backlog was empty
            // at publication and its drain duration is exactly zero.
            backlogDrainedAt = now
        }
    }

    /// Returns a sample exactly once, after both a publishable non-empty result
    /// and cold-backlog drain are known. A non-empty result that was superseded
    /// is deliberately not "stable" and cannot finish the measurement.
    func requestCompleted(
        generation: UInt64,
        wasSuperseded: Bool,
        hadNonEmptySuggestions: Bool,
        at now: TimeInterval = AutocompleteColdStartTracker.now
    ) -> Metrics? {
        lock.lock()
        defer { lock.unlock() }

        outstandingRequests = max(outstandingRequests - 1, 0)
        if firstStableResultAt == nil {
            if hadNonEmptySuggestions && !wasSuperseded {
                firstStableResultAt = now
            } else {
                requestsCompletedBeforeStable += 1
                if wasSuperseded { outdatedResultsBeforeStable += 1 }
            }
        }
        preReadyGenerations.remove(generation)
        if engineReadyAt != nil, preReadyGenerations.isEmpty, backlogDrainedAt == nil {
            // Request generations are assigned before their queue blocks are
            // enqueued, so concurrent callers need not complete in generation
            // order. The explicit set proves every pre-ready window drained.
            backlogDrainedAt = now
        }
        return completedMetricsIfAvailable()
    }

    private func completedMetricsIfAvailable() -> Metrics? {
        guard
            !didEmitMetrics,
            let bootstrapStartedAt,
            let engineReadyAt,
            let firstRequestAt,
            let firstStableResultAt,
            let backlogDrainedAt
        else { return nil }
        didEmitMetrics = true
        return Metrics(
            processServiceOrdinal: processServiceOrdinal,
            activationToServiceCreationMs: milliseconds(activationStartedAt, serviceCreatedAt),
            activationToEngineReadyMs: milliseconds(activationStartedAt, engineReadyAt),
            activationToStableResultMs: milliseconds(activationStartedAt, firstStableResultAt),
            serviceToBootstrapStartMs: milliseconds(serviceCreatedAt, bootstrapStartedAt),
            bootstrapDurationMs: milliseconds(bootstrapStartedAt, engineReadyAt),
            serviceToEngineReadyMs: milliseconds(serviceCreatedAt, engineReadyAt),
            serviceToFirstRequestMs: milliseconds(serviceCreatedAt, firstRequestAt),
            firstRequestToStableResultMs: milliseconds(firstRequestAt, firstStableResultAt),
            serviceToStableResultMs: milliseconds(serviceCreatedAt, firstStableResultAt),
            engineReadyBacklogDepth: engineReadyBacklogDepth,
            maxQueuedWindowDepth: maxQueuedWindowDepth,
            requestsAcceptedBeforeReady: requestsAcceptedBeforeReady,
            requestsCompletedBeforeStable: requestsCompletedBeforeStable,
            outdatedResultsBeforeStable: outdatedResultsBeforeStable,
            backlogDrainMs: max(milliseconds(engineReadyAt, backlogDrainedAt), 0)
        )
    }

    private func milliseconds(_ start: TimeInterval, _ end: TimeInterval) -> Double {
        max((end - start) * 1_000, 0)
    }
}

#if os(iOS)
/// Local-only JSONL journal. File work runs on a separate utility queue after
/// the first stable result, never on the main or engine queues. The journal is
/// bounded so long-term dogfooding cannot grow the App Group indefinitely.
final class AutocompleteColdStartRecorder {

    private static let schema = "lyklabord.cold-start.v1"
    private static let maximumJournalBytes = 256 * 1_024
    private static let retainedLineCount = 256
    private static let ioQueue = DispatchQueue(
        label: "is.solberg.lyklabord.cold-start-metrics",
        qos: .utility
    )
    private static let logger = Logger(
        subsystem: "is.solberg.lyklabord",
        category: "AutocompleteColdStart"
    )

    private let appGroupId: String?

    init(appGroupId: String?) {
        self.appGroupId = appGroupId
    }

    func record(_ metrics: AutocompleteColdStartTracker.Metrics) {
        let appGroupId = appGroupId
        // Everything beyond the dispatch enqueue happens after publication on
        // a separate utility queue: metadata lookup, JSON encoding, logging,
        // App Group resolution, and file I/O never delay the stable result.
        Self.ioQueue.async {
            let info = Bundle.main.infoDictionary
            let sample = Sample(
                schema: Self.schema,
                capturedAt: Date().timeIntervalSince1970,
                runId: UUID().uuidString,
                extensionVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
                extensionBuild: info?["CFBundleVersion"] as? String ?? "?",
                deviceModel: Self.deviceModelIdentifier(),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                isSimulator: Self.isSimulator,
                isProcessCold: metrics.isProcessCold,
                metrics: metrics
            )
            guard let data = try? JSONEncoder().encode(sample),
                let line = String(data: data, encoding: .utf8)
            else { return }
            // Unified logging keeps an Instruments/Console path even when App
            // Group access is unavailable. The payload is metrics-only/public.
            Self.logger.notice("COLD_START_JSON \(line, privacy: .public)")
            guard let appGroupId,
                let container = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: appGroupId)
            else { return }
            let journalURL = container
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("diagnostics", isDirectory: true)
                .appendingPathComponent("cold-start.jsonl")
            Self.append(Data((line + "\n").utf8), to: journalURL)
        }
    }

    private static func append(_ line: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
            bytes >= maximumJournalBytes,
            let existing = try? Data(contentsOf: url),
            let text = String(data: existing, encoding: .utf8)
        {
            let retained = text.split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(retainedLineCount)
                .joined(separator: "\n") + "\n"
            try? Data(retained.utf8).write(to: url, options: .atomic)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    private static var isSimulator: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    private static func deviceModelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private struct Sample: Encodable {
        let schema: String
        let capturedAt: Double
        let runId: String
        let extensionVersion: String
        let extensionBuild: String
        let deviceModel: String
        let osVersion: String
        let isSimulator: Bool
        let isProcessCold: Bool
        let metrics: AutocompleteColdStartTracker.Metrics
    }
}
#endif
