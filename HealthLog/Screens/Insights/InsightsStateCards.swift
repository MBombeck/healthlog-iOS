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
/// had simply not loaded (no AI set up, 1.0.4) and the overview above it was
/// full of scores. ``InsightsEmptyState/resolve(hasServer:hasDeliveredCards:cardsEmpty:isLoading:hasError:hasRecordedData:briefing:)``
/// decides whether it shows and with which sentence.
struct InsightsEmptyStateCard: View {
    let state: InsightsEmptyState

    var body: some View {
        HLCard {
            switch state {
            case .needsData:
                HLEmptyState(
                    icon: "sparkles",
                    title: "No insights yet",
                    message: "Insights appear once enough data is logged — capture more measurements."
                )
                .accessibilityIdentifier("insights.empty")
            case let .aiUnavailable(reason):
                HLEmptyState(
                    icon: "sparkles",
                    title: Text(String(localized: "insights.empty.ai.title")),
                    message: Text(verbatim: InsightsEmptyState.message(for: reason))
                )
                .accessibilityIdentifier("insights.empty.ai")
            }
        }
    }
}

/// F1 (1.1.0) — when the Insights overview shows its empty card, and what it
/// says.
///
/// Since server v1.39 `insights/cards` is rule-based (`provider: "rules"`) and
/// loads with or without AI, so an empty list is the server's own answer only
/// once it has actually answered. The sentence then follows the real reason:
/// - no recorded data at all → ask for measurements (the one case where that
///   is true);
/// - data, but the AI summary layer (`ai.capabilities.briefing`) is off → name
///   the reason the server gives, never "capture more";
/// - data and AI available → no card: the sections above carry the data and
///   there is nothing to excuse.
enum InsightsEmptyState: Equatable {
    case needsData
    case aiUnavailable(AIUnavailableReason)

    static func resolve(
        hasServer: Bool,
        hasDeliveredCards: Bool,
        cardsEmpty: Bool,
        isLoading: Bool,
        hasError: Bool,
        hasRecordedData: Bool,
        briefing: AICapabilityState
    ) -> InsightsEmptyState? {
        guard hasServer, hasDeliveredCards, cardsEmpty, !isLoading, !hasError else { return nil }
        guard hasRecordedData else { return .needsData }
        guard !briefing.isAvailable else { return nil }
        return .aiUnavailable(briefing.reason ?? .unknown)
    }

    /// The reason sentence plus the note that the values above are the
    /// server's. `nonisolated` + `String` so tests pin both languages without
    /// a render pass.
    nonisolated static func message(for reason: AIUnavailableReason) -> String {
        let why = switch reason {
        case .operatorDisabled:
            String(localized: "insights.empty.ai.reason.operator")
        case .moduleDisabled, .userDisabled:
            String(localized: "insights.empty.ai.reason.switchedOff")
        case .noProvider:
            String(localized: "insights.empty.ai.reason.noProvider")
        case .consentRequired:
            String(localized: "insights.empty.ai.reason.consent")
        case .notPermittedForRecord:
            String(localized: "insights.empty.ai.reason.record")
        case .checkFailed, .unknown:
            String(localized: "insights.empty.ai.reason.unknown")
        }
        return why + " " + String(localized: "insights.empty.ai.dataNote")
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
