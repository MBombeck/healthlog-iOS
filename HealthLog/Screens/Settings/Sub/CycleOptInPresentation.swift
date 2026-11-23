import Foundation

/// **How the cycle-tracking opt-in presents in the Apple-Health
/// special-syncs card.**
///
/// The cycle opt-in is the **legitimate last opt-in path** (the `CycleGate`
/// tertiary override for trans / non-binary / self-test users). Gating it purely
/// on eligibility (`isCycleTrackingAvailable`) would remove the only remaining
/// way in; showing the raw toggle to everyone makes a non-cycle user think an
/// active "cycle tracking" module is on. Option 1 keeps the path reachable but
/// presents it as an *offer* until the user opts in:
///
/// - **toggle** — available (opted-in / female / HK-female / server module):
///   the today's toggle, unchanged.
/// - **offer** — not (yet) available: a neutral "activate cycle tracking?" row
///   instead of a toggle that reads like a live module.
///
/// Pure + SwiftUI-free so the decision is unit-tested without a view host.
/// Wording + offer-vs-toggle form are operator-approved (b244 follow-up): title
/// "Zyklus-Tracking aktivieren?", body naming it optional + reversible, confirm
/// "Zyklus-Tracking aktivieren".
enum CycleOptInPresentation {
    enum Mode: Equatable {
        /// The gate is not (yet) available — present the neutral opt-in offer
        /// instead of a live-looking toggle.
        case offer
        /// The gate is available — the real cycle-tracking toggle, unchanged.
        case toggle
    }

    /// - Parameter available: `CycleGate.isCycleTrackingAvailable`.
    static func mode(available: Bool) -> Mode {
        available ? .toggle : .offer
    }
}
