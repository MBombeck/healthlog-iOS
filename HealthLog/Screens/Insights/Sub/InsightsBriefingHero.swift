import SwiftUI

/// Thin wrapper that constructs the `OnDeviceBriefingHero` from the stores
/// already injected into the Insights screen. Factored out of
/// `InsightsScreen.loadedContent` so the screen body stays declarative; the
/// gate (`assistant.briefing` flag) lives at the call site. The hero owns its
/// own resolution
/// ladder (on-device → Statistik-Mode floor → server fallback → EmptyView)
/// and per-day cache, so this wrapper carries no state.
///
/// **v0.11 W-C:** moved out of `InsightsScreen.swift` (was a `private struct`
/// there) into its own file so the screen stays under the length cap after the
/// inline Trends + Correlations rows landed. Kept `struct` (internal) — it's
/// only constructed from `InsightsScreen`.
///
/// **W52-1 (web-parity overview polish):** the wrapper now carries the hero's
/// provenance meta line — the iOS twin of the web hero's `insights.heroGenerated`
/// ("Generated <rel>") timestamp footnote. The hero card itself already renders
/// the labeled provenance ROW ("On your device" / "From your account" / "From
/// your data") inside `DailyBriefingHero`; this wrapper adds the relative-time
/// footnote BELOW the card, sourced from `DailyBriefingStore.lastUpdatedAt` (the
/// only honest generation timestamp iOS holds). It self-suppresses when no
/// server briefing has been fetched — the purely on-device / Statistik-Mode
/// arms have no precise generation instant (the on-device cache is keyed by
/// calendar day, not a timestamp), so claiming one there would be dishonest.
/// `.hlCaption` / `HLText.tertiary`, matte, zero glass.
struct InsightsBriefingHero: View {
    /// v0.10.0 W-Insights (R2 §6.1 Zone 1) — whole-card tap opens the AskCoach
    /// conversation. The single Hero is now the one AI entry point at the top.
    let onTap: (() -> Void)?

    @Environment(MeasurementsStore.self) private var measurementsStore
    @Environment(HealthScoreStore.self) private var healthScoreStore
    @Environment(DailyBriefingStore.self) private var briefingStore
    @Environment(MoodStore.self) private var moodStore
    @Environment(DashboardStore.self) private var dashboardStore
    @Environment(\.appContainer) private var appContainer

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            OnDeviceBriefingHero(
                measurements: measurementsStore.recent,
                healthScore: healthScoreStore.score,
                serverFallback: briefingStore.briefing,
                moodEntries: moodStore.entries,
                compliance: (dashboardStore.summary?.compliance).map(ComplianceSnapshotInput.init(from:)),
                style: .full,
                locale: .current,
                service: appContainer?.onDeviceBriefingService ?? OnDeviceBriefingService(),
                // I-3 ITEM 3 — server AI active (`aiMode == .online`) → prefer the
                // richer server briefing over the on-device / Statistik arm; the
                // on-device path stays the honest fallback when the server arm is
                // empty. On-device / BYO / none keep the on-device-first ladder.
                preferServer: appContainer?.aiMode == .online,
                onTap: onTap
            )
            // v1.18.7 web-parity (❌-3) — "Signals of the day": the
            // present-focused lead of the rebuilt briefing. Server-computed
            // (`dailyBriefing.signalsOfDay`), render-only; self-suppresses when
            // the briefing carries none.
            InsightsSignalsCard(signals: briefingStore.briefing?.signalsOfDay ?? [])
            generatedMetaLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Relative-time provenance footnote ("Generated <rel>"), mirroring the web
    /// hero's `insights.heroGenerated` line. Honest source: only the server
    /// briefing carries a generation instant (`lastUpdatedAt`); for the
    /// on-device / Statistik-Mode arms there is none, so the line stays hidden.
    ///
    /// **v1.16.x `briefingStale` (GH issue #15):** when the rendered prose is
    /// the snapshot's LAST generated briefing (server regenerating or
    /// provider-less), the footnote becomes a small "Stand HH:MM" caption from
    /// `briefingUpdatedAt` — honest staleness instead of a preparing state.
    @ViewBuilder
    private var generatedMetaLine: some View {
        if let staleAsOf = briefingStore.staleBriefingAsOf {
            Text(
                String(
                    format: String(localized: "insights.briefingHero.staleAsOf"),
                    staleAsOf.formatted(date: .omitted, time: .shortened)
                )
            )
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .padding(.horizontal, HLSpace.xs)
            .accessibilityIdentifier("insights.briefingHero.staleAsOf")
        } else if let updatedAt = briefingStore.lastUpdatedAt {
            HStack(spacing: HLSpace.xs) {
                Text(String(localized: "insights.briefingHero.generatedPrefix"))
                Text(updatedAt, format: .relative(presentation: .named))
            }
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .padding(.horizontal, HLSpace.xs)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("insights.briefingHero.generated")
        }
    }
}
