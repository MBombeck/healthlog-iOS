import SwiftUI

// 2026-07-31 (operator) — "Zusammenhänge in deinen Daten" moved out from behind
// the health values and under the Tagesbriefing.
//
// The block used to be a fixed child of `InsightsServerDerivedOverview`, which
// is what the `wellness-scores` section slot mounts — so it always landed
// directly after DEINE GESUNDHEITSWERTE. `InsightsServerDerivedOverview` now
// takes `showsCorrelations: false` there (the same hoisting idiom "Signale des
// Tages" already used), and this slot renders it in its new home.
//
// **Where it is mounted, corrected 2026-08-23 (C2).** This comment used to say
// the block is mounted INSIDE the `dailyBriefing` section case so that it would
// follow the Tagesbriefing through a reorder, and it named the trade-off that a
// hidden Tagesbriefing would take the correlations with it. Neither is true of
// the code any more and had not been for some time: `InsightsOverviewBody`
// mounts this slot at `InsightsOverviewSlots.swift:448`, **after** the `ForEach`
// over every visible section and before the empty/error slot. The block
// therefore trails the whole server-owned section list unconditionally, and a
// hidden Tagesbriefing does not affect it at all.
//
// That anchoring is also what already satisfies the second half of the
// operator's C2 ask ("immer ganz unten … und eingeklappt"): last in the column
// here, and collapsed by default in the block itself
// (`isInitiallyExpanded == false`). No work was owed for it in Phase 17 — only
// this correction, because a comment that describes a mount the code no longer
// performs is the kind of thing that gets "restored" by someone taking it at its
// word.
//
// The reason the block is not a section of its own is unchanged: the server's
// section catalog is mirrored element-wise (a test pins it), so extending it is
// not an option.

// MARK: - Correlations slot (CorrelationsDiscoveryStore + Backend + module gate)

/// Owns the ZUSAMMENHÄNGE IN DEINEN DATEN block. Store-scoped leaf in the same
/// idiom as `InsightsOverviewSlots.swift`: it reads ONLY
/// `CorrelationsDiscoveryStore` + `BackendAvailability` + the `insights` module
/// gate, so a correlations refresh (or a relevance statement round-trip)
/// invalidates this slot alone rather than the whole overview.
///
/// Gating matches the block's previous host exactly (`backend.hasServer` +
/// `insights` module), and the block itself still self-suppresses to nothing when
/// the server returned no surviving pair.
///
/// **CU-33 lives here now.** The block used to be mounted with a hardcoded
/// `correlations: []` (the same dead-mount bug Build-4 item 4.6 fixed for
/// RhythmEvents), so the whole surface self-suppressed forever even though
/// `InsightsScreen` loads and refreshes the store. CU-33 fixed that by reading
/// the store in `InsightsWellnessScoresSlot`; with the block hoisted out, that
/// read — and with it the reversible relevance affordance — moved here.
struct InsightsCorrelationsSlot: View {
    let appContainer: AppContainer?
    /// **C1** — the overview's own metric deep-link, handed down so a pair's
    /// detail shape can jump into the Insights page of either channel. It is the
    /// same closure the vitals and trends slots receive, so a correlation jump
    /// and a tile tap land on exactly the same page.
    var onSelectMetric: ((MetricKind) -> Void)?

    @Environment(CorrelationsDiscoveryStore.self) private var correlationsStore
    @Environment(BackendAvailability.self) private var backend

    var body: some View {
        if backend.hasServer, InsightsOverviewGate.insightsModuleEnabled(appContainer) {
            InsightsCorrelationsDiscoveryBlock(
                pairs: correlationsStore.presentable,
                pairsTested: correlationsStore.response?.pairsTested ?? 0,
                dismissedPairs: correlationsStore.dismissedPairs,
                onSetDismissed: { pair, dismissed in
                    Task { await correlationsStore.setDismissed(dismissed, for: pair) }
                },
                pendingIDs: correlationsStore.pendingIDs,
                resurfacedIDs: correlationsStore.resurfacedIDs,
                actionError: correlationsStore.actionError,
                onSelectMetric: onSelectMetric
            )
        }
    }
}
