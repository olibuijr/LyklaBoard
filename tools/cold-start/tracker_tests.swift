import Foundation

enum TrackerTestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TrackerTestFailure.assertion(message) }
}

private func expectClose(_ actual: Double, _ expected: Double, _ message: String) throws {
    try expect(abs(actual - expected) < 0.001, "\(message): \(actual) != \(expected)")
}

@main
struct ColdStartTrackerTests {
    static func main() throws {
        try supersededBacklogDoesNotMasqueradeAsStable()
        try outOfOrderCompletionStillWaitsForTheWholeColdBacklog()
        try noPreReadyRequestsHasZeroBacklogDrain()
        try metricsEmitOnlyOnce()
        print("PASS — cold-start tracker ordering, stability, and backlog drain")
    }

    private static func outOfOrderCompletionStillWaitsForTheWholeColdBacklog() throws {
        let tracker = AutocompleteColdStartTracker(
            serviceCreatedAt: 4.0,
            processServiceOrdinal: 1
        )
        tracker.bootstrapStarted(at: 4.010)
        tracker.requestAccepted(generation: 1, at: 4.020)
        tracker.requestAccepted(generation: 2, at: 4.030)
        tracker.engineReady(at: 4.100)
        try expect(tracker.requestCompleted(
            generation: 2,
            wasSuperseded: false,
            hadNonEmptySuggestions: true,
            at: 4.120
        ) == nil, "stable result must not hide an older undrained window")
        guard let metrics = tracker.requestCompleted(
            generation: 1,
            wasSuperseded: true,
            hadNonEmptySuggestions: true,
            at: 4.140
        ) else { throw TrackerTestFailure.assertion("full backlog drain did not emit metrics") }
        try expectClose(metrics.firstRequestToStableResultMs, 100, "stable result time")
        try expectClose(metrics.backlogDrainMs, 40, "out-of-order backlog drain")
    }

    private static func supersededBacklogDoesNotMasqueradeAsStable() throws {
        let tracker = AutocompleteColdStartTracker(
            serviceCreatedAt: 1.0,
            activationStartedAt: 0.950,
            processServiceOrdinal: 1
        )
        tracker.bootstrapStarted(at: 1.010)
        tracker.requestAccepted(generation: 1, at: 1.020)
        tracker.requestAccepted(generation: 2, at: 1.030)
        tracker.engineReady(at: 1.100)
        try expect(tracker.requestCompleted(
            generation: 1,
            wasSuperseded: true,
            hadNonEmptySuggestions: true,
            at: 1.120
        ) == nil, "superseded non-empty result must not finish the run")
        guard let metrics = tracker.requestCompleted(
            generation: 2,
            wasSuperseded: false,
            hadNonEmptySuggestions: true,
            at: 1.140
        ) else { throw TrackerTestFailure.assertion("stable result did not emit metrics") }

        try expect(metrics.isProcessCold, "first service must be process-cold")
        try expectClose(metrics.activationToServiceCreationMs, 50, "activation to service")
        try expectClose(metrics.activationToEngineReadyMs, 150, "activation to engine")
        try expectClose(metrics.activationToStableResultMs, 190, "activation to stable")
        try expectClose(metrics.serviceToBootstrapStartMs, 10, "queue delay")
        try expectClose(metrics.bootstrapDurationMs, 90, "bootstrap duration")
        try expectClose(metrics.serviceToEngineReadyMs, 100, "engine ready")
        try expectClose(metrics.firstRequestToStableResultMs, 120, "request to stable")
        try expect(metrics.engineReadyBacklogDepth == 2, "engine-ready backlog depth")
        try expect(metrics.maxQueuedWindowDepth == 2, "maximum queue depth")
        try expect(metrics.requestsAcceptedBeforeReady == 2, "pre-ready accepted count")
        try expect(metrics.requestsCompletedBeforeStable == 1, "pre-stable completed count")
        try expect(metrics.outdatedResultsBeforeStable == 1, "outdated count")
        try expectClose(metrics.backlogDrainMs, 40, "backlog drain")
    }

    private static func noPreReadyRequestsHasZeroBacklogDrain() throws {
        let tracker = AutocompleteColdStartTracker(
            serviceCreatedAt: 2.0,
            processServiceOrdinal: 2
        )
        tracker.bootstrapStarted(at: 2.005)
        tracker.engineReady(at: 2.050)
        tracker.requestAccepted(generation: 1, at: 2.100)
        guard let metrics = tracker.requestCompleted(
            generation: 1,
            wasSuperseded: false,
            hadNonEmptySuggestions: true,
            at: 2.110
        ) else { throw TrackerTestFailure.assertion("warm presentation did not emit metrics") }

        try expect(!metrics.isProcessCold, "second service must be marked warm")
        try expect(metrics.engineReadyBacklogDepth == 0, "unexpected ready backlog")
        try expect(metrics.requestsAcceptedBeforeReady == 0, "unexpected pre-ready request")
        try expectClose(metrics.backlogDrainMs, 0, "empty backlog drain")
        try expectClose(metrics.firstRequestToStableResultMs, 10, "warm request to stable")
    }

    private static func metricsEmitOnlyOnce() throws {
        let tracker = AutocompleteColdStartTracker(
            serviceCreatedAt: 3.0,
            processServiceOrdinal: 1
        )
        tracker.bootstrapStarted(at: 3.001)
        tracker.engineReady(at: 3.010)
        tracker.requestAccepted(generation: 1, at: 3.020)
        try expect(tracker.requestCompleted(
            generation: 1,
            wasSuperseded: false,
            hadNonEmptySuggestions: true,
            at: 3.030
        ) != nil, "first stable result must emit")
        tracker.requestAccepted(generation: 2, at: 3.040)
        try expect(tracker.requestCompleted(
            generation: 2,
            wasSuperseded: false,
            hadNonEmptySuggestions: true,
            at: 3.050
        ) == nil, "metrics emitted more than once")
    }
}
