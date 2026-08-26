import SwiftUI

/// Inline validation-error text for `Form` section footers (and equivalent
/// sheet error rows).
///
/// **Audit M3.** Error footers previously relied on `HLColor.statusBad`
/// colour alone. In light mode `statusBad` de-neons (≈ `#D63B3B`), so a
/// colour-blind user can't reliably distinguish an error footer from the
/// neutral hint it replaces. We prefix the message with a leading
/// `exclamationmark.triangle.fill` glyph so the error is signalled by shape
/// + colour, not colour alone. The text remains the VoiceOver-read content
/// (the glyph is decorative and combined into the element).
struct HLFormErrorText: View {
    private let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(HLColor.statusBad)
        // The glyph is a redundant visual cue; VoiceOver reads the message.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Error: \(message)"))
    }
}
