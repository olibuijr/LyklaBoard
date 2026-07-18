//
//  LyklabordEmojiKeyboard.swift
//  LyklabordKeyboard
//
//  A minimal, self-contained emoji picker for the keyboard extension.
//
//  Why this exists: the vendored KeyboardKit (9.9.1, MIT) ships only a
//  *placeholder* emoji keyboard — `Emoji.KeyboardWrapper` renders `EmptyView`
//  because the real grid is a KeyboardKit Pro feature. KeyboardKit's
//  `KeyboardView` also strips the `.keyboardType(.emojis)` key from the layout
//  unless a NON-placeholder emoji view type is supplied (`hasEmojiKeyboard`).
//  Supplying this view (a distinct type ≠ `Emoji.KeyboardWrapper`) both keeps
//  the emoji key alive and gives it something to show.
//
//  It reuses the emoji *model* data that IS bundled in the vendored package
//  (EmojiKit: `EmojiCategory.standard`, each category's `.emojis`), and routes
//  taps through the existing `KeyboardActionHandler` — so emoji insertion goes
//  through the same path as every other key (feedback, autocomplete reset,
//  proxy insert). iOS offers no public API to jump a custom keyboard to the
//  system emoji keyboard, so an in-keyboard picker is the only route.
//
//  Privacy: pure on-device UI over static emoji tables. No network, no storage.
//

import SwiftUI
import KeyboardKit

/// In-keyboard emoji picker: a category-sectioned scroll grid with a bottom
/// control bar (ABC to return to letters, category jump tabs, backspace).
struct LyklabordEmojiKeyboard: View {

    /// Routes emoji taps / ABC / backspace through the shared action handler,
    /// exactly like the letter keys do.
    let actionHandler: KeyboardActionHandler
    /// KeyboardKit-provided style (item font/size), so the grid tracks the
    /// same metrics as the rest of the keyboard.
    var style: Emoji.KeyboardStyle

    private let categories = EmojiCategory.standardCategories

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 36), spacing: 4)]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(categories, id: \.id) { category in
                            Section {
                                grid(for: category)
                            } header: {
                                header(for: category)
                            }
                            .id(category.id)
                        }
                    }
                    .padding(.top, 2)
                }
                controlBar(scroll: scroll)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    private func grid(for category: EmojiCategory) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(category.emojis) { emoji in
                Button {
                    actionHandler.handle(.release, on: .emoji(emoji))
                } label: {
                    Text(emoji.char)
                        .font(.system(size: 30))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
    }

    private func header(for category: EmojiCategory) -> some View {
        Text(title(for: category))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.thinMaterial)
    }

    // MARK: - Bottom control bar

    private func controlBar(scroll: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            // "ABC" is the iOS-standard label for returning to letters — kept
            // verbatim English per the COPY RULE (system-style control label).
            Button {
                actionHandler.handle(.release, on: .keyboardType(.alphabetic))
            } label: {
                Text("ABC")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 56, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(categories, id: \.id) { category in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scroll.scrollTo(category.id, anchor: .top)
                            }
                        } label: {
                            Image(systemName: icon(for: category))
                                .font(.system(size: 15))
                                .frame(width: 34, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                actionHandler.handle(.release, on: .backspace)
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 18))
                    .frame(width: 48, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.primary)
        .frame(height: 44)
        .background(.thinMaterial)
    }

    // MARK: - Category presentation

    /// Icelandic section titles (keyboard-internal UI ⇒ Icelandic per the COPY
    /// RULE). Falls back to a custom category's own name.
    private func title(for category: EmojiCategory) -> String {
        switch category {
        case .smileysAndPeople: return "Broskallar og fólk"
        case .animalsAndNature: return "Dýr og náttúra"
        case .foodAndDrink: return "Matur og drykkur"
        case .activity: return "Afþreying"
        case .travelAndPlaces: return "Ferðalög og staðir"
        case .objects: return "Hlutir"
        case .symbols: return "Tákn"
        case .flags: return "Fánar"
        case .custom(_, let name, _, _): return name
        default: return ""
        }
    }

    /// SF Symbols for the category jump tabs (all available on the extension's
    /// deployment target).
    private func icon(for category: EmojiCategory) -> String {
        switch category {
        case .smileysAndPeople: return "face.smiling"
        case .animalsAndNature: return "leaf"
        case .foodAndDrink: return "fork.knife"
        case .activity: return "sportscourt"
        case .travelAndPlaces: return "car"
        case .objects: return "lightbulb"
        case .symbols: return "number"
        case .flags: return "flag"
        default: return "square.grid.2x2"
        }
    }
}
