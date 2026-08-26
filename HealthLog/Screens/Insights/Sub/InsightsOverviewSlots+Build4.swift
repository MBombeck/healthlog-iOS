import SwiftUI

// Parity Build 4 · Items 4.2 / 4.5 / 4.6 — the overview section slots added or
// split in Build 4, kept in their own file for file-length discipline (the
// sibling `InsightsOverviewSlots.swift` owns the composition + the pre-existing
// slots). Same store-scoped-leaf idiom as that file: each slot reads the
// SMALLEST set of `@Observable` stores it needs, so a refresh invalidates only
// that slot.

// MARK: - Rhythm-events slot (RhythmEventsStore + Backend + module gate)

/// **Parity Build 4 · 4.6 — the `rhythm-events` overview section.**
///
/// The card (device-flagged categorical-event timeline + the permanent
/// regulatory disclaimer) has existed since v0.12 and was mounted inside
/// `InsightsServerDerivedOverview` — but the overview's only call site handed it
/// a hardcoded empty array, so it suppressed itself unconditionally. The web
/// renders it on BOTH the dashboard and the Insights overview; iOS showed it
/// only as the Home tile. This slot feeds it the real store.
///
/// Self-suppression is unchanged and load-bearing: `RhythmEventsStore.events` is
/// empty on `hasEvents:false` / 404 / 422 / error, and the card renders nothing
/// for an empty list — no header, no shell, no alarming empty card.
struct InsightsRhythmEventsSlot: View {
    let appContainer: AppContainer?

    @Environment(RhythmEventsStore.self) private var rhythmEventsStore
    @Environment(BackendAvailability.self) private var backend

    var body: some View {
        if backend.hasServer, InsightsOverviewGate.insightsModuleEnabled(appContainer) {
            InsightsRhythmEventsCard(events: rhythmEventsStore.events)
        }
    }
}

// MARK: - Clinical-signals slots (ClinicalSignalsStore + Backend + module gate)

/// v1.25 (GH iOS #38) — the baseline-drift health-status card. Self-suppresses
/// when the server read is absent (server-authoritative, paired-only).
///
/// Parity Build 4 · 4.5 — split out of the former combined
/// `InsightsClinicalSignalsSlot` because web models `health-status` and
/// `breathing` as two INDEPENDENT overview sections; keeping them fused would
/// have made one of the two section toggles a lie.
struct InsightsHealthStatusSlot: View {
    let appContainer: AppContainer?

    @Environment(ClinicalSignalsStore.self) private var clinicalSignalsStore
    @Environment(BackendAvailability.self) private var backend

    var body: some View {
        if backend.hasServer, InsightsOverviewGate.insightsModuleEnabled(appContainer) {
            InsightsHealthStatusCard(status: clinicalSignalsStore.healthStatus)
        }
    }
}

/// v1.25 (GH iOS #38) — the sleep-breathing screening card. See
/// ``InsightsHealthStatusSlot`` for why the two are separate slots.
struct InsightsBreathingSlot: View {
    let appContainer: AppContainer?

    @Environment(ClinicalSignalsStore.self) private var clinicalSignalsStore
    @Environment(BackendAvailability.self) private var backend

    var body: some View {
        if backend.hasServer, InsightsOverviewGate.insightsModuleEnabled(appContainer) {
            InsightsBreathingScreeningCard(screening: clinicalSignalsStore.breathing)
        }
    }
}

// MARK: - Labs-changes slot (ClinicalSignalsStore + Backend + module gate)

/// **Parity Build 4 · 4.6 — the `labs-changes` overview section.**
///
/// `LabsChangesCard` was built for v1.25 but mounted in exactly one place
/// (`LabsScreen.swift:202`). The web renders it on the Insights overview too,
/// where "what changed since your last panel" is the piece of lab context that
/// belongs next to the day's other awareness cards. Same DTO, same store, no new
/// data path.
///
/// The dismiss affordance is deliberately NOT offered here: it is keyed to the
/// Labs screen's own per-panel dismissal (`LabsChangesDismissStore`), and a
/// second dismiss button writing the same key would let one surface silently
/// suppress the other. On the overview the card self-suppresses on `hasContent`
/// alone.
struct InsightsLabsChangesSlot: View {
    let appContainer: AppContainer?

    @Environment(ClinicalSignalsStore.self) private var clinicalSignalsStore
    @Environment(BackendAvailability.self) private var backend

    var body: some View {
        if backend.hasServer, InsightsOverviewGate.insightsModuleEnabled(appContainer) {
            LabsChangesCard(changes: clinicalSignalsStore.labsChanges)
        }
    }
}

// MARK: - Vitals slot (DashboardStore)

/// **Parity Build 4 · 4.2 — the `vitals` overview section, remounted.**
///
/// `InsightsVitalsDashboard` was written for W52 and then orphaned: the v0.14.1
/// §4 overview rework dropped its call site and never restored one, leaving a
/// fully-built, fully-tested block with ZERO call sites in the tree. That is the
/// concrete reason the operator reported "BMI / Gewicht / Schlaf sieht man auf
/// der Übersicht nicht" — the web renders `SECTION_VITALS` there and iOS
/// rendered nothing.
///
/// No new data path: it reads `DashboardStore.summary?.metrics`, the same array
/// the Home tiles already fetch, so remounting costs no extra round-trip.
struct InsightsVitalsSlot: View {
    let appContainer: AppContainer?
    /// Deep-nav into a vital's Insights page.
    let onSelect: (MetricKind) -> Void

    @Environment(DashboardStore.self) private var dashboardStore

    var body: some View {
        InsightsVitalsDashboard(
            metrics: dashboardStore.summary?.metrics ?? [],
            onSelect: onSelect,
            container: appContainer
        )
    }
}
