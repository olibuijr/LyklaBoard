//
//  FullAccessExplainer.swift
//  BetterKeyboard
//
//  Honest "Full Access" explainer (v1-blocker), reused in onboarding and
//  Settings. The message we commit to: typing works fully WITHOUT Full
//  Access; granting it only enables the shared dictionary (app ↔ keyboard)
//  + iCloud sync, and haptics — an iOS limitation we inherit, not a choice.
//  The extension ships zero networking code either way (link the source as
//  proof). Also carries the password-field behavior and the
//  uninstall/data-survival note. All copy lives in `Strings.FullAccess`.
//

import SwiftUI

struct FullAccessExplainer: View {
    var body: some View {
        List {
            Section {
                block(
                    icon: "keyboard",
                    tint: .green,
                    title: Strings.FullAccess.worksWithoutTitle,
                    body: Strings.FullAccess.worksWithoutBody
                )
            }

            Section {
                block(
                    icon: "arrow.triangle.2.circlepath",
                    tint: .blue,
                    title: Strings.FullAccess.enablesTitle,
                    body: Strings.FullAccess.enablesBody
                )
            }

            Section {
                block(
                    icon: "lock.shield",
                    tint: .indigo,
                    title: Strings.FullAccess.noNetworkTitle,
                    body: Strings.FullAccess.noNetworkBody
                )
                if let url = URL(string: Strings.Links.githubRepo) {
                    Link(destination: url) {
                        Label(Strings.FullAccess.viewSourceLink, systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }

            Section {
                block(
                    icon: "asterisk",
                    tint: .orange,
                    title: Strings.FullAccess.passwordTitle,
                    body: Strings.FullAccess.passwordBody
                )
            }

            Section {
                block(
                    icon: "trash",
                    tint: .red,
                    title: Strings.FullAccess.uninstallTitle,
                    body: Strings.FullAccess.uninstallBody
                )
            }
        }
        .navigationTitle(Strings.FullAccess.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func block(icon: String, tint: Color, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        FullAccessExplainer()
    }
}
