import SwiftUI

/// **b182 (AUDIT-COACH-PARITY F1) — Insights "Enable the coach" re-engage card.**
///
/// Rendered on the Insights overview when the Coach is currently SUPPRESSED
/// (`aiMode == .none`) but a server provider IS configured and consent is merely
/// missing or was declined once. A declined auto-sheet permanently silences the
/// shell auto-gate (`AuthenticatedShell.swift:250`), so without this card the
/// Insights coach surface is a silent dead end — no path back to the Coach.
///
/// This is the calm counterpart to `AskCoachHeroCard` (the colourful consented-on
/// hero): a quiet `HLCard` with one clear primary action that re-opens the consent
/// choice. Tapping routes through `AIConsentStore.requestExplicitPrompt()`, which
/// presents the consent sheet REGARDLESS of a prior decline; on accept the grant
/// clears the silenced state and the Coach takes over.
///
/// Monochrome by doctrine — the AI-brand colour moment is reserved for the
/// consented hero; an opt-in prompt stays neutral.
struct CoachReengageCard: View {
    let action: () -> Void

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: "sparkles")
                        .font(.hlIcon(HLIconSize.lg))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(HLText.primary)
                        .accessibilityHidden(true)
                    Text(String(localized: "Enable the coach"))
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                }
                Text(
                    String(
                        localized: "Your data, explained. Turn the coach on to ask about your trends, scores, and what to watch."
                    )
                )
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HLButton(String(localized: "Enable the coach"), variant: .primary, size: .regular, action: action)
                    .accessibilityIdentifier("InsightsScreen.coachReengageCard.button")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("InsightsScreen.coachReengageCard")
    }
}

#Preview("CoachReengageCard") {
    VStack(spacing: HLSpace.lg) {
        CoachReengageCard {}
    }
    .padding(HLSpace.lg)
    .background(HLSurface.primary)
}
