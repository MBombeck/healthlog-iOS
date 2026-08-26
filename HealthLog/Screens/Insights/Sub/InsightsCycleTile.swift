import SwiftUI

/// **v0.14.8 CYCLE-polish — the cycle presence on the Insights overview.**
///
/// A calm summary card that surfaces the current cycle phase + "Period in ~N
/// days" on the Insights overview, so the women-only cycle feature has a home in
/// the metric hub (the operator reported it was invisible there). Tapping the
/// card pushes the full ``CycleScreen`` on the shared Insights navigation stack.
///
/// **Hard-gated.** Renders nothing unless ``CycleGate/isCycleTrackingAvailable``
/// is true (women-only resolution + explicit opt-in, behind
/// `FeatureFlag.cycleTracking`), AND the cycle surface is not disabled, AND a
/// prediction exists — so an ineligible / opted-out / still-learning user never
/// sees a hollow tile. It self-loads the cycle store on appear (SWR cache-first;
/// the on-device engine fills the prediction offline), so it paints from cache.
///
/// Monochrome doctrine: the body is monochrome `HLText`; the only colour is the
/// single sparse warm phase-tint dot in the chip, matching the cycle surface.
///
/// **Privacy:** cycle data is highly sensitive — this view logs nothing.
struct InsightsCycleTile: View {
    let store: CycleStore?
    let isAvailable: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isAvailable, let store, !store.isDisabled, let summary {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("cycle.insights.tile.heading")
                NavigationLink {
                    CycleScreen()
                } label: {
                    card(summary)
                }
                .hlPressable() // QOL-AUDIT H1: press feedback
                .accessibilityIdentifier("insights.overview.cycleTile")
            }
            .task { await store.load() }
        } else if isAvailable, let store, !store.isDisabled {
            // Eligible but still learning (no prediction yet): warm the store so the
            // tile appears once the prediction lands, without rendering a hollow card.
            Color.clear.frame(height: 0).task { await store.load() }
        }
    }

    private func card(_ summary: Summary) -> some View {
        HLCard {
            HStack(spacing: HLSpace.md) {
                phaseDot
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(summary.phaseName)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Text(summary.subtitle)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
                Spacer(minLength: HLSpace.sm)
                HLDisclosureChevron()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var phaseDot: some View {
        let tint = summary.map { CyclePhasePalette.tint(for: $0.phase, scheme: colorScheme) } ?? HLText.tertiary
        return ZStack {
            Circle().fill(tint.opacity(colorScheme == .dark ? 0.22 : 0.16))
            Circle().fill(tint).frame(width: 10, height: 10)
        }
        .frame(width: 34, height: 34)
    }

    // MARK: - Summary derivation

    private struct Summary {
        let phase: CyclePhasePalette.Phase
        let phaseName: String
        let subtitle: String
    }

    /// The cycle summary, or `nil` while still learning (no prediction / no
    /// resolvable phase) so the tile self-suppresses rather than show a hollow card.
    private var summary: Summary? {
        guard let store, let verdict = store.verdict?.verdict else { return nil }
        // Z1 (#72) — the phase is the SERVER's. `nil` in OVERDUE and
        // INSUFFICIENT_DATA, and the tile then self-suppresses: a glance surface
        // has no room for the caveat an overdue state needs, and the phase-tinted
        // dot would assert a phase the record does not hold.
        guard let phase = CycleScreenModel.phase(verdict) else { return nil }
        let phaseName = String(localized: CyclePhaseExplainer.nameKey(for: phase))
        return Summary(phase: phase, phaseName: phaseName, subtitle: subtitleText(store: store, verdict: verdict))
    }

    /// "Period in ~N days" / "Period due today" — mirrors the hero ring centre
    /// copy, falling back to the day-of-cycle when no next-period date is known.
    ///
    /// **C1 maturity gate (b183 `38560c9f`).** Below
    /// ``CycleMaturity/minCyclesForFertility`` confirmed cycles (or while the
    /// prediction is flagged `stillLearning`) we do NOT paint a confident
    /// "Period in ~N days" estimate here — the overview tile is a glance surface
    /// with no room for the still-learning caption + disclaimer the full
    /// ``CycleScreen`` carries, so a confident-looking countdown would read as
    /// fact. Instead we show the honest "Still learning your cycle" line and let
    /// the user tap through for the full (captioned) picture. The current phase
    /// itself stays (it is observed, not predicted).
    private func subtitleText(store: CycleStore, verdict: CycleVerdictDTO) -> String {
        let dayLine = verdict.dayOfCycle.map {
            String(format: String(localized: "cycle.home.center.cycleDay"), $0)
        }
        if Self.isStillLearning(
            calendarCyclesObserved: store.calendar?.profile?.cyclesObserved,
            predictionCyclesObserved: store.prediction?.cyclesObserved,
            confirmedCycleCount: store.cycles.filter { !$0.isPredicted }.count,
            stillLearning: store.prediction?.stillLearning
        ) {
            return dayLine ?? String(localized: "cycle.insights.tile.learning")
        }
        // Z1 (#72) — the countdown is the verdict's `daysUntilNext`, resolved
        // server-side against the profile timezone. Nothing is subtracted here.
        if let days = verdict.daysUntilNext {
            if days == 0 { return String(localized: "cycle.insights.tile.dueToday") }
            return String(format: String(localized: "cycle.insights.tile.inDays"), days)
        }
        return dayLine ?? String(localized: "cycle.insights.tile.learning")
    }

    /// Whether the cycle is still in its learning phase — the same maturity
    /// predicate the full ``CycleScreen`` threads into the calendar / summary,
    /// keyed off the observed-cycle count (calendar profile → prediction →
    /// confirmed cycles) and the prediction's own `stillLearning` flag. Pure +
    /// `nonisolated` so the gate is unit-testable without a SwiftUI host.
    nonisolated static func isStillLearning(
        calendarCyclesObserved: Int?,
        predictionCyclesObserved: Int?,
        confirmedCycleCount: Int,
        stillLearning: Bool?
    ) -> Bool {
        let observed = calendarCyclesObserved
            ?? predictionCyclesObserved
            ?? confirmedCycleCount
        return !CycleMaturity.showsFertility(
            cyclesObserved: observed,
            stillLearning: stillLearning
        )
    }
}
