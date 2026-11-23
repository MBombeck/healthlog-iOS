import SwiftUI

/// Shown on the Coach memory and conversation screens while the server has the
/// Coach switched off: the shared empty state, named once for both screens.
/// A named wrapper around HLEmptyState, not a state view of its own.
struct CoachUnavailableCard: View { // swiftlint:disable:this hl_no_local_state_view
    var body: some View {
        HLEmptyState(
            icon: "cloud",
            title: "coach.unavailable.title",
            message: "coach.unavailable.subtitle"
        )
    }
}

#Preview("CoachUnavailableCard") {
    CoachUnavailableCard()
        .padding()
        .background(HLSurface.primary)
}
