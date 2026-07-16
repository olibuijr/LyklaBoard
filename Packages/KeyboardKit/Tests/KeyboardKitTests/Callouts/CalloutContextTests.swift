//
//  CalloutContextTests.swift
//  KeyboardKit
//
//  Regression coverage for the better-keyboard fork's action-callout
//  drag-out dismissal (dogfood 2026-07-16: long-pressing the bottom-row `.`
//  key, dragging FAR OUT of the callout and releasing still committed a
//  character, whereas letter keys dismissed cleanly).
//
//  Root cause: `CalloutContext.updateSecondaryActionsSelection(with:)` mapped
//  a drag x-position onto a secondary-action index and, when that index fell
//  OUTSIDE the item range, clamped it back to `secondaryActionStartIndex` — a
//  valid index whose action a release then commits. Letter keys hid this
//  because their "drag away to cancel" is a downward swipe, cleared earlier by
//  `shouldResetSecondaryActions` (`dragTranslation.height > buttonFrame.height`).
//  A bottom-row key has no room below it, so that downward reset is
//  unreachable and the horizontal drag-out was the only exit — and it wrongly
//  committed. The fix clears the selection (index -1) on an out-of-range drag,
//  so a release commits nothing, matching iOS and the letter-key path.
//
//  These tests pin the pure decision seam `resolvedSecondaryActionIndex(...)`
//  (returns nil = deselected when the drag lands past the item range) and the
//  downstream contract that a deselected context commits no action on release.
//

import Foundation
import Testing
@testable import KeyboardKit

class CalloutContextTests {

    // Representative bottom-row `.` geometry: a slim 8%-width key (~31pt) with
    // the Icelandic ".,!?@#:;-" callout (9 items) and the fork's default
    // `dragIndexScaleFactor` of 0.8 (indexWidth = max(20, 0.8*31) ≈ 24.8pt).
    private let buttonWidth: CGFloat = 31
    private let scale = 0.8
    private let count = 9

    private func index(
        atX x: CGFloat,
        isLeading: Bool
    ) -> Int? {
        CalloutContext.resolvedSecondaryActionIndex(
            locationX: x,
            buttonWidth: buttonWidth,
            dragIndexScaleFactor: scale,
            actionCount: count,
            isLeading: isLeading
        )
    }

    // MARK: - In-range selection is preserved (no behavior change)

    @Test func testResolvesFirstItemNearButtonOrigin_leading() {
        #expect(index(atX: 5, isLeading: true) == 0)
    }

    @Test func testResolvesInteriorItem_leading() {
        // indexWidth ≈ 24.8; x ≈ 3.5 * indexWidth lands on item 3.
        #expect(index(atX: 87, isLeading: true) == 3)
    }

    @Test func testResolvesLastItem_leading() {
        // Just inside the final slot (8 * indexWidth ≈ 198.4 ..< 223.2).
        #expect(index(atX: 205, isLeading: true) == count - 1)
    }

    // MARK: - The bug: far drag-out deselects instead of clamping to base

    @Test func testFarDragPastLastItemDeselects_leading() {
        // Well past the 9th slot (>= 9 * indexWidth ≈ 223.2) → nil, NOT a
        // clamp back to index 0 (which would insert the base character).
        #expect(index(atX: 400, isLeading: true) == nil)
    }

    @Test func testFarDragPastLastItemDeselects_trailing() {
        // Trailing callout (the `.` key sits on the right of the row): items
        // extend LEFT, so "far out" is a large negative-ish x. Drag far left
        // → offset large → index negative → nil.
        #expect(index(atX: -400, isLeading: false) == nil)
    }

    @Test func testResolvesLastItem_trailing() {
        // Near the button origin the trailing callout selects a valid index.
        let i = index(atX: 5, isLeading: false)
        #expect(i != nil)
        #expect(i == count - 1)
    }

    // MARK: - Guards

    @Test func testDegenerateButtonWidthDeselects() {
        #expect(
            CalloutContext.resolvedSecondaryActionIndex(
                locationX: 10, buttonWidth: 0.5, dragIndexScaleFactor: scale,
                actionCount: count, isLeading: true
            ) == nil
        )
    }

    @Test func testEmptyActionsDeselects() {
        #expect(
            CalloutContext.resolvedSecondaryActionIndex(
                locationX: 10, buttonWidth: buttonWidth, dragIndexScaleFactor: scale,
                actionCount: 0, isLeading: true
            ) == nil
        )
    }

    // MARK: - Release contract: a deselected context commits nothing

    /// A callout with no valid selection (the state a far drag-out leaves it
    /// in) must not route any action to the handler on release — this is the
    /// `handleReleaseInside`/`handleReleaseOutside` early-out in
    /// `Keyboard.ButtonGestures` that lets the release fall through to "nothing
    /// inserted". Mirrors the letter-key drag-out behavior.
    @Test func testDeselectedContextCommitsNoActionOnRelease() {
        let context = CalloutContext()
        var handled: [KeyboardAction] = []
        context.actionHandler = { handled.append($0) }

        // Fresh context: no secondary actions, index -1 (the deselected state).
        #expect(context.selectedSecondaryAction == nil)
        #expect(context.handleSelectedSecondaryAction() == false)
        #expect(handled.isEmpty)
    }
}
