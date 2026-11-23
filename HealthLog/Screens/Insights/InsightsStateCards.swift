import SwiftUI

// MARK: - Empty + Error

/// When the Insights overview shows its empty card.
///
/// Since server v1.39 `insights/cards` is rule-based (`provider: "rules"`) and
/// loads with or without AI, so an empty list is the server's own answer only
/// once it has actually answered. The card shows only when there is no recorded
/// data at all — the one case where "capture more measurements" is true.
///
/// The second case ("Gerade keine KI-Zusammenfassung" plus the reason,
/// under an overview full of data) is gone: it reminded people of their own
/// choice on every visit, and the consent case has `CoachReengageCard`.
enum InsightsEmptyState: Equatable {
    case needsData

    static func resolve(
        hasDeliveredCards: Bool,
        cardsEmpty: Bool,
        isLoading: Bool,
        hasError: Bool,
        hasRecordedData: Bool
    ) -> InsightsEmptyState? {
        guard hasDeliveredCards, cardsEmpty, !isLoading, !hasError else { return nil }
        return hasRecordedData ? nil : .needsData
    }
}
