import SwiftUI

/// SET-6 (AUDIT-QOL-UX §5) — modal presentation wrapper for `EditProfileScreen`.
///
/// Every other edit surface in the app — `EditMeasurementSheet`,
/// `EditMedicationSheet`, `EditMoodSheet` — is presented as a **sheet** (an edit
/// is a modal transaction, like the capture flows). `EditProfileScreen` was the
/// lone exception, pushed onto the navigation stack. The QoL audit flagged this
/// as an Edit-flow divergence; this wrapper standardizes it on the canonical
/// sheet idiom so profile editing feels like every other edit.
///
/// The screen itself auto-saves (`EditProfileScreen` debounces field commits and
/// flushes on `onDisappear`), so there is no Save button — the trailing toolbar
/// hosts the screen's own transient "Saved" cue. A leading **Done** button
/// dismisses the sheet (the auto-save `onDisappear` flush fires on dismissal,
/// so nothing is lost). `.form` height + drag indicator come from the canonical
/// `hlSheetPresentation` token, matching the other edit sheets.
struct EditProfileSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EditProfileScreen()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "Done")) { dismiss() }
                            .accessibilityIdentifier("editProfile.done")
                    }
                }
        }
        .hlSheetPresentation(.form)
    }
}
