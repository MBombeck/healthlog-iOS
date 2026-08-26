import SwiftUI

// v0141 — per-card show/hide support for the Insights-overview wellness score
// cards. Split out of `InsightsScoreCardsBlock.swift` to keep that file under
// the 600-line file-length budget (project file-length discipline).
//
// The hide STATE lives in `WellnessCardVisibilityStore` (a local UserDefaults
// UI-pref, cleared on logout); this file holds the pure catalogue helpers the
// block + the customisation screen share, plus the per-tile long-press menu.

extension InsightsScoreCardsBlock {
    /// The ordered set of score-card ids the operator can individually
    /// hide/show. Every ring/gauge/delta card promoted by this block EXCEPT the
    /// `COINCIDENT_DEVIATION` signals count (that is the honest "Signals of the
    /// day" section, not a hideable value ring). Drives the "Score cards" toggle
    /// list on `SettingsInsightsCustomizationScreen`.
    nonisolated static var hideableCardOrder: [String] {
        ringScoreOrder + [gaugeID, vascularID, hrvBalanceID]
    }

    /// True when a hideable card id would actually render for this
    /// derived-metric list (has a presentable value), mirroring the per-tile
    /// gates in `tiles`. Used by the customisation screen to list only cards the
    /// operator can act on (present now, or explicitly hidden). `nonisolated` so
    /// the settings screen + tests can call it off a SwiftUI host.
    nonisolated static func isCardPresent(_ id: String, in metrics: [DerivedMetricDTO]) -> Bool {
        guard let dto = metrics.first(where: { $0.metric == id }) else { return false }
        switch id {
        case gaugeID: return dto.value != nil
        case hrvBalanceID:
            return isRenderableScore(dto) && WellnessScorePresentation.hrvBalanceValueText(dto) != nil
        default: return isRenderableScore(dto)
        }
    }
}

// MARK: - Parity Build 4 · 4.3 — one source of truth per card

/// Resolves WHICH wellness score cards the Insights overview renders, and in
/// what order, from the two inputs that each own a disjoint slice of the
/// catalogue.
///
/// **The duplication this removes.** `selectedScoreRings` is a server-synced
/// choice (`/api/dashboard/widgets`, visible to web); `WellnessCardVisibilityStore`
/// is a device-local `@AppStorage` hidden-set (invisible to web). Three ids —
/// READINESS / SLEEP_SCORE / RECOVERY_SCORE — exist in BOTH, so before this
/// resolver a card could be "shown" by one and "hidden" by the other with no
/// defined winner. Now each id has exactly one owner:
///
/// - ids in ``ScoreRingID`` → governed by the SERVER selection (and reachable
///   from web);
/// - everything else (STRAIN_SCORE, STRESS_SCORE, FITNESS_AGE,
///   VASCULAR_AGE_DELTA, HRV_BALANCE) → governed by the local hidden-set,
///   because the server models no row for them.
///
/// **Why the rings render here at all.** The web deliberately STOPPED rendering
/// the selected score rings in v1.29.1 and kept the contract specifically to
/// feed iOS — `today-hero.tsx:18-21` says so verbatim: "the score-ring
/// SELECTION contract stays server-side (`selectedScoreRings` on the snapshot
/// still feeds iOS); the web hero simply stops rendering it". This is a
/// documented, intentional divergence between the two clients, NOT drift, and
/// must not be "reconciled" by deleting either side.
enum InsightsScoreCardResolution {
    /// The ids the ring selection owns — the intersection of the server's
    /// selectable set with the Insights card catalogue. `MED_COMPLIANCE` is
    /// selectable but has no Insights card, so it drops out naturally.
    static func selectionGovernedIDs(catalogue: [String]) -> Set<String> {
        let selectable = Set(ScoreRingID.allCases.map(\.rawValue))
        return Set(catalogue.filter { selectable.contains($0) })
    }

    /// The ordered, visible card ids.
    ///
    /// - `selection`: the user's EXPLICIT ring choice, or `nil` when they have
    ///   never picked. `nil` deliberately falls back to "the local hidden-set
    ///   governs everything" — the server default is `[MED_COMPLIANCE]`, which
    ///   would otherwise blank the Insights grid for every untouched account.
    /// - Selected rings lead, in the user's selection order (that order is the
    ///   hero render order too, so the two surfaces read the same).
    static func visibleOrderedIDs(
        catalogue: [String],
        selection: [ScoreRingID]?,
        hidden: Set<String>
    ) -> [String] {
        guard let selection else {
            return catalogue.filter { !hidden.contains($0) }
        }
        let governed = selectionGovernedIDs(catalogue: catalogue)
        let selectedIDs = selection.map(\.rawValue).filter { governed.contains($0) }
        let rest = catalogue.filter { !governed.contains($0) && !hidden.contains($0) }
        return selectedIDs + rest
    }
}

// MARK: - Per-card hide affordance

/// v0141 — attaches a long-press "Hide card" context menu to a wellness score
/// tile. Renders nothing extra for a tile with no hideable id (the cycle tile),
/// so a plain `.modifier(_:)` call site stays uniform. The tap gesture (open the
/// detail sheet) is untouched — only the long-press adds the hide action.
struct HideScoreCardMenu: ViewModifier {
    let id: String?
    let store: WellnessCardVisibilityStore

    func body(content: Content) -> some View {
        if let id {
            content.contextMenu {
                Button(role: .destructive) {
                    store.hide(id)
                } label: {
                    Label(String(localized: "Hide card"), systemImage: "eye.slash")
                }
            }
        } else {
            content
        }
    }
}
