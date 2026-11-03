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
///
/// F1 (1.1.0) — the card says WHY it is empty. It used to ask for more
/// measurements whenever the insights store held nothing, also when the store
/// had simply not loaded and the overview above it was full of scores.
/// ``InsightsEmptyState/resolve(hasServer:hasDeliveredCards:cardsEmpty:isLoading:hasError:hasRecordedData:)``
/// decides whether it shows.
struct InsightsEmptyStateCard: View {
    let state: InsightsEmptyState

    var body: some View {
        // 1.4 B4 — the lockup stands on the page, never in a card.
        switch state {
        case .needsData:
            HLEmptyState(
                icon: "sparkles",
                title: "No insights yet",
                message: "Insights appear once enough data is logged — capture more measurements."
            )
            .accessibilityIdentifier("insights.empty")
        }
    }
}

/// F1 (1.1.0) — when the Insights overview shows its empty card.
///
/// Since server v1.39 `insights/cards` is rule-based (`provider: "rules"`) and
/// loads with or without AI, so an empty list is the server's own answer only
/// once it has actually answered. The card shows only when there is no recorded
/// data at all — the one case where "capture more measurements" is true.
///
/// 1.4 B2 — the second case ("Gerade keine KI-Zusammenfassung" plus the reason,
/// under an overview full of data) is gone: it reminded people of their own
/// choice on every visit, and the consent case has `CoachReengageCard`.
enum InsightsEmptyState: Equatable {
    case needsData

    static func resolve(
        hasServer: Bool,
        hasDeliveredCards: Bool,
        cardsEmpty: Bool,
        isLoading: Bool,
        hasError: Bool,
        hasRecordedData: Bool
    ) -> InsightsEmptyState? {
        guard hasServer, hasDeliveredCards, cardsEmpty, !isLoading, !hasError else { return nil }
        return hasRecordedData ? nil : .needsData
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
