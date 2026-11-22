import SwiftUI

/// Single suggestion chip inside the `AskCoachSheet` welcome panel: the
/// app's one choosable chip (`HLChip`), never selected, because a tap sends
/// the question at once.
///
/// **Accessibility:** entire chip is a single tappable element with the
/// suggestion text as its label.
struct AskCoachSuggestionChip: View {
    let text: String
    let icon: String
    let action: () -> Void

    var body: some View {
        HLChip(verbatim: text, systemImage: icon, isSelected: false, action: action)
            .accessibilityHint(String(localized: "Insert suggestion into the input field"))
    }
}

#Preview("AskCoachSuggestionChip") {
    VStack(alignment: .leading, spacing: HLSpace.sm) {
        AskCoachSuggestionChip(
            text: String(localized: "What does my blood pressure mean?"),
            icon: "waveform.path.ecg"
        ) {}
        AskCoachSuggestionChip(
            text: String(localized: "How is my sleep?"),
            icon: "moon.zzz.fill"
        ) {}
        AskCoachSuggestionChip(
            text: String(localized: "Am I active enough today?"),
            icon: "figure.walk"
        ) {}
    }
    .padding()
    .background(HLSurface.primary)
}
