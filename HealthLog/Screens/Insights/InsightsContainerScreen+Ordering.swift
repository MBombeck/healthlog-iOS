import SwiftUI

// MARK: - Ordering + prefetch window (store-reading derivations)

/// W-FILELEN / senior audit M1 — the STORE-READING derivations stay on the View
/// (this same-module extension) so SwiftUI's `@Observable` dependency tracking
/// fires the body when `layoutStore` / `measurementsStore` / the special-page
/// stores / `appContainer.moduleGate` change. They read the model's owned state
/// (`pager.pagerOrder` / `pager.seenKinds` / `pager.seenSpecials` /
/// `pager.selection`) and feed it into the pure decision logic that now lives on
/// `InsightsPagerModel`. The impure transitions (`reconcilePagerOrder`,
/// `realizeWindow`, `mergeSeen*`, `selectionForLandedPage`, …) moved to the model.
extension InsightsContainerScreen {
    /// The LIVE ordered tab list — the *source* the frozen `pager.pagerOrder` is
    /// reconciled from. It grows asynchronously as availability hydrates, which is
    /// exactly why the pager must NOT read it directly (V0150).
    var liveOrderedSelections: [InsightsTabSelection] {
        InsightsTabSelection.ordered(
            layout: layoutStore.layout,
            availableKinds: availableKinds,
            availableSpecials: availableSpecials
        )
    }

    /// V0150 — the FROZEN ordered list the pager + strip render (anchor-stable).
    /// Falls back to the live list before the first reconcile seeds `pager.pagerOrder`.
    var orderedSelections: [InsightsTabSelection] {
        pager.pagerOrder.isEmpty ? liveOrderedSelections : pager.pagerOrder
    }

    /// V0151 — the FOLDED pager page list: one page per strip pill, each category
    /// collapsed to a single group page. Built from the same fold the strip uses
    /// (`InsightsStripEntry.strip(from:)`), so strip pill `i` ↔ pager page `i`.
    var pagerPages: [InsightsPagerPage] {
        InsightsPagerPage.pages(from: orderedSelections)
    }

    /// V0151 — the pager page that hosts the current `selection`. `nil` when the
    /// selection's page isn't present (its metric left availability).
    var pageForSelection: InsightsPagerPage? {
        InsightsPagerPage.page(for: pager.selection, in: pagerPages)
    }

    /// The LIVE (un-latched) availability snapshot — every kind the user has data
    /// for right now.
    ///
    /// v0.13.1 IC — the UNION of two sources:
    /// 1. `measurementsStore.availableKinds` — the all-time per-kind has-data set
    ///    (web-parity); catches low-frequency kinds (BP / weight) outside the
    ///    last-400 `recent` window.
    /// 2. The kinds in the last-400 `recent` page — keeps a freshly captured kind
    ///    lit INSTANTLY and keeps the standalone path correct.
    var liveAvailableKinds: Set<MetricKind> {
        measurementsStore.availableKinds.union(measurementsStore.recent.map(\.kind))
    }

    /// #34 — the latched availability set the strip gates metric pills on: the
    /// union of every kind seen this session (monotonic). A kind enters the moment
    /// it first appears and never leaves during the session, so a single SWR
    /// revalidation cannot collapse `orderedSelections` and snap the operator's
    /// tapped page to `.overview`.
    var availableKinds: Set<MetricKind> {
        // Union with the live snapshot so the very first paint (before
        // `mergeSeenKinds` has run) is already correct — the latch only ever adds.
        let union = pager.seenKinds.union(liveAvailableKinds)
        // #30 — drop metric kinds owned by a server-disabled module (sleep /
        // glucose). Fail-open when the map is absent.
        let disabled = moduleDisabledMetricKinds
        return disabled.isEmpty ? union : union.subtracting(disabled)
    }

    /// #30 — the union of `MetricKind`s owned by every server-disabled module that
    /// has an Insights surface. Empty when no gate is wired / all on.
    var moduleDisabledMetricKinds: Set<MetricKind> {
        guard let gate = appContainer?.moduleGate else { return [] }
        _ = gate.modules // @Observable tracking — re-resolve on a map flip
        var disabled: Set<MetricKind> = []
        for key in ModuleKey.allCases where !gate.isEnabled(key) {
            disabled.formUnion(key.dashboardMetricKinds)
        }
        return disabled
    }

    /// W28c — the LIVE special-page availability: which of mood / medications /
    /// workouts / recovery have ≥1 datum right now. Feeds the special latch.
    var liveAvailableSpecials: Set<InsightsSpecialPage> {
        var specials: Set<InsightsSpecialPage> = []
        if !moodStore.entries.isEmpty { specials.insert(.mood) }
        if !medicationsStore.medications.isEmpty { specials.insert(.medications) }
        // W-B182 (AUDIT-WORKOUTS-RCA) — Workouts is ALWAYS visible, even when the
        // list is empty (it ships its own calm empty-state + sync affordance).
        specials.insert(.workouts)
        // Parity Build 4 / 4.4 — Recovery is UNGATED on data, like the web. The
        // W-B189 `recoveryStore.hasContent` gate is dropped: the web pushes the
        // Recovery pill unconditionally (only the `recovery` module toggle hides
        // it) because the page has no single `summaries[METRIC].count` to gate on
        // and data-gates every block internally, falling back to a calm empty
        // note — the same shape as Workouts directly above. The module gate still
        // applies downstream in `availableSpecials`.
        specials.insert(.recovery)
        // P8 (v0141 parity) — ECG is DATA-gated, deliberately unlike Recovery
        // directly above. The web gates its ECG pill on `hasEcgRecordings`
        // explicitly (`insights-tab-strip.tsx:588`) because ECG has no
        // `MeasurementType` to hang the availability model on, and an account
        // with no strips must see no pill and no page rather than a dead
        // surface. The `insights` module gate still applies downstream in
        // `availableSpecials`.
        if ecgStore.hasRecordings { specials.insert(.ecg) }
        return specials
    }

    /// W28c — the latched special-page availability the strip + pager gate on. Same
    /// monotonic-union latch as `availableKinds`.
    var availableSpecials: Set<InsightsSpecialPage> {
        let union = pager.seenSpecials.union(liveAvailableSpecials)
        // #30 — drop special pages whose owning module is OFF (mood / workouts /
        // recovery). Medications is core (`moduleKey == nil`) → never dropped.
        guard let gate = appContainer?.moduleGate else { return union }
        _ = gate.modules // @Observable tracking
        return union.filter { page in
            guard let key = page.moduleKey else { return true }
            return gate.isEnabled(key)
        }
    }
}
