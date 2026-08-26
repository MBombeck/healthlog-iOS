import Foundation

/// **A2 (b244) — how the cycle-tracking opt-in presents in the Apple-Health
/// special-syncs card.**
///
/// The raw `FeatureFlag.cycleTracking` gates whether the cycle opt-in exists at
/// all, but it is the **legitimate last opt-in path** (the `CycleGate` tertiary
/// override for trans / non-binary / self-test users). Gating it purely on
/// eligibility (`isCycleTrackingAvailable`) would remove the only remaining way
/// in; showing the raw toggle to everyone makes a non-cycle user think an active
/// "cycle tracking" module is on. Option 1 keeps the path reachable but presents
/// it as an *offer* until the user opts in:
///
/// - **hidden** — flag off (as today): nothing.
/// - **toggle** — flag on AND available (opted-in / female / HK-female / server
///   module): the today's toggle, unchanged.
/// - **offer** — flag on but not (yet) available: a neutral "activate cycle
///   tracking?" row instead of a toggle that reads like a live module.
///
/// Pure + SwiftUI-free so the three-state decision is unit-tested without a view
/// host. Wording + offer-vs-toggle form are operator-approved (b244 follow-up):
/// title "Zyklus-Tracking aktivieren?", body naming it optional + reversible,
/// confirm "Zyklus-Tracking aktivieren".
enum CycleOptInPresentation {
    enum Mode: Equatable {
        /// The flag is off — the opt-in does not appear at all.
        case hidden
        /// The flag is on but the gate is not (yet) available — present the neutral
        /// opt-in offer instead of a live-looking toggle.
        case offer
        /// The gate is available — the real cycle-tracking toggle, unchanged.
        case toggle
    }

    /// - Parameters:
    ///   - flagOn: `FeatureFlag.cycleTracking`.
    ///   - available: `CycleGate.isCycleTrackingAvailable`.
    static func mode(flagOn: Bool, available: Bool) -> Mode {
        guard flagOn else { return .hidden }
        return available ? .toggle : .offer
    }
}
