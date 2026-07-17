//
//  RecordingStore.swift
//  BetterKeyboard
//
//  DEV-MODE typing-session recorder (containing-app half). Owns the recording
//  pad's authoritative timeline and the arming handshake with the keyboard
//  extension.
//
//  ┌─ PRIVACY INVARIANTS (HARD) ─────────────────────────────────────────────┐
//  │ • Recording is OFF by default and is a developer-only affordance         │
//  │   (DEBUG builds, or dev-signed release via a hidden long-press — see     │
//  │   SettingsView). End users never see it.                                 │
//  │ • Ground truth is captured ONLY from the app's own "Upptökusvæði" pad —  │
//  │   never from any third-party app. The keyboard-side capture is armed by  │
//  │   this store's App Group flag; because the extension cannot identify its │
//  │   host, we bound the residual risk by (a) disarming the instant the app  │
//  │   leaves the foreground (`noteScenePhaseInactive`), (b) a 10-minute      │
//  │   auto-expiry bumped by pad activity, and (c) an always-visible red      │
//  │   recording indicator in the pad.                                        │
//  │ • Sessions are written to App Group Documents/sessions/ (LOCAL) and, on  │
//  │   stop, ALSO copied into the USER'S OWN iCloud Drive (the app's ubiquity │
//  │   container iCloud.is.solberg.lyklabord, document-scope-public → visible &       │
//  │   deletable in Files). This is an OTA convenience for the developer's    │
//  │   own devices — the user's private iCloud, no servers of ours, same      │
//  │   promise as the dictionary's optional CloudKit sync. The local copies   │
//  │   and the share-sheet export / USB pull all remain. iCloud copy is       │
//  │   best-effort and off-main; when iCloud is unavailable it stays          │
//  │   local-only (surfaced in the UI). Nothing is sent to us; the extension  │
//  │   still has ZERO network/iCloud entitlements.                            │
//  │ • The learning event log and the personal dictionary are UNAFFECTED —    │
//  │   these are separate files with a separate lifecycle.                    │
//  └──────────────────────────────────────────────────────────────────────────┘
//

import Foundation
import Observation
import UIKit  // UIDevice — device model / iOS version for the session manifest

@MainActor
@Observable
final class RecordingStore {

    // MARK: - App Group contract (MUST match KeyboardExt/SessionRecorder.swift)

    static let sessionIdKey = "is.solberg.lyklabord.dev.recording.sessionId"
    static let armedUntilKey = "is.solberg.lyklabord.dev.recording.armedUntil"
    static let sessionsSubdirectory = "sessions"
    /// Auto-expiry window; re-stamped on every pad change while recording.
    static let armWindow: TimeInterval = 10 * 60

    /// The app's iCloud Documents (ubiquity) container — SAME id as CloudKit.
    /// Sessions are copied here on stop so they sync to the developer's own
    /// iCloud Drive and can be picked up on the Mac (tools/session-analyzer
    /// ingest.py), no servers involved. App-only; the extension never touches it.
    static let ubiquityContainerId = "iCloud.is.solberg.lyklabord"

    /// Optional App Group key a FUTURE keyboard-extension wave may stamp with
    /// its own marketing/build version so the manifest can record the exact
    /// extension binary that produced `<id>-kb.jsonl`. Absent today (the
    /// extension stamps nothing) — the manifest falls back to the app build and
    /// records `kbVersionSource: "app-build-fallback"`. Defined here so a later
    /// extension wave has a stable key to write.
    static let kbVersionKey = "is.solberg.lyklabord.dev.kbVersion"

    static let manifestSchema = "lyklabord.session-manifest.v1"

    // MARK: - Per-session iCloud sync state (UI indicator)

    enum SyncState: String, Equatable {
        case localOnly   // on device only — iCloud copy not (yet) present
        case syncing     // copy in flight
        case uploaded    // present in the ubiquity container
        case unavailable // iCloud account/container unavailable on this device
    }

    // MARK: - A recorded session on disk

    struct Session: Identifiable, Equatable {
        let id: String
        /// Parsed from the id (see `makeSessionId`); falls back to file date.
        let startedAt: Date
        /// Files that exist for this session (app timeline + kb log).
        let fileURLs: [URL]
        let totalBytes: Int
    }

    // MARK: - Observable state

    /// Bound to the pad's `TextEditor`.
    var padText: String = ""
    private(set) var isRecording = false
    private(set) var currentSessionId: String?
    private(set) var sessions: [Session] = []
    private(set) var lastErrorMessage: String?

    /// Per-session iCloud sync state, keyed by session id. Updated by the
    /// off-main export task; unknown ids read as `.localOnly`.
    private(set) var syncStates: [String: SyncState] = [:]
    /// False once an export attempt found no iCloud container (drives the
    /// "iCloud unavailable — sessions stay on this device" UI note).
    private(set) var iCloudAvailable = true

    func syncState(for id: String) -> SyncState {
        if !iCloudAvailable { return .unavailable }
        return syncStates[id] ?? .localOnly
    }

    // MARK: - Wiring

    private let defaults: UserDefaults?
    private let sessionsDir: URL?

    var isAvailable: Bool { sessionsDir != nil }

    init(appGroupId: String = AppModel.appGroupIdentifier) {
        if let container = FileManager.default.containerURL(
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
        refreshSessions()
    }

    // MARK: - Recording lifecycle

    func startRecording() {
        guard !isRecording, let sessionsDir else { return }
        let id = Self.makeSessionId()
        currentSessionId = id
        padText = ""
        isRecording = true
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
        appendAppRecord(kind: "start", text: "")
        arm(sessionId: id)
    }

    func stopRecording() {
        guard isRecording, let id = currentSessionId else { return }
        appendAppRecord(kind: "stop", text: padText)
        disarm()
        isRecording = false
        currentSessionId = nil
        _ = id
        refreshSessions()
        // OTA: copy the just-finished session (and any earlier unexported ones)
        // into the user's iCloud Drive. Best-effort, off-main.
        exportPendingSessions()
    }

    /// Pad text changed — snapshot the full text (the authoritative timeline)
    /// and re-stamp the auto-expiry so the keyboard stays armed while typing.
    func noteTextChanged() {
        guard isRecording else { return }
        appendAppRecord(kind: "snapshot", text: padText)
        bumpArmExpiry()
    }

    // MARK: - Scene phase (residual-risk mitigation)

    /// Called when the app leaves the foreground: disarm the keyboard side
    /// immediately so recording cannot follow the user into another app. The
    /// session stays "recording" in the UI and re-arms on return.
    func noteScenePhaseInactive() {
        guard isRecording else { return }
        disarm()
    }

    /// Called when the app returns to the foreground while still recording.
    func noteScenePhaseActive() {
        guard isRecording, let id = currentSessionId else { return }
        arm(sessionId: id)
    }

    // MARK: - Session management

    func refreshSessions() {
        guard let sessionsDir else {
            sessions = []
            return
        }
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: sessionsDir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else {
            sessions = []
            return
        }
        // Group `<id>-app.jsonl` / `<id>-kb.jsonl` by id.
        var byId: [String: (urls: [URL], bytes: Int, date: Date)] = [:]
        for url in entries where url.pathExtension == "jsonl" {
            let name = url.deletingPathExtension().lastPathComponent  // "<id>-app"
            guard let dash = name.range(of: "-", options: .backwards) else { continue }
            let id = String(name[..<dash.lowerBound])
            let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey,
            ])
            let bytes = values?.fileSize ?? 0
            let date = values?.contentModificationDate ?? Date.distantPast
            var entry = byId[id] ?? ([], 0, Date.distantPast)
            entry.urls.append(url)
            entry.bytes += bytes
            entry.date = max(entry.date, date)
            byId[id] = entry
        }
        sessions = byId.map { id, value in
            Session(
                id: id,
                startedAt: Self.date(fromSessionId: id) ?? value.date,
                fileURLs: value.urls.sorted { $0.lastPathComponent < $1.lastPathComponent },
                totalBytes: value.bytes)
        }
        .sorted { $0.startedAt > $1.startedAt }  // newest first
    }

    func delete(_ session: Session) {
        let fm = FileManager.default
        for url in session.fileURLs {
            try? fm.removeItem(at: url)
        }
        refreshSessions()
    }

    // MARK: - iCloud (ubiquity) export

    /// Values needed to build a manifest, snapshotted on the main actor so the
    /// export can run fully off-main.
    private struct ManifestEnv {
        let appShortVersion: String
        let appBuild: String
        let engineCommit: String
        let deviceModel: String
        let iosVersion: String
        let kbVersion: String?
    }

    private func currentManifestEnv() -> ManifestEnv {
        let info = Bundle.main.infoDictionary
        return ManifestEnv(
            appShortVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info?["CFBundleVersion"] as? String ?? "?",
            engineCommit: BuildInfo.engineCommit,
            deviceModel: Self.deviceModelIdentifier(),
            iosVersion: UIDevice.current.systemVersion,
            kbVersion: defaults?.string(forKey: Self.kbVersionKey))
    }

    /// Ensure every finished session has a local manifest, then copy the pair
    /// of JSONL files + the manifest into the iCloud ubiquity container so they
    /// sync to the developer's own iCloud Drive. Idempotent (skips sessions
    /// already present in iCloud with matching sizes), best-effort, off-main.
    func exportPendingSessions() {
        guard let sessionsDir else { return }
        let snapshot = sessions
        let env = currentManifestEnv()
        // Optimistic UI: anything not already uploaded shows as syncing.
        for s in snapshot where (syncStates[s.id] ?? .localOnly) != .uploaded {
            syncStates[s.id] = .syncing
        }
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.exportWork(
                localDir: sessionsDir, sessions: snapshot, env: env,
                containerId: Self.ubiquityContainerId)
            await self?.applyExportResult(result)
        }
    }

    private func applyExportResult(_ result: ExportResult) {
        iCloudAvailable = result.iCloudAvailable
        for (id, state) in result.states {
            syncStates[id] = state
        }
        refreshSessions()  // pick up freshly written local <id>-meta.json files
    }

    private struct ExportResult {
        let iCloudAvailable: Bool
        let states: [String: SyncState]
    }

    /// Off-main worker: writes local manifests and (when iCloud is available)
    /// copies each session's files into the ubiquity container's
    /// Documents/sessions/. `nonisolated static` so it never touches actor state.
    nonisolated private static func exportWork(
        localDir: URL, sessions: [Session], env: ManifestEnv, containerId: String
    ) -> ExportResult {
        let fm = FileManager.default

        // 1. Ensure a local manifest exists for each session (also pulled via USB).
        for s in sessions {
            let metaURL = localDir.appendingPathComponent("\(s.id)-meta.json")
            if !fm.fileExists(atPath: metaURL.path) {
                if let data = manifestData(for: s.id, env: env) {
                    try? data.write(to: metaURL, options: .atomic)
                }
            }
        }

        // 2. iCloud container. This call blocks — hence off-main. nil ⇒ the
        //    account/container is unavailable; stay local-only, note in UI.
        guard let ubiquity = fm.url(forUbiquityContainerIdentifier: containerId) else {
            var states: [String: SyncState] = [:]
            for s in sessions { states[s.id] = .localOnly }
            return ExportResult(iCloudAvailable: false, states: states)
        }
        let destDir = ubiquity
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(sessionsSubdirectory, isDirectory: true)
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        var states: [String: SyncState] = [:]
        for s in sessions {
            let names = ["\(s.id)-app.jsonl", "\(s.id)-kb.jsonl", "\(s.id)-meta.json"]
            var ok = true
            var copiedAny = false
            for name in names {
                let src = localDir.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = destDir.appendingPathComponent(name)
                // Skip if already present with the same size (idempotent retro-export).
                if let sSize = fileSize(fm, src), let dSize = fileSize(fm, dst), sSize == dSize {
                    copiedAny = true
                    continue
                }
                do {
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    try fm.copyItem(at: src, to: dst)
                    copiedAny = true
                } catch {
                    ok = false
                }
            }
            states[s.id] = (ok && copiedAny) ? .uploaded : .localOnly
        }
        return ExportResult(iCloudAvailable: true, states: states)
    }

    nonisolated private static func fileSize(_ fm: FileManager, _ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// Build the JSON manifest bytes for a session. `nonisolated static` — pure.
    nonisolated private static func manifestData(for id: String, env: ManifestEnv) -> Data? {
        let manifest = SessionManifest(
            schema: manifestSchema,
            sessionId: id,
            appShortVersion: env.appShortVersion,
            appBuild: env.appBuild,
            engineCommit: env.engineCommit,
            deviceModel: env.deviceModel,
            iosVersion: env.iosVersion,
            kbVersion: env.kbVersion,
            kbVersionSource: env.kbVersion == nil ? "app-build-fallback" : "app-group",
            createdAt: Date().timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(manifest)
    }

    /// Hardware model identifier, e.g. `iPhone15,2`. On the Simulator the raw
    /// utsname is the host arch, so prefer `SIMULATOR_MODEL_IDENTIFIER`.
    nonisolated private static func deviceModelIdentifier() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        var sys = utsname()
        uname(&sys)
        let id = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return id.isEmpty ? "unknown" : id
    }

    // MARK: - Arming (App Group flag)

    private func arm(sessionId: String) {
        defaults?.set(sessionId, forKey: Self.sessionIdKey)
        defaults?.set(Date().timeIntervalSince1970 + Self.armWindow, forKey: Self.armedUntilKey)
    }

    private func bumpArmExpiry() {
        defaults?.set(Date().timeIntervalSince1970 + Self.armWindow, forKey: Self.armedUntilKey)
    }

    private func disarm() {
        defaults?.removeObject(forKey: Self.sessionIdKey)
        defaults?.set(0.0, forKey: Self.armedUntilKey)
    }

    // MARK: - App-side timeline append

    private func appendAppRecord(kind: String, text: String) {
        guard let sessionsDir, let id = currentSessionId else { return }
        let url = sessionsDir.appendingPathComponent("\(id)-app.jsonl")
        let record = AppRecord(t: Date().timeIntervalSince1970, sid: id, kind: kind, text: text)
        guard var data = try? JSONEncoder().encode(record) else { return }
        data.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            lastErrorMessage = "Ekki tókst að skrifa upptöku"
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    // MARK: - Session id helpers

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }()

    static func makeSessionId(date: Date = Date()) -> String {
        idFormatter.string(from: date)
    }

    static func date(fromSessionId id: String) -> Date? {
        idFormatter.date(from: id)
    }
}

// MARK: - On-disk record (app timeline; one JSON object per line)

private struct AppRecord: Encodable {
    let t: Double
    let sid: String
    let kind: String  // "start" | "snapshot" | "stop"
    let text: String
}

// MARK: - Session manifest (`<id>-meta.json`)

/// Small provenance sidecar written next to a session's JSONL files and copied
/// into iCloud alongside them. Lets the Mac-side aggregate group real-typing
/// rates by ENGINE BUILD (the anti-overcorrection instrument) and know the
/// device/OS a session came from. Contains NO typed text — safe metadata only.
private struct SessionManifest: Encodable {
    let schema: String
    let sessionId: String
    let appShortVersion: String   // CFBundleShortVersionString (MARKETING_VERSION)
    let appBuild: String          // CFBundleVersion (CURRENT_PROJECT_VERSION)
    let engineCommit: String      // BuildInfo.engineCommit (git short hash)
    let deviceModel: String       // e.g. iPhone15,2
    let iosVersion: String        // UIDevice.systemVersion
    let kbVersion: String?        // extension-stamped version, nil today
    let kbVersionSource: String   // "app-group" | "app-build-fallback"
    let createdAt: Double         // unix seconds the manifest was written
}
