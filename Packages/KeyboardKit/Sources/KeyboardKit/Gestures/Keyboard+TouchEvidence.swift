//
//  Keyboard+TouchEvidence.swift
//  KeyboardKit
//
//  LyklaborÃ° fork: this file does not exist upstream. It carries
//  per-release touch coordinates from the gesture layer to the action
//  handler for TypeEngine's coordinate-level decoding (LyklaborÃ°
//  PLAN.md "Touch decoding", stage 1).
//

import Foundation

public extension Keyboard {

    /// LyklaborÃ° fork: main-thread latches carrying touch evidence
    /// from the gesture layer to the action handler.
    ///
    /// Why a latch and not a parameter: KeyboardKit's gesture → action
    /// path erases the touch point long before
    /// `KeyboardActionHandler.handle(_:on:)` runs — the release closures
    /// (`KeyboardGestureAction`) take no arguments — and threading a
    /// `CGPoint` through them would fork every public gesture/handler
    /// signature. The gesture callbacks and the action handler execute
    /// synchronously on the main thread in the same call stack
    /// (`GestureButton.tryHandleRelease` → `releaseAction` →
    /// `handle(.release, on:)`; `CalloutContext
    /// .handleSelectedSecondaryAction` → `actionHandler(action)`), so a
    /// consume-on-read latch matched on the action is race-free, O(1),
    /// and allocation-free. This is the honest trade-off, documented: a
    /// side channel instead of a signature fork.
    enum TouchEvidence {

        /// The most recent key-release touch point. `dxNorm`/`dyNorm` are
        /// normalized within the released key's full touch CELL (the cell
        /// spans the key pitch — gestures attach outside the visual
        /// insets, see `Keyboard+ButtonModifier`): −0.5…+0.5 at the cell
        /// edges, x growing right, y growing down (toward the spacebar) —
        /// the same convention as LyklaborÃ°'s ReplayRig TSI traces
        /// and `TypeEngine.TapSample`. Values may exceed ±0.5 when a drag
        /// releases outside the key within tolerance.
        public struct ReleaseTouch {
            public let action: KeyboardAction
            public let dxNorm: Double
            public let dyNorm: Double

            public init(action: KeyboardAction, dxNorm: Double, dyNorm: Double) {
                self.action = action
                self.dxNorm = dxNorm
                self.dyNorm = dyNorm
            }
        }

        private static var releaseTouch: ReleaseTouch?
        private static var calloutSelection: KeyboardAction?

        /// Record the release touch point for `action` (called by the
        /// button gesture layer on drag end, main thread).
        public static func noteRelease(action: KeyboardAction, dxNorm: Double, dyNorm: Double) {
            releaseTouch = ReleaseTouch(action: action, dxNorm: dxNorm, dyNorm: dyNorm)
        }

        /// Consume the pending release touch when it belongs to `action`;
        /// the latch clears either way (evidence never outlives the
        /// keystroke it was captured for).
        public static func consumeReleaseTouch(matching action: KeyboardAction) -> ReleaseTouch? {
            defer { releaseTouch = nil }
            guard let touch = releaseTouch, touch.action == action else { return nil }
            return touch
        }

        /// Mark `action` as selected from a long-press callout (called by
        /// `CalloutContext` right before it forwards the action). Clears
        /// any pending release touch: the finger's location belongs to the
        /// BASE key's gesture, not to the callout-selected character.
        public static func noteCalloutSelection(_ action: KeyboardAction) {
            calloutSelection = action
            releaseTouch = nil
        }

        /// Consume the callout-selection marker when it belongs to
        /// `action`; clears either way.
        public static func consumeCalloutSelection(matching action: KeyboardAction) -> Bool {
            defer { calloutSelection = nil }
            return calloutSelection == action
        }

        /// Test hook: drop both latches.
        public static func reset() {
            releaseTouch = nil
            calloutSelection = nil
        }
    }
}
