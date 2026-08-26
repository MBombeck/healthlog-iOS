import Foundation

// Parity Build 4 · Items 4.3 / 4.8 — the score-ring slice of the widgets
// layout: the hero ring SELECTION (v1.27.7) and, new in Build 4, the hero ring
// ORDER incl. the health-score anchor. Split out of `DashboardWidgetLayout.swift`
// for file-length discipline; pure movement plus the two order helpers.

public extension DashboardWidgetLayout {
    /// **v1.27.7 — set the hero score-ring selection.** Returns a layout that
    /// carries `selectedScoreRings` (deduped, clamped to
    /// ``ScoreRingID/maxSelected``, order-preserving) so the widgets PUT SENDS
    /// the field — the one path that actually changes the server's stored
    /// choice. Every OTHER helper leaves `selectedScoreRings == nil` (omitted →
    /// preserved). Widgets + version are carried through untouched.
    func settingSelectedScoreRings(_ ids: [ScoreRingID]) -> DashboardWidgetLayout {
        settingScoreRings(selected: ids, heroOrder: nil)
    }

    /// **Parity Build 4 · 4.8 — set the selection AND/OR the hero ring order.**
    ///
    /// One helper for both fields because the ring editor commits them
    /// together: dropping a ring from the selection must also drop it from the
    /// order, and both belong in the SAME PUT so the server never sees a
    /// half-applied edit. `heroOrder: nil` keeps the previous behaviour (send
    /// the selection only, server preserves the stored order); a non-nil order
    /// is reconciled against the new selection first, so an id the user just
    /// deselected can never survive in the order.
    func settingScoreRings(
        selected: [ScoreRingID],
        heroOrder: [HeroRingID]?
    ) -> DashboardWidgetLayout {
        var seen = Set<ScoreRingID>()
        let deduped = Array(
            selected.filter { seen.insert($0).inserted }.prefix(ScoreRingID.maxSelected)
        )
        return DashboardWidgetLayout(
            version: version,
            widgets: widgets,
            selectedScoreRings: deduped.map(\.rawValue),
            heroRingOrder: heroOrder.map { order in
                HeroRingID.resolved(order: order, selected: deduped).map(\.rawValue)
            }
        )
    }

    /// The current hero ring order, reconciled against the current selection —
    /// the pre-fill source for the order editor and the honest read of what the
    /// server will resolve.
    var resolvedHeroRingOrder: [HeroRingID] {
        HeroRingID.resolved(
            order: heroRingOrder?.compactMap(HeroRingID.init(rawValue:)),
            selected: resolvedScoreRingSelection
        )
    }

    /// The current selection parsed back into the closed set (unknown/dropped
    /// ids ignored), falling back to ``ScoreRingID/defaultSelection`` when the
    /// layout carries none — the pre-selection source for the picker.
    var resolvedScoreRingSelection: [ScoreRingID] {
        guard let selectedScoreRings else { return ScoreRingID.defaultSelection }
        let parsed = selectedScoreRings.compactMap(ScoreRingID.init(rawValue:))
        return parsed.isEmpty ? ScoreRingID.defaultSelection : parsed
    }
}
