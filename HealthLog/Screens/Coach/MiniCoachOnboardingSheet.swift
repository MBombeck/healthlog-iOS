import SwiftUI

/// Dedicated one-screen onboarding for the Mini-Coach.
///
/// **Operator decision (Q-MC-2 default):** the scope-statement + explicit
/// acknowledgement live in their own sheet so the MDR boundary is read
/// before any first ask lands. The CTA stays disabled until the user
/// ticks "Ich verstehe…" — *no* dark-pattern auto-tick, *no* pre-checked
/// box.
///
/// Cards mirror the four operator-locked categories
/// (`MiniCoachPrompt.AllowedCategory`):
///   - **C-A** data-lookup  ("Mein letztes Gewicht")
///   - **C-B** period-summary ("Wie war meine Woche?")
///   - **C-C** historic-lookup ("Mein Puls am 1. März")
///   - **C-D** comparison    ("Diese Woche vs. letzte Woche")
///
/// Acknowledge → flips `hl.minicoach.onboarded` + `hl.minicoach.enabled`
/// in UserDefaults and dismisses; cancel → dismiss without enabling.
struct MiniCoachOnboardingSheet: View {
    let store: MiniCoachStore
    /// Called after the user taps the "Aktivieren" CTA — the parent flips
    /// the AppStorage-backed enabled flag so the surface stays in sync
    /// with whatever Settings displays. The Settings toggle owns the key
    /// via `@AppStorage`; this callback bridges sheet-acknowledge → toggle.
    let onEnabled: () -> Void

    @State private var didAcknowledge: Bool = false

    var body: some View {
        // Enabling is the sheet's one confirmation, in the bar like every
        // other sheet's; it stays off until the acknowledgement is given.
        HLSheetScaffold(
            "Coach",
            action: .confirm("Enable", isEnabled: didAcknowledge) {
                store.markOnboarded()
                onEnabled()
                return true
            }
        ) {
            HLPage {
                header
                scopeCards
                acknowledgement
            }
        }
    }

    // MARK: - Header

    /// The Coach's one head form, the empty-state lockup. No sentence under
    /// it: the acknowledgement further down states the limits, and an active
    /// confirmation says more than its preview in prose.
    private var header: some View {
        HLEmptyState(icon: "sparkles", title: "coach.onboarding.title")
    }

    // MARK: - Scope cards (four operator-locked categories)

    /// One card of rows, as every list of the app: the category as the
    /// title, its example question as the one detail line.
    @ViewBuilder
    private var scopeCards: some View {
        HLSectionHeader("What the coach is made for")
        HLCard(layout: .rows) {
            ForEach(ScopeCardModel.allDefault) { model in
                ScopeCard(model: model)
            }
        }
    }

    // MARK: - Acknowledgement

    private var acknowledgement: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Toggle(isOn: $didAcknowledge) {
                    Text(String(localized: "I understand: no medical recommendations, no diagnoses, no therapy suggestions."))
                        .font(.hlBody)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The app's switch, green when on like every other one.
                .toggleStyle(.hl)
                .accessibilityIdentifier("MiniCoachOnboarding.ack")

                Text(
                    String(localized: "On device — no cloud, no recording of the conversation beyond the current session.")
                )
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Scope card model + view

struct ScopeCardModel: Identifiable {
    let id: String
    let title: String
    let example: String
    let iconSystemName: String

    static let allDefault: [ScopeCardModel] = [
        .init(
            id: "data-lookup",
            title: String(localized: "Look up values"),
            example: String(localized: "“My latest weight?”"),
            iconSystemName: "magnifyingglass"
        ),
        .init(
            id: "period-summary",
            title: String(localized: "coach.scope.periodSummary.title"),
            example: String(localized: "“How was my week?”"),
            iconSystemName: "calendar"
        ),
        .init(
            id: "historic-lookup",
            title: String(localized: "Past values"),
            example: String(localized: "“My heart rate on March 1?”"),
            iconSystemName: "clock.arrow.circlepath"
        ),
        .init(
            id: "comparison",
            title: String(localized: "coach.scope.compare.title"),
            example: String(localized: "“This week vs. last week?”"),
            iconSystemName: "chart.bar.xaxis"
        )
    ]
}

private struct ScopeCard: View {
    let model: ScopeCardModel

    var body: some View {
        HLRow(title: Text(model.title), detail: Text(model.example)) {
            HLRowGlyph(symbol: model.iconSystemName)
        }
        .accessibilityElement(children: .combine)
    }
}
