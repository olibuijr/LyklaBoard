import Foundation
import TypeEngine

/// Production-shaped, UI-free last-mile replay.
///
/// Unlike the synchronous scenario runner, this harness keeps a separately
/// published suggestion bar and drives `TypingSession` through an actual
/// serial DispatchQueue. Requests are accepted at the keystroke boundary,
/// every proxy window is still observed by the stateful session in order, and
/// the shared `AutocompleteRequestSequencer` decides whether each completed
/// result may publish. Delimiter application consults the same
/// `AutocorrectApplyGuard` as the extension and assertions target the final
/// proxy document, not the bar alone.
final class TimedLastMileHarness {

    struct Metrics {
        var requestToDeliveryMs: [Double]
        var actionMs: [Double]
        var maximumQueueDepth: Int
        var supersededDeliveries: Int
        var staleApplySkips: Int
        var autocorrectApplies: Int
    }

    final class EngineHold {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var released = false

        fileprivate func wait() { semaphore.wait() }

        func release() {
            lock.lock()
            guard !released else {
                lock.unlock()
                return
            }
            released = true
            lock.unlock()
            semaphore.signal()
        }

        deinit { release() }
    }

    private struct PublishedBar {
        var suggestions: [Suggestion] = []
        var pendingToken = ""
    }

    private let session: TypingSession
    private let proxy = ProxySimulator(truncation: .none)
    private let requestSequencer = AutocompleteRequestSequencer()
    private let engineQueue = DispatchQueue(
        label: "is.solberg.lyklabord.last-mile.engine", qos: .userInitiated)
    private let deliveryQueue = DispatchQueue(
        label: "is.solberg.lyklabord.last-mile.delivery", qos: .userInitiated)
    private let requestGroup = DispatchGroup()
    private let stateLock = NSLock()

    private var bar = PublishedBar()
    private var pendingRequests = 0
    private var maximumQueueDepth = 0
    private var requestToDeliveryMs: [Double] = []
    private var actionMs: [Double] = []
    private var supersededDeliveries = 0
    private var staleApplySkips = 0
    private var autocorrectApplies = 0
    private var continuationRevertArmed = false
    private var punctuationAttachmentArmed = false

    init(engine: TypeEngine) {
        session = TypingSession(engine: engine)
    }

    var document: String { proxy.document }

    var publishedSuggestions: [Suggestion] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return bar.suggestions
    }

    var metrics: Metrics {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Metrics(
            requestToDeliveryMs: requestToDeliveryMs,
            actionMs: actionMs,
            maximumQueueDepth: maximumQueueDepth,
            supersededDeliveries: supersededDeliveries,
            staleApplySkips: staleApplySkips,
            autocorrectApplies: autocorrectApplies
        )
    }

    /// Reset document/session state after all prior requests have drained.
    /// Timing/counter evidence intentionally remains cumulative across cases.
    func reset(document: String = "") {
        precondition(waitForIdle(), "cannot reset with an undrained request")
        engineQueue.sync { session.reset() }
        proxy.hostReplaceText(document)
        stateLock.lock()
        bar = PublishedBar()
        continuationRevertArmed = false
        punctuationAttachmentArmed = false
        stateLock.unlock()
    }

    /// Put a barrier in front of subsequent engine work. This deterministic
    /// test hook models a busy/bootstrap-delayed serial queue while preserving
    /// the production ordering and request sequencing on either side of it.
    func holdEngineProcessing() -> EngineHold {
        let hold = EngineHold()
        engineQueue.async { hold.wait() }
        return hold
    }

    @discardableResult
    func waitForIdle(timeoutSeconds: Double = 5) -> Bool {
        let result = requestGroup.wait(
            timeout: .now() + .milliseconds(Int(timeoutSeconds * 1000)))
        if result == .success { deliveryQueue.sync {} }
        return result == .success
    }

    func typeCharacter(_ character: Character) {
        let actionStarted = DispatchTime.now().uptimeNanoseconds
        let before = proxy.trueContextBeforeInput

        let memoFlags = currentMemoFlags()
        if memoFlags.continuation, character.isLetter || character.isNumber {
            if let edit = engineQueue.sync(execute: { session.continuationRevert(for: character) }) {
                execute(edit)
            }
        }
        if memoFlags.attachment {
            if let edit = engineQueue.sync(execute: { session.punctuationAttachment(for: character) }) {
                execute(edit)
            }
        }

        if TypingSession.isDelimiter(character), character != ".",
            let candidate = currentPublishedBar().suggestions.first(where: { $0.isAutocorrect })
        {
            let published = currentPublishedBar()
            if AutocorrectApplyGuard.shouldAutoApply(
                recordedPendingToken: published.pendingToken,
                textBeforeCursor: proxy.trueContextBeforeInput)
            {
                let live = TypingSession.splitCurrentWord(
                    of: proxy.trueContextBeforeInput).currentWord
                for _ in 0..<live.count { proxy.deleteBackward() }
                proxy.insertText(candidate.text)
                stateLock.lock()
                autocorrectApplies += 1
                stateLock.unlock()
            } else {
                stateLock.lock()
                staleApplySkips += 1
                stateLock.unlock()
            }
        }

        proxy.insertText(String(character))
        submitObservation(before: before, after: proxy.trueContextBeforeInput)
        recordAction(startedAt: actionStarted)
    }

    func pressBackspace() {
        let actionStarted = DispatchTime.now().uptimeNanoseconds
        let before = proxy.trueContextBeforeInput
        proxy.deleteBackward()
        submitObservation(before: before, after: proxy.trueContextBeforeInput)
        recordAction(startedAt: actionStarted)
    }

    @discardableResult
    func tapSuggestion(_ text: String) -> Bool {
        let actionStarted = DispatchTime.now().uptimeNanoseconds
        guard let suggestion = currentPublishedBar().suggestions.first(where: { $0.text == text })
        else { return false }

        if suggestion.isVerbatim {
            let wasLiteralRevert = engineQueue.sync {
                session.revertToLiteral(matching: suggestion.text)
            }
            if !wasLiteralRevert {
                engineQueue.sync { session.noteVerbatimChoice(suggestion.text) }
            }
        }

        let before = proxy.trueContextBeforeInput
        let live = TypingSession.splitCurrentWord(of: before).currentWord
        for _ in 0..<live.count { proxy.deleteBackward() }
        proxy.insertText(suggestion.text)
        let windows = proxy.contextWindows()
        if !windows.before.hasSuffix(" "), !windows.after.hasPrefix(" ") {
            proxy.insertText(" ")
        }
        submitObservation(before: before, after: proxy.trueContextBeforeInput)
        recordAction(startedAt: actionStarted)
        return true
    }

    private func submitObservation(before: String, after: String) {
        let text = proxy.contextBeforeInput
        let ticket = requestSequencer.accept(text: text)
        let acceptedAt = DispatchTime.now().uptimeNanoseconds
        requestGroup.enter()
        stateLock.lock()
        pendingRequests += 1
        maximumQueueDepth = max(maximumQueueDepth, pendingRequests)
        stateLock.unlock()

        engineQueue.async { [self] in
            session.noteSelfEdit(before: before, after: after)
            let suggestions = session.suggestions(for: text, limit: 3)
            let pendingToken = TypingSession.splitCurrentWord(of: text).currentWord
            let superseded = requestSequencer.isSuperseded(ticket)
            let continuation = session.hasPendingContinuationRevert
            let attachment = session.hasPendingPunctuationAttachment

            deliveryQueue.async { [self] in
                let deliveredAt = DispatchTime.now().uptimeNanoseconds
                stateLock.lock()
                pendingRequests -= 1
                requestToDeliveryMs.append(
                    Double(deliveredAt &- acceptedAt) / 1_000_000)
                if superseded {
                    supersededDeliveries += 1
                } else {
                    bar = PublishedBar(
                        suggestions: suggestions, pendingToken: pendingToken)
                    continuationRevertArmed = continuation
                    punctuationAttachmentArmed = attachment
                }
                stateLock.unlock()
                requestGroup.leave()
            }
        }
    }

    private func currentPublishedBar() -> PublishedBar {
        stateLock.lock()
        defer { stateLock.unlock() }
        return bar
    }

    private func currentMemoFlags() -> (continuation: Bool, attachment: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (continuationRevertArmed, punctuationAttachmentArmed)
    }

    private func execute(_ edit: RevertInstruction) {
        for _ in 0..<edit.deleteCount { proxy.deleteBackward() }
        proxy.insertText(edit.text)
    }

    private func recordAction(startedAt: UInt64) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000
        stateLock.lock()
        actionMs.append(elapsed)
        stateLock.unlock()
    }
}

struct TimedLastMileRunner {
    private struct CaseResult {
        let name: String
        let passed: Bool
        let detail: String
    }

    let engine: TypeEngine

    func run() -> Int {
        let harness = TimedLastMileHarness(engine: engine)
        var cases: [CaseResult] = []

        func typeFresh(_ text: String) -> Bool {
            for character in text {
                harness.typeCharacter(character)
                guard harness.waitForIdle() else { return false }
            }
            return true
        }

        // Fresh ordinary delimiter: the real-artifact `teh` repair must be
        // stamped for that exact token, apply, and produce the final text.
        harness.reset()
        let freshReady = typeFresh("teh")
        let freshBar = harness.publishedSuggestions.contains {
            $0.isAutocorrect && $0.text == "the"
        }
        harness.typeCharacter(" ")
        let freshDrained = harness.waitForIdle()
        cases.append(CaseResult(
            name: "delimiter-application",
            passed: freshReady && freshBar && freshDrained && harness.document == "the ",
            detail: "document=\(quoted(harness.document)), armed=\(freshBar)"))

        // Dot is deliberately literal on its own; the following delimiter
        // applies the re-armed whole-token suggestion (`teh.` -> `the.`).
        harness.reset()
        let dotReady = typeFresh("teh.")
        let dotBar = harness.publishedSuggestions.contains {
            $0.isAutocorrect && $0.text == "the."
        }
        let literalDot = harness.document == "teh."
        harness.typeCharacter(" ")
        let dotDrained = harness.waitForIdle()
        cases.append(CaseResult(
            name: "deferred-dot-delimiter",
            passed: dotReady && dotBar && literalDot && dotDrained
                && harness.document == "the. ",
            detail: "document=\(quoted(harness.document)), armed=\(dotBar)"))

        // Hold the serial queue after publishing `teh`'s bar, then type a
        // continuation + delimiter without waiting. The old bar must fail the
        // apply-time token check, the first queued result must be delivery-
        // superseded, and the final document must retain every typed byte.
        harness.reset()
        let staleReady = typeFresh("teh")
        let beforeFast = harness.metrics
        let hold = harness.holdEngineProcessing()
        harness.typeCharacter("x")
        harness.typeCharacter(" ")
        let queuedDepth = harness.metrics.maximumQueueDepth
        let drainStarted = DispatchTime.now().uptimeNanoseconds
        hold.release()
        let fastDrained = harness.waitForIdle()
        let backlogDrainMs = Double(
            DispatchTime.now().uptimeNanoseconds &- drainStarted) / 1_000_000
        let afterFast = harness.metrics
        let staleDelta = afterFast.staleApplySkips - beforeFast.staleApplySkips
        let supersededDelta = afterFast.supersededDeliveries - beforeFast.supersededDeliveries
        cases.append(CaseResult(
            name: "stale-delivery-fast-queue",
            passed: staleReady && fastDrained && harness.document == "tehx "
                && staleDelta == 1 && supersededDelta >= 1 && queuedDepth >= 2,
            detail: "document=\(quoted(harness.document)), depth=\(queuedDepth), "
                + "outdated=\(supersededDelta), staleSkips=\(staleDelta)"))

        // Real commit -> first backspace -> reserved literal slot -> tap. The
        // assertion is the restored proxy text, not merely slot visibility.
        harness.reset()
        let revertReady = typeFresh("teh")
        harness.typeCharacter(" ")
        let commitDrained = harness.waitForIdle()
        harness.pressBackspace()
        let backspaceDrained = harness.waitForIdle()
        let literalVisible = harness.publishedSuggestions.contains {
            $0.isVerbatim && $0.text == "teh"
        }
        let tapped = harness.tapSuggestion("teh")
        let revertDrained = harness.waitForIdle()
        cases.append(CaseResult(
            name: "backspace-literal-revert",
            passed: revertReady && commitDrained && backspaceDrained
                && literalVisible && tapped && revertDrained && harness.document == "teh ",
            detail: "document=\(quoted(harness.document)), slot=\(literalVisible), tapped=\(tapped)"))

        let metrics = harness.metrics
        let requestP95 = percentile(metrics.requestToDeliveryMs, 0.95)
        let requestMax = metrics.requestToDeliveryMs.max() ?? .infinity
        let actionP95 = percentile(metrics.actionMs, 0.95)
        let behaviorPass = cases.allSatisfy(\.passed)

        // Host-side last-mile budgets. The decoder's independent per-line
        // ceiling remains 30 ms; this allows one additional queued pass while
        // still making a stalled delivery/action path fail loudly.
        let requestP95ThresholdMs = 60.0
        let requestMaxThresholdMs = 120.0
        let backlogDrainThresholdMs = 100.0
        let actionP95ThresholdMs = 5.0
        let performancePass = requestP95 < requestP95ThresholdMs
            && requestMax < requestMaxThresholdMs
            && backlogDrainMs < backlogDrainThresholdMs
            && actionP95 < actionP95ThresholdMs
        let passedCases = cases.filter(\.passed).count
        let pass = behaviorPass && performancePass

        for result in cases {
            print("  \(result.passed ? "PASS" : "FAIL") \(result.name): \(result.detail)")
        }
        print(String(
            format: "last-mile %@ — %d/%d cases; request p95 %.2f ms/max %.2f ms; "
                + "fast drain %.2f ms; action p95 %.3f ms; max queue %d",
            pass ? "PASS" : "FAIL", passedCases, cases.count, requestP95,
            requestMax, backlogDrainMs, actionP95, metrics.maximumQueueDepth))

        let object: [String: Any] = [
            "version": "v1",
            "passedCases": passedCases,
            "totalCases": cases.count,
            "behaviorPass": behaviorPass,
            "sessionProxyFailures": cases.count - passedCases,
            "performancePass": performancePass,
            "pass": pass,
            "cases": cases.map {
                ["name": $0.name, "pass": $0.passed, "detail": $0.detail]
            },
            "metrics": [
                "requestP95Ms": requestP95,
                "requestMaxMs": requestMax,
                "backlogDrainMs": backlogDrainMs,
                "actionP95Ms": actionP95,
                "maximumQueueDepth": metrics.maximumQueueDepth,
                "supersededDeliveries": metrics.supersededDeliveries,
                "staleApplySkips": metrics.staleApplySkips,
                "autocorrectApplies": metrics.autocorrectApplies,
            ],
            "thresholds": [
                "requestP95Ms": requestP95ThresholdMs,
                "requestMaxMs": requestMaxThresholdMs,
                "backlogDrainMs": backlogDrainThresholdMs,
                "actionP95Ms": actionP95ThresholdMs,
            ],
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return pass ? 0 : 1
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .infinity }
        let sorted = values.sorted()
        let index = Int(ceil(p * Double(sorted.count))) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    private func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
