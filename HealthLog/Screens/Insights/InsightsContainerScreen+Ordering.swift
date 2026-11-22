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
    /// exactly why the pager must NOT read it directly.
    var liveOrderedSelections: [InsightsTabSelection] {
        InsightsTabSelection.ordered(
            layout: layoutStore.layout,
            availableKinds: availableKinds,
            availableSpecials: availableSpecials,
            recoveryKinds: recoveryKinds
        )
    }

    /// The recovery family members with a current reading, as the server
    /// summarised them (`RecoveryInsightsStore.layout`), joined with the ones
    /// already seen this session so a refresh cannot pull a page from under
    /// the pager. In the family's order; empty while the module is off.
    var recoveryKinds: [MetricKind] {
        if let gate = appContainer?.moduleGate {
            _ = gate.modules // @Observable tracking
            if !gate.isEnabled(.recovery) { return [] }
        }
        let live = Set(liveRecoveryKinds)
        return RecoveryInsightsRepository.familyOrder.filter { live.contains($0) || pager.seenRecoveryKinds.contains($0) }
    }

    /// The recovery members the family reports right now.
    var liveRecoveryKinds: [MetricKind] {
        let layout = recoveryStore.layout
        return (layout.trends + layout.rows).map(\.kind)
    }

    /// The FROZEN ordered list the pager + strip render (anchor-stable).
    /// Falls back to the live list before the first reconcile seeds `pager.pagerOrder`.
    var orderedSelections: [InsightsTabSelection] {
        pager.pagerOrder.isEmpty ? liveOrderedSelections : pager.pagerOrder
    }

    /// The FOLDED pager page list: one page per strip pill, each category
    /// collapsed to a single group page. Built from the same fold the strip uses
    /// (`InsightsStripEntry.strip(from:)`), so strip pill `i` ↔ pager page `i`.
    var pagerPages: [InsightsPagerPage] {
        InsightsPagerPage.pages(from: orderedSelections)
    }

    /// The pager page that hosts the current `selection`. `nil` when the
    /// selection's page isn't present (its metric left availability).
    var pageForSelection: InsightsPagerPage? {
        InsightsPagerPage.page(for: pager.selection, in: pagerPages)
    }

    /// The LIVE (un-latched) availability snapshot — every kind the user has data
    /// for right now.
    ///
    /// The UNION of two sources:
    /// 1. `measurementsStore.availableKinds` — the all-time per-kind has-data set
    ///    (web-parity); catches low-frequency kinds (BP / weight) outside the
    ///    last-400 `recent` window.
    /// 2. The kinds in the last-400 `recent` page — keeps a freshly captured kind
    ///    lit INSTANTLY.
    ///
    /// RMSSD has no page of its own; it is shown on the HRV page
    /// (`RecoveryInsightsStore.displayKind(for:)`). An account whose wearable
    /// only reports RMSSD therefore lights the HRV page too, or it would reach
    /// its readings nowhere.
    var liveAvailableKinds: Set<MetricKind> {
        Self.pageKinds(for: measurementsStore.availableKinds.union(measurementsStore.recent.map(\.kind)))
    }

    /// The metric pages `kinds` light: each kind its own, RMSSD the HRV page.
    nonisolated static func pageKinds(for kinds: Set<MetricKind>) -> Set<MetricKind> {
        kinds.contains(.hrvRMSSD) ? kinds.union([.hrv]) : kinds
    }

    /// The latched availability set the strip gates metric pills on: the
    /// union of every kind seen this session (monotonic). A kind enters the moment
    /// it first appears and never leaves during the session, so a single SWR
    /// revalidation cannot collapse `orderedSelections` and snap the operator's
    /// tapped page to `.overview`.
    var availableKinds: Set<MetricKind> {
        // Union with the live snapshot so the very first paint (before
        // `mergeSeenKinds` has run) is already correct — the latch only ever adds.
        let union = pager.seenKinds.union(liveAvailableKinds)
        // Drop metric kinds owned by a server-disabled module (sleep /
        // glucose). Fail-open when the map is absent.
        let disabled = moduleDisabledMetricKinds
        return disabled.isEmpty ? union : union.subtracting(disabled)
    }

    /// The union of `MetricKind`s owned by every server-disabled module that
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

    /// The LIVE special-page availability: which of mood / medications /
    /// workouts / ECG have ≥1 datum right now. Feeds the special latch.
    var liveAvailableSpecials: Set<InsightsSpecialPage> {
        var specials: Set<InsightsSpecialPage> = []
        if !moodStore.entries.isEmpty { specials.insert(.mood) }
        if !medicationsStore.medications.isEmpty { specials.insert(.medications) }
        // Workouts is ALWAYS visible, even when the
        // list is empty (it ships its own calm empty-state + sync affordance).
        specials.insert(.workouts)
        // P8 (v0141 parity) — ECG is DATA-gated, deliberately unlike Workouts
        // directly above. The web gates its ECG pill on `hasEcgRecordings`
        // explicitly (`insights-tab-strip.tsx:588`) because ECG has no
        // `MeasurementType` to hang the availability model on, and an account
        // with no strips must see no pill and no page rather than a dead
        // surface. ECG has no owning module (server v1.39), so nothing
        // downstream in `availableSpecials` removes it again.
        if ecgStore.hasRecordings { specials.insert(.ecg) }
        return specials
    }

    /// The latched special-page availability the strip + pager gate on. Same
    /// monotonic-union latch as `availableKinds`.
    var availableSpecials: Set<InsightsSpecialPage> {
        let union = pager.seenSpecials.union(liveAvailableSpecials)
        // Drop special pages whose owning module is OFF (mood / workouts /
        // medications).
        guard let gate = appContainer?.moduleGate else { return union }
        _ = gate.modules // @Observable tracking
        return union.filter { $0.isModuleEnabled(in: gate) }
    }
}
