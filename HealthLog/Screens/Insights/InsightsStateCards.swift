import SwiftUI

// MARK: - Empty + Error

/// v0.7.0 — migrated to `ContentUnavailableView` (iOS 17+) hosted
/// inside `HLCard` so the empty card sits in the same surrounding scroll
/// rhythm as the other Insights cards. The system primitive carries the
/// glyph + title + description layout; the card chrome stays for visual
/// continuity with the populated state. T2-4 intent ("calm + waiting,
/// not shout in accent") is preserved — the system primitive renders
/// the glyph in tertiary by default.
///
/// v0.8.2 W3b-reconcile — extracted out of `InsightsScreen.swift` so the
/// host file stays under the 1000-line SwiftLint `file_length` error limit
/// after the edit-mode glass chrome (inline "+" + scrim) landed.
struct InsightsEmptyStateCard: View {
    var body: some View {
        HLCard {
            HLEmptyState(
                icon: "sparkles",
                title: "No insights yet",
                message: "Insights appear once enough data is logged — capture more measurements."
            )
            .accessibilityIdentifier("insights.empty")
        }
    }
}

struct InsightsErrorCard: View {
    let error: HLError
    let retry: () -> Void

    var body: some View {
        HLCard(style: .ghost) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(HLColor.statusBad)
                    Text(String(localized: "Couldn't load insights"))
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                }
                Text(error.userFacingDescription)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HLButton(
                    String(localized: "Try again"),
                    variant: .primary,
                    size: .regular
                ) { retry() }
            }
        }
    }
}
