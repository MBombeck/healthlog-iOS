import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// #115 · 1.1 T1 — serialises every sheet the authenticated shell presents.
///
/// TestFlight 1.1.0 (286) aborted on iOS 27 inside
/// `SheetBridge.present(…isPreempting:)` → `dismissViewControllerAnimated:` →
/// `_UIZoomTransitionController` → `_morphPreviewFromCurrentState:` (an
/// `NSAssertionHandler` abort). SwiftUI raised one of the shell's sheets while
/// another presentation still sat on the window's root controller, so it
/// *preempted* that presentation with an animated dismiss. When the presentation
/// it threw away was a zoom transition — the Insights fullscreen chart cover —
/// whose source card had already left the window (tab switched) or whose own
/// morph was still in flight, UIKit could not build a morph preview and aborted.
///
/// The shell used to flip its six sheet flags independently (central "+", the
/// staged capture hand-off, router counters from notifications, Quick Actions,
/// widgets and the Home Vorsorge tile), so nothing stopped a second flag from
/// turning on while the first sheet was still up or still animating out. This
/// gate is the one place that decides:
///
/// - Nothing up → present now (`active` = that sheet until its `onDismiss`).
/// - Something up or tearing down → the request waits in a single slot (latest
///   request wins) and is presented from the `onDismiss` of the current sheet.
/// - A capture-picker request ("+" tap, Control Center widget) while anything is
///   up or waiting is dropped: a re-tap never stacks a second capture surface.
///
/// Pure value type so the ordering rules are unit-testable without a host.
struct ShellSheetGate: Equatable {
    enum Sheet: Hashable {
        case capturePicker
        case measure
        case measurePrefill(MetricKind)
        case mood
        case medicationQuickIntake
        case cycle

        /// The `.sheet` modifier this request drives. `measurePrefill` carries its
        /// kind, but every kind shares one modifier, so dismissal matches by slot.
        var slot: Slot {
            switch self {
            case .capturePicker: .capturePicker
            case .measure: .measure
            case .measurePrefill: .measurePrefill
            case .mood: .mood
            case .medicationQuickIntake: .medicationQuickIntake
            case .cycle: .cycle
            }
        }
    }

    enum Slot: Hashable {
        case capturePicker
        case measure
        case measurePrefill
        case mood
        case medicationQuickIntake
        case cycle
    }

    enum Decision: Equatable {
        /// Flip the sheet's flag now.
        case present(Sheet)
        /// Parked; `didDismiss(_:)` / `resume(blocked:)` hands it back later.
        case deferred
        /// A capture re-tap while the stage is busy — nothing to do.
        case ignored
    }

    /// The shell sheet that is presented or still animating out. Cleared only by
    /// that sheet's `onDismiss`, i.e. once UIKit has finished the dismissal.
    private(set) var active: Sheet?
    /// The one request waiting for the stage.
    private(set) var queued: Sheet?

    var isIdle: Bool {
        active == nil && queued == nil
    }

    /// - Parameter blocked: another shell presentation the gate does not drive
    ///   (the AI consent sheet) currently owns the stage.
    mutating func request(_ sheet: Sheet, blocked: Bool = false) -> Decision {
        let busy = active != nil || blocked
        if sheet == .capturePicker, busy || queued != nil {
            return .ignored
        }
        guard busy else {
            active = sheet
            return .present(sheet)
        }
        queued = sheet
        return .deferred
    }

    /// The sheet in `slot` finished dismissing. Returns the parked request that
    /// may present now, if any.
    mutating func didDismiss(_ slot: Slot, blocked: Bool = false) -> Sheet? {
        guard active?.slot == slot else { return nil }
        active = nil
        return resume(blocked: blocked)
    }

    /// Hands out the parked request once nothing owns the stage any more.
    mutating func resume(blocked: Bool = false) -> Sheet? {
        guard active == nil, !blocked, let next = queued else { return nil }
        queued = nil
        active = next
        return next
    }
}

/// #115 · 1.1 T1 — what the window's root controller is doing right now, read
/// immediately before the shell flips a sheet flag.
///
/// The gate above only knows the shell's own sheets. A presentation raised by a
/// descendant — the Insights fullscreen chart cover (a zoom transition), a context
/// menu, an alert — also sits on the root controller, and SwiftUI preempts it
/// with `dismissIfNeeded(animated:)` when a shell sheet appears. An *animated*
/// preemption of a zoom presentation is the crash site, so:
///
/// - stage clear → present animated, exactly as before;
/// - a foreign presentation settled on screen → present without animation, which
///   makes SwiftUI's preempting dismiss non-animated and skips
///   `_UIZoomTransitionController` entirely;
/// - a foreign presentation still transitioning → wait until it has settled.
enum ShellPresentationStage: Equatable {
    case clear
    case occupied
    case transitioning

    enum Plan: Equatable {
        case presentAnimated
        case presentWithoutAnimation
        case wait
    }

    var plan: Plan {
        switch self {
        case .clear: .presentAnimated
        case .occupied: .presentWithoutAnimation
        case .transitioning: .wait
        }
    }

    /// Pure classification of the root controller's presentation chain.
    static func classify(hasPresented: Bool, isTransitioning: Bool) -> ShellPresentationStage {
        if isTransitioning { return .transitioning }
        return hasPresented ? .occupied : .clear
    }

    #if canImport(UIKit)
        /// Reads the live stage off the key window. No window (unit-test host,
        /// scene teardown) reads as `.clear`, i.e. the pre-T1 behaviour.
        @MainActor
        static func current() -> ShellPresentationStage {
            guard let root = SceneAnchorProvider.shared.resolveWindow()?.rootViewController else { return .clear }
            var transitioning = root.transitionCoordinator != nil
            var presented = root.presentedViewController
            let hasPresented = presented != nil
            while let controller = presented {
                if controller.isBeingPresented || controller.isBeingDismissed || controller.transitionCoordinator != nil {
                    transitioning = true
                }
                presented = controller.presentedViewController
            }
            return classify(hasPresented: hasPresented, isTransitioning: transitioning)
        }
    #endif
}
