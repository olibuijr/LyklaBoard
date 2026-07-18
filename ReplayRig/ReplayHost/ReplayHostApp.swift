//
//  ReplayHostApp.swift
//  ReplayHost — last-mile replay rig host app (PLAN.md testing pyramid tier 3)
//
//  Minimal SwiftUI app: one full-screen TextField that Lyklaborð types into,
//  plus a mirrored results label. The XCUITest (ReplayRigUITests) replays timed
//  human typing traces as accessibility-layer taps on the on-screen keyboard and
//  reads the resulting text back out of this field.
//
//  Why a dedicated host (vs reusing the main app's UI): the containing app's
//  screens are onboarding/settings/dictionary — navigation-heavy and stateful.
//  This host is a single deterministic text surface with stable accessibility
//  ids and nothing else on screen, so the test never has to fight layout.
//
//  The keyboard itself is NOT embedded here: Lyklaborð is installed
//  system-wide by the containing Lyklabord app (its app-extension), enabled
//  once in Settings, and then available to every app — including this one. See
//  scripts/replay-run.sh for the enablement story.
//
//  This target ships in the rig only; it is never part of the App Store build.
//

import SwiftUI

@main
struct ReplayHostApp: App {
    var body: some Scene {
        WindowGroup {
            ReplayHostView()
        }
    }
}

struct ReplayHostView: View {
    @State private var text: String = ""
    @FocusState private var focused: Bool

    /// SCREENSHOT_MODE=1 (launch environment, set by ScreenshotUITests):
    /// swap the top-anchored rig layout for a store-capture layout — a single
    /// compose-style field pinned DIRECTLY above the keyboard, nothing else on
    /// screen. The App Store renders crop to the bottom half of the device, so
    /// the field must live in the sliver just above the keyboard. Replay
    /// behavior (a11y ids, focus, no host autocorrection) is identical.
    private var screenshotMode: Bool {
        ProcessInfo.processInfo.environment["SCREENSHOT_MODE"] == "1"
    }

    var body: some View {
        if screenshotMode { screenshotBody } else { rigBody }
    }

    private var screenshotBody: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("", text: $text, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(false)
                    .font(.system(size: 22))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color(.systemGray4), lineWidth: 1.5)
                    )
                    .focused($focused)
                    .accessibilityIdentifier("replay-input")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
        .onAppear { focused = true }
    }

    private var rigBody: some View {
        VStack(spacing: 16) {
            // The field the rig types into. Auto-behaviors are DISABLED here so
            // the only correction/prediction in play is Lyklaborð's own — the
            // host must not add UITextField-level autocorrection on top.
            TextField("Replay input", text: $text, axis: .vertical)
                .textInputAutocapitalization(.sentences) // matches a normal message field
                .autocorrectionDisabled(false)            // let the keyboard drive; host adds none
                .font(.title3)
                .padding()
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
                .focused($focused)
                .accessibilityIdentifier("replay-input")

            // Mirror label — a redundant read channel for the test in case the
            // TextField's `.value` is flaky under fast replay.
            Text(text.isEmpty ? " " : text)
                .accessibilityIdentifier("replay-result")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Programmatic clear between traces (tapped by the test).
            Button("Clear") { text = "" }
                .accessibilityIdentifier("replay-clear")

            Spacer()
        }
        .padding()
        .onAppear { focused = true }
    }
}
