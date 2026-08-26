import SwiftUI

/// **POLISH-COACH (v0.5.5.6)** — single suggestion chip inside the
/// `AskCoachSheet` welcome panel.
///
/// Apple-Award restraint: tinted-but-not-loud capsule (12 % accent fill,
/// 22 % accent stroke) so 3-4 chips can sit next to each other without
/// shouting over the welcome lockup above them. Reads as "suggestion"
/// the way Apple Maps' "Try searching" capsules do.
///
/// **Accessibility:** entire chip is a single tappable element with the
/// suggestion text as its label.
struct AskCoachSuggestionChip: View {
    let text: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: icon)
                    .font(.hlIcon(HLIconSize.sm))
                    .foregroundStyle(.tint)
                Text(text)
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, HLSpace.md)
            .padding(.vertical, HLSpace.sm)
            .background(
                RoundedRectangle(cornerRadius: HLRadius.button, style: .continuous)
                    .fill(.tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HLRadius.button, style: .continuous)
                    .stroke(.tint.opacity(0.22), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: HLRadius.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint(String(localized: "Insert suggestion into the input field"))
        .accessibilityAddTraits(.isButton)
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
