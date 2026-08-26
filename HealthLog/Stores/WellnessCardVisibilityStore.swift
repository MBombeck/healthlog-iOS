import Foundation
import Observation

/// Local UI-preference store for the per-card show/hide state of the
/// Insights-overview **wellness score cards** (Daily condition / Sleep score /
/// Recovery / Stress / Daily load / Cardio fitness / Vascular age / HRV balance).
///
/// **Parity Build 4 · 4.3 — this store no longer owns every card.** Three of the
/// eight ids (`READINESS` / `SLEEP_SCORE` / `RECOVERY_SCORE`) are also members of
/// the server-synced `selectedScoreRings` set, so before Build 4 the same card
/// had two independent visibility controls with no defined winner — and one of
/// them (this one) was invisible to the web client entirely. The split is now
/// explicit and disjoint: any id in ``ScoreRingID`` is governed by the SERVER
/// selection, and this store governs only the rest (`STRAIN_SCORE`,
/// `STRESS_SCORE`, `FITNESS_AGE`, `VASCULAR_AGE_DELTA`, `HRV_BALANCE`), which
/// the server models no row for. `InsightsScoreCardResolution` is the single
/// place that arbitration lives.
///
/// **Why local, not server** (for the ids it still owns). The dashboard tile-strip
/// (`/api/dashboard/widgets` → `DashboardLayoutStore`) and the Insights
/// tab-strip (`/api/insights/layout` → `InsightsLayoutStore`) are both
/// server-synced LAYOUT surfaces the operator already curates. The wellness
/// score cards are different: they are on-device projections of
/// `DerivedInsightsStore` with NO server layout row of their own, so their
/// show/hide is a pure UI preference the server does not model. It therefore
/// lives in the sanctioned UserDefaults UI-pref tier (PROJECT_GUIDE.md: "UserDefaults
/// (UI-Prefs only)"), keyed by the derived-metric id (`READINESS` /
/// `RECOVERY_SCORE` / `FITNESS_AGE` / …).
///
/// **Default = nothing hidden** — non-breaking, the current behaviour. The
/// operator hides a card that can never fill for them (e.g. Cardio-fitness /
/// Recovery with no Apple Watch, which otherwise sits there as a permanent
/// "no data" tile) via the card's long-press "Hide card" action, and re-enables
/// it from the Insights customisation screen's "Score cards" toggles.
///
/// Cleared on logout (`LogoutClearable`, wired through `AppContainer`'s Mirror
/// registry) so a hidden-set never bleeds across an account switch.
@MainActor
@Observable
public final class WellnessCardVisibilityStore {
    /// The set of derived-metric ids the operator has explicitly hidden. Empty
    /// by default → every renderable score card shows (current behaviour).
    public private(set) var hiddenIDs: Set<String>

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "hl.insights.hiddenWellnessCards"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenIDs = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    /// True when `id` is currently hidden by the operator.
    public func isHidden(_ id: String) -> Bool {
        hiddenIDs.contains(id)
    }

    /// Hide or show one card id and persist. Idempotent (a no-op write does not
    /// touch UserDefaults or the observed set).
    public func setHidden(_ id: String, _ hidden: Bool) {
        if hidden {
            guard !hiddenIDs.contains(id) else { return }
            hiddenIDs.insert(id)
        } else {
            guard hiddenIDs.contains(id) else { return }
            hiddenIDs.remove(id)
        }
        persist()
    }

    /// Convenience — hide `id` (the long-press "Hide card" path).
    public func hide(_ id: String) {
        setHidden(id, true)
    }

    /// Convenience — show `id` (the customisation-screen re-enable path).
    public func show(_ id: String) {
        setHidden(id, false)
    }

    private func persist() {
        // Sorted for a stable, deterministic on-disk representation.
        defaults.set(hiddenIDs.sorted(), forKey: storageKey)
    }

    /// `LogoutClearable` — reset to the pristine "nothing hidden" default so a
    /// hidden-set never carries into a different account.
    public func clearOnLogout() {
        hiddenIDs = []
        defaults.removeObject(forKey: storageKey)
    }
}
