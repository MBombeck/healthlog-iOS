import SwiftUI

/// The medication's own note ("30 minutes before food") where a dose is
/// logged, at most two lines as on the web. The detail page shows it in full.
/// Read only: the note is edited on the web for now.
struct MedicationNoteLine: View {
    let note: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Image(systemName: "text.bubble")
                .accessibilityHidden(true)
            Text(verbatim: note)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .hlText(.factLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("med.note.accessibility \(note)"))
    }
}
