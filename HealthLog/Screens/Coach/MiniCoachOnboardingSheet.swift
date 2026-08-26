import SwiftUI

/// Dedicated one-screen onboarding for the Mini-Coach (C5).
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

    @Environment(\.dismiss) private var dismiss
    @State private var didAcknowledge: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.xl) {
                    header
                    scopeCards
                    acknowledgement
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.lg)
                .padding(.bottom, HLSpace.xxxl)
            }
            .hlScreenBackground()
            .navigationTitle(String(localized: "Coach"))
            .navigationBarTitleDisplayMode(.inline)
            // v0.6.1 Y2 — Home-Compliance pattern: drop the 'Abbrechen'
            // cancellationAction (drag-down dismisses without enabling).
            // The 'Aktivieren' CTA at the bottom is functional and stays.
            .safeAreaInset(edge: .bottom) {
                activateBar
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            // REG-2 (2026-05-21): brand hero glyph follows the accent
            // picker. Matches Insights' `sparkles` rhythm (rides on
            // `.tint`, see `InsightsScreen.swift:370`).
            Image(systemName: "sparkles")
                .font(.hlIcon(HLIconSize.hero, weight: .regular))
                .foregroundStyle(.tint)
                .padding(.bottom, HLSpace.xs)
            Text(String(localized: "coach.onboarding.title"))
                .font(.hlTitle3)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
            // UI-Standard R15 (U1) — die Fließtext-Wiederholung „Er erklärt
            // deine Daten — keine medizinischen Empfehlungen." ist entfallen.
            // Derselbe Screen lässt den Nutzer die Aussage 25 Zeilen tiefer
            // AKTIV bestätigen („Ich verstehe: keine medizinischen
            // Empfehlungen …"); eine aktive Bestätigung ist stärker als ihre
            // Vorwegnahme als Prosa (R3 — eine Aussage, ein Ort).
        }
    }

    // MARK: - Scope cards (four operator-locked categories)

    private var scopeCards: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLSectionLabel("What the coach is made for")
                .padding(.horizontal, HLSpace.xs)
            ForEach(ScopeCardModel.allDefault) { model in
                ScopeCard(model: model)
            }
        }
    }

    // MARK: - Acknowledgement + activate bar

    private var acknowledgement: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                Toggle(isOn: $didAcknowledge) {
                    Text(String(localized: "I understand: no medical recommendations, no diagnoses, no therapy suggestions."))
                        .font(.hlBody)
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                // REG-2: scene-root `.tint` already binds to the user's
                // accent pick; no per-Toggle override needed (matches the
                // rest of the app — search Insights, Settings, none of
                // them paint a hardcoded purple tint on a Toggle).
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

    private var activateBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(HLColor.separator)
            // H2 (QOL-AUDIT): canonical `HLButton(.primary)` instead of a
            // hand-rolled `.white`-on-`.tint` CTA. Routes through the contrast
            // clamp (white-on-white risk for `.weiss`/`.schwarz` accent picks)
            // and gets press-shrink + selection haptic + disabled opacity for
            // free; `.disabled(!didAcknowledge)` keeps the acknowledge gate.
            HLButton(String(localized: "Enable"), variant: .primary) {
                store.markOnboarded()
                onEnabled()
                dismiss()
            }
            .disabled(!didAcknowledge)
            .padding(.horizontal, HLSpace.lg)
            .padding(.vertical, HLSpace.md)
            .accessibilityIdentifier("MiniCoachOnboarding.activate")
        }
        // 08-14 — the activate bar is pinned under the scrolling scope cards, so
        // its material is a real translucency over content. `HLMaterialBackground`
        // is the one seam that turns it opaque when the user asked for that.
        .background(HLMaterialBackground(.thinMaterial))
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
        HLCard {
            HStack(alignment: .top, spacing: HLSpace.md) {
                // REG-2: scope-card leading icon follows the accent picker.
                // Matches the Insights `PerKindInsightCard` icon rhythm
                // (rides on `HLText.secondary` for static icons, on
                // `.tint` for branded/accent icons).
                Image(systemName: model.iconSystemName)
                    .font(.hlIcon(HLIconSize.lg, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text(model.title)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Text(model.example)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
