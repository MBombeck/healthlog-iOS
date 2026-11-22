import SwiftUI

/// **The small "aus Apple Health" provenance mark.**
///
/// Rendered on a medication that is a read-only mirror of an Apple Health
/// (HealthKit) medication. Signals WHY the manual dose-logging controls are
/// absent on that card: the doses are owned by Apple Health (source-exclusive),
/// so logging here would double-count. Purely presentational.
struct AppleHealthProvenanceBadge: View {
    var body: some View {
        // The same mark as the others on the card, so they stand equally tall.
        HLBadge(String(localized: "medications.appleHealth.provenance"), icon: "heart.text.square.fill")
    }
}
