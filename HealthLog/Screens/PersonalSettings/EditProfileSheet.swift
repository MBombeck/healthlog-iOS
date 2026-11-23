import SwiftUI

/// Modal presentation wrapper for `EditProfileScreen`.
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
/// hosts the screen's own transient "Saved" cue. The scaffold's Done check
/// mark dismisses the sheet (the auto-save `onDisappear` flush fires on
/// dismissal, so nothing is lost).
struct EditProfileSheet: View {
    var body: some View {
        // The screen saves each field as it goes; the check mark only
        // leaves, and the flush on disappear keeps the last edit.
        HLSheetScaffold("Edit Profile", action: .done()) {
            EditProfileScreen()
        }
    }
}
