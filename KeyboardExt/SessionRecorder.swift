//
//  SessionRecorder.swift
//  BetterKeyboardExt
//
//  DEV-MODE typing-session recorder (keyboard-extension half). Captures the
//  ground-truth signal the headless harness and eval corpus can't: what the
//  engine actually offered, applied, and saw the finger do, per real
//  `suggestions()` pass — merged offline (tools/session-analyzer) against the
//  app's authoritative full-text timeline to classify autocorrect misses.
//
//  ┌─ PRIVACY INVARIANTS (HARD — this is a recorder of raw typed text) ──────┐
//  │ • OFF BY DEFAULT. Nothing is ever written unless the containing app has │
//  │   armed a session (App Group flag `recording.sessionId`). One cheap     │
//  │   flag check per pass; ZERO file/allocation overhead when disarmed.     │
//  │ • ARMED STATE AUTO-EXPIRES. The app stamps `recording.armedUntil`; once │
//  │   `now > armedUntil` (10-min window, bumped by app-side activity) this  │
//  │   side treats itself as disarmed regardless of the session id. This is  │
//  │   the belt on the residual risk that arming leaks past the app's pad.   │
//  │ • NEVER records secure / URL / email / web-search fields, even when     │
//  │   armed — same `fieldKind == .standard` gate as learning. The app's pad │
//  │   is a plain TextEditor (standard); anything else is refused.           │
//  │ • LOCAL ONLY. Writes to the App Group container's Documents/sessions/;  │
//  │   never networked (the extension has no network code at all), only      │
//  │   pulled by the developer over USB or exported by explicit user action. │
//  │ • The learning event log is UNAFFECTED — this is a separate file with a │
//  │   separate lifecycle; it never touches learning-events.log or the       │
//  │   personal model.                                                       │
//  │                                                                         │
//  │ RESIDUAL RISK: the extension cannot identify the host app, so a caller  │
//  │ that arms recording and then types in a *third-party* app would still   │
//  │ be captured while the window is live. Mitigations, in order of force:   │
//  │  (a) the app disarms the moment it leaves the foreground (scenePhase),  │
//  │      so leaving the pad for another app stops capture almost instantly; │
//  │  (b) the 10-minute auto-expiry above;                                   │
//  │  (c) a persistent red recording indicator in the app;                   │
//  │  (d) recording is a DEBUG / dev-signed-only affordance, never shipped   │
//  │      to end users.                                                      │
//  └─────────────────────────────────────────────────────────────────────────┘
//

import Foundation
import TypeEngine

/// Keyboard-side session recorder, owned by (and confined to the serial queue
/// of) `BetterKeyboardAutocompleteService`. Not thread-safe on its own — every
/// method must be called on the engine `queue`, exactly like `TypingSession`.
final class SessionRecorder {

    // MARK: - App Group contract (MUST match App/RecordingStore.swift)

    /// `UserDefaults` key (App Group suite) holding the id of the session the
    /// app is currently recording into. Absent/empty ⇒ disarmed.
    static let sessionIdKey = "is.lyklabord.dev.recording.sessionId"
    /// `UserDefaults` key (App Group suite) holding the unix timestamp past
    /// which this side must treat itself as disarmed (auto-expiry).
    static let armedUntilKey = "is.lyklabord.dev.recording.armedUntil"
    /// Subdirectory (under the App Group container's Documents) holding the
    /// per-session `<id>-app.jsonl` (app timeline) and `<id>-kb.jsonl` (this).
    static let sessionsSubdirectory = "sessions"

    // MARK: - Applied action (per pass)

    /// What the keyboard applied to the document in the interval leading up to
    /// a pass — forwarded from `BetterKeyboardActionHandler`.
    enum AppliedAction {
        case autocorrect(String)
        case suggestionTap(String)
        /// The apply-time staleness guard skipped an armed autocorrect whose
        /// recorded pending token no longer matched the live proxy token
        /// (wave #28); the payload is the suggestion text that was NOT
        /// applied. Lets the analyzer count guard firings in the wild.
        case staleSkip(String)
    }

    // MARK: - Wiring

    private let defaults: UserDefaults?
    /// `<container>/Documents/sessions`, or nil when no App Group container.
    private let sessionsDir: URL?

    // MARK: - Cached arm state (recomputed once per pass)

    private(set) var isArmed = false
    private var currentSessionId: String?
    private var kbLogURL: URL?

    // MARK: - Buffers drained on each recorded pass

    private var pendingTaps: [(char: Character, dx: Double, dy: Double)] = []
    private var pendingBackspaces = 0
    private var pendingApplied: AppliedAction?

    // MARK: - Init

    init(appGroupId: String?) {
        if let appGroupId,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupId)
        {
            defaults = UserDefaults(suiteName: appGroupId)
            sessionsDir = container
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(Self.sessionsSubdirectory, isDirectory: true)
        } else {
            defaults = nil
            sessionsDir = nil
        }
    }

    // MARK: - Capture (called between passes, on `queue`)

    /// Buffer one within-key tap sample (only kept while armed). Called from
    /// the service's existing `noteKeyTap` path — no extra keystroke cost when
    /// disarmed beyond the cached-bool check.
    func captureTap(char: Character, dx: Double, dy: Double) {
        guard isArmed else { return }
        // Cap defensively so a pathological pass can't grow unbounded.
        if pendingTaps.count < 64 { pendingTaps.append((char, dx, dy)) }
    }

    /// Buffer one backspace, forwarded from the action handler's `.backspace`
    /// release.
    func captureBackspace() {
        guard isArmed else { return }
        pendingBackspaces += 1
    }

    /// Buffer the applied action (autocorrect fired / suggestion tapped) for
    /// the next pass to attribute it to.
    func captureApplied(_ action: AppliedAction) {
        guard isArmed else { return }
        pendingApplied = action
    }

    // MARK: - Pass logging (called from performAutocomplete, on `queue`)

    /// Record one `suggestions()` pass. Refreshes the arm state (the single
    /// flag check), and — only when armed, in a standard field — appends one
    /// JSONL line to `<id>-kb.jsonl`. Buffers are always cleared so stale taps
    /// never leak across field/session boundaries.
    /// - Parameter pIcelandic: the engine's current Icelandic-lane posterior
    ///   (`TypingSession.probabilityIcelandic`, the same value `type-repl`
    ///   prints as `P(IS)`) for this pass, when the caller has a live
    ///   session. Recorded rounded to 3 decimals as `pIS`; omitted entirely
    ///   (not written as `null`) when nil — e.g. no session yet bootstrapped.
    func recordPass(
        window: String, fieldKind: FieldKind, suggestions: [Suggestion],
        pIcelandic: Double? = nil
    ) {
        refreshArmState()
        guard isArmed, fieldKind == .standard, let kbLogURL, let sid = currentSessionId else {
            clearBuffers()
            return
        }
        let record = KBRecord(
            t: Date().timeIntervalSince1970,
            sid: sid,
            window: String(window.suffix(40)),
            field: fieldKind.rawValue,
            bar: suggestions.map {
                KBRecord.Bar(
                    text: $0.text,
                    ac: $0.isAutocorrect,
                    vb: $0.isVerbatim,
                    rs: $0.isRestoration,
                    conf: $0.confidence)
            },
            applied: KBRecord.Applied(pendingApplied),
            taps: pendingTaps.map { KBRecord.Tap(c: String($0.char), dx: $0.dx, dy: $0.dy) },
            backspaces: pendingBackspaces,
            pIS: pIcelandic.map { (($0 * 1000).rounded()) / 1000 })
        clearBuffers()
        append(record, to: kbLogURL)
    }

    private func clearBuffers() {
        pendingTaps.removeAll(keepingCapacity: true)
        pendingBackspaces = 0
        pendingApplied = nil
    }

    // MARK: - Arm state

    /// The one cheap check that gates everything: read the session id +
    /// expiry from the App Group suite and decide whether this side is armed.
    /// No file I/O, no allocation when disarmed.
    private func refreshArmState() {
        guard let defaults, let sessionsDir else {
            isArmed = false
            return
        }
        guard let sid = defaults.string(forKey: Self.sessionIdKey), !sid.isEmpty else {
            isArmed = false
            currentSessionId = nil
            kbLogURL = nil
            return
        }
        let armedUntil = defaults.double(forKey: Self.armedUntilKey)
        guard armedUntil > Date().timeIntervalSince1970 else {
            // Auto-expired: refuse to record even though an id is still set.
            isArmed = false
            return
        }
        isArmed = true
        if sid != currentSessionId {
            currentSessionId = sid
            kbLogURL = sessionsDir.appendingPathComponent("\(sid)-kb.jsonl")
        }
    }

    // MARK: - Append

    private func append(_ record: KBRecord, to url: URL) {
        guard var data = try? JSONEncoder().encode(record) else { return }
        data.append(0x0A)  // newline (JSONL)
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

// MARK: - On-disk record (one JSON object per line)

private struct KBRecord: Encodable {
    let t: Double
    let sid: String
    let window: String
    let field: String
    let bar: [Bar]
    let applied: Applied
    let taps: [Tap]
    let backspaces: Int
    /// Engine's Icelandic-lane posterior at this pass, 3 decimals — see
    /// `SessionRecorder.recordPass(pIcelandic:)`. Omitted (not `null`) when
    /// unavailable: `analyze.py`'s `KBRecord` construction reads fields via
    /// `dict.get(...)` one at a time (no `**r` splat), so an absent OR an
    /// unrecognized extra key is silently ignored — additive by
    /// construction, verified by reading `analyze.py` (read-only, not
    /// touched by this change).
    let pIS: Double?

    struct Bar: Encodable {
        let text: String
        let ac: Bool  // isAutocorrect
        let vb: Bool  // isVerbatim
        let rs: Bool  // isRestoration
        let conf: Double
    }

    struct Tap: Encodable {
        let c: String
        let dx: Double
        let dy: Double
    }

    struct Applied: Encodable {
        let kind: String  // "none" | "autocorrect" | "tap" | "stale-skip"
        let text: String?

        init(_ action: SessionRecorder.AppliedAction?) {
            switch action {
            case .autocorrect(let text): kind = "autocorrect"; self.text = text
            case .suggestionTap(let text): kind = "tap"; self.text = text
            case .staleSkip(let text): kind = "stale-skip"; self.text = text
            case nil: kind = "none"; self.text = nil
            }
        }
    }
}
