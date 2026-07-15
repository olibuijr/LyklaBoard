//
//  KeyboardViewController.swift
//  BetterKeyboardExt
//
//  M0 spike: KeyboardKit shell wired up with a custom Icelandic QWERTY
//  layout. Autocorrect / prediction / learning land in later milestones
//  (see PLAN.md). This extension must never make a network call.
//
//  KeyboardKit note: v10+ ships as a closed-source XCFramework gated by a
//  LicenseKit dependency, which conflicts with this repo's locked decision
//  that the free tier stays MIT/auditable and the extension is
//  network-code-free. We pin to 9.9.1 (project.yml), the last tag with full
//  MIT Swift source and no license-key machinery.
//

import KeyboardKit
import SwiftUI

/// The `KeyboardApp` descriptor shared by the app and the extension. Kept
/// minimal for the M0 spike: no license key (we stay on the free/MIT tier
/// by design — see PLAN.md decision #4), single locale, App Group wired for
/// the future LearningStore / dictionary sync (M2/M3).
extension KeyboardApp {
    static var betterKeyboard: Self {
        .init(
            name: "Better Keyboard",
            appGroupId: "group.is.betterkeyboard",
            locales: [.icelandic]
        )
    }
}

final class KeyboardViewController: KeyboardInputViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        // Configure the settings store (App Group backed) and inject the
        // app descriptor into the keyboard state.
        KeyboardSettings.setupStore(for: .betterKeyboard)
        state.setup(for: .betterKeyboard)

        // Single Icelandic layout — no locale switching (PLAN.md decision #2:
        // mixed EN/IS typing is assumed on the one Icelandic layout).
        state.keyboardContext.locale = .icelandic
        state.keyboardContext.locales = [.icelandic]

        // Custom layout (input keys) and callouts (long-press accents) are
        // wired up as value/modifier APIs in `viewWillSetupKeyboardView()`
        // below, not via the deprecated `services.layoutService` /
        // `services.calloutService` service-protocol assignments — see the
        // "Icelandic Layout" / "Icelandic Callouts" sections at the bottom
        // of this file.

        // M1: bilingual IS/EN autocomplete via TypeEngine. The service
        // bootstraps itself lazily on its own utility-QoS serial queue (mmap
        // of lemma-is.bin + en.lex + is.lex happens off the main thread —
        // the launch-flicker mitigation in PLAN.md; nothing heavy runs in
        // viewDidLoad). Until the engine is ready it returns empty
        // suggestions. Replaces the default `.disabled` service; the
        // standard KeyboardView toolbar (`toolbar: { $0.view }` below)
        // renders `AutocompleteContext.suggestions`, and the standard action
        // handler applies `.autocorrect` suggestions on space/delimiter.
        services.autocompleteService = BetterKeyboardAutocompleteService()
    }

    override func viewWillSetupKeyboardView() {
        setupKeyboardView { controller in
            KeyboardView(
                layout: icelandicLayoutProvider.keyboardLayout(for: controller.state.keyboardContext),
                state: controller.state,
                services: controller.services,
                buttonContent: { $0.view },
                buttonView: { $0.view },
                collapsedView: { $0.view },
                emojiKeyboard: { $0.view },
                toolbar: { $0.view }
            )
            .keyboardCalloutActions { params in
                Callouts.Actions.icelandic.actions(for: params.action)
            }
        }
    }
}

/// The Icelandic layout provider, shared by every call to
/// `viewWillSetupKeyboardView()` (re-invoked on each keyboard-view render,
/// so it's cheap to construct here rather than stored as a stored property).
private let icelandicLayoutProvider = IcelandicKeyboardLayoutProvider()

// MARK: - Icelandic Layout

/// Icelandic QWERTY input layout.
///
/// Verified against the physical/hardware Icelandic layout (ÍST 125:2015,
/// cross-checked via kbdlayout.info/KBDIC) and iOS 6+ behavior (Æ, Þ, Ð, Ö
/// have been dedicated, always-visible keys since iOS 6 — not long-press
/// variants). The three-row software layout mirrors how iOS collapses other
/// Nordic/German hardware layouts onto the on-screen keyboard: characters
/// that live on the physical letter rows keep their row; ö (which sits on
/// the *number* row on physical Icelandic hardware, right of 0) is relocated
/// onto row 2 since the on-screen alphabetic keyboard has no number row.
///
///   Row 1: q w e r t y u i o p ð   (ð right of p — matches hardware)
///   Row 2: a s d f g h j k l æ ö   (æ right of l — matches hardware;
///                                   ö appended — relocated from the
///                                   hardware number row)
///   Row 3: z x c v b n m þ         (þ right of m — matches hardware,
///                                   which places þ at the end of the
///                                   bottom row)
///
/// Sources: kbdlayout.info/KBDIC (hardware key positions), Wikipedia
/// "Icelandic keyboard layout", and the iOS 6 Icelandic-keyboard coverage
/// on einstein.is / simon.is (confirms Æ/Þ/Ð/Ö are dedicated, always-visible
/// keys, not long-press-only).
extension KeyboardLayout.InputSet {
    static var icelandic: Self {
        .init(rows: [
            .init(chars: "qwertyuiopð"),
            .init(chars: "asdfghjklæö"),
            .init(chars: "zxcvbnmþ", deviceVariations: [.pad: "zxcvbnmþ,."])
        ])
    }
}

/// Generates the full keyboard layout (letters + numeric + symbolic pages)
/// using the Icelandic input set for the alphabetic page. Numeric/symbolic
/// pages reuse KeyboardKit's standard sets for now.
///
/// KeyboardKit note: this replicates the (row-building + item-sizing) logic
/// that used to live in the now-deprecated `KeyboardLayout.BaseLayoutService`
/// — deprecated in 9.9.1, removed in v10, in favor of passing a plain
/// `KeyboardLayout` value via `KeyboardView(layout:)`. The logic itself
/// isn't Pro-gated or new to v10, it's just no longer wrapped in a
/// subclassable service protocol — see research/keyboardkit-v10-delta.md §1.
struct IcelandicKeyboardLayoutProvider {
    var alphabeticInputSet: KeyboardLayout.InputSet = .icelandic
    var numericInputSet: KeyboardLayout.InputSet = .numeric
    var symbolicInputSet: KeyboardLayout.InputSet = .symbolic

    /// Get a keyboard layout for the provided context.
    func keyboardLayout(for context: KeyboardContext) -> KeyboardLayout {
        KeyboardLayout(
            itemRows: itemRows(for: context),
            deviceConfiguration: .standard(for: context),
            inputToolbarInputSet: inputSetForInputToolbar(with: context)
        )
    }

    private func inputSet(for context: KeyboardContext) -> KeyboardLayout.InputSet {
        switch context.keyboardType {
        case .numeric: numericInputSet
        case .symbolic: symbolicInputSet
        default: alphabeticInputSet
        }
    }

    private func inputSetForInputToolbar(with context: KeyboardContext) -> KeyboardLayout.InputSet {
        switch context.keyboardType {
        case .numeric: symbolicInputSet
        default: numericInputSet
        }
    }

    private func inputCharacters(for context: KeyboardContext) -> [[String]] {
        inputSet(for: context).rows.characters(
            for: context.keyboardCase,
            device: context.deviceTypeForKeyboard
        )
    }

    private func inputActions(for context: KeyboardContext) -> KeyboardAction.Rows {
        .init(characters: inputCharacters(for: context))
    }

    private func itemRows(for context: KeyboardContext) -> KeyboardLayout.ItemRows {
        // `KeyboardAction.standardLayoutItem(for:)` is the non-deprecated
        // 9.9.1 free-function replacement for `BaseLayoutService`'s
        // item/size/inset builder methods (itemSize/itemInsets/itemAlignment).
        let config = KeyboardLayout.DeviceConfiguration.standard(for: context)
        return inputActions(for: context).map { row in
            row.map { action in action.standardLayoutItem(for: config) }
        }
    }
}

// MARK: - Icelandic Callouts (long-press accents)

/// Long-press callout actions for the Icelandic layout.
///
/// Provides the accented vowels á é í ó ú ý on long-press of their base
/// letter (per PLAN.md v1 scope), and keeps ð/þ discoverable on long-press
/// of d/t as a secondary path even though they're also dedicated keys.
///
/// KeyboardKit note: built on `Callouts.Actions` + `View.keyboardCalloutActions(_:)`,
/// the non-deprecated 9.9.1 value/modifier replacement for the deprecated
/// `Callouts.BaseCalloutService` subclassing pattern (see
/// research/keyboardkit-v10-delta.md §1). Starts from the standard English
/// callout set (base symbols/digits + Latin diacritics) so untouched keys
/// keep their existing long-press behavior, then overrides the eight
/// Icelandic-specific keys.
extension Callouts.Actions {
    static var icelandic: Self {
        var actions = Self.english
        let icelandicOverrides = Self(characters: [
            "a": "aá",
            "e": "eé",
            "i": "ií",
            "o": "oó",
            "u": "uú",
            "y": "yý",
            "d": "dð",
            "t": "tþ",
        ])
        actions.actionsDictionary.merge(icelandicOverrides.actionsDictionary) { _, new in new }
        return actions
    }
}
