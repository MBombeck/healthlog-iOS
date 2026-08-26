import Foundation
import Observation

/// Front-loads the composite Health Score for the dashboard tile and
/// the detail sheet. Pure server-rendering — score, band, delta, composition
/// and confidence come from the response and are never recomputed locally.
///
/// **v1.34.0 (CU-31) — the source moved.** The server rebuilt the score and the
/// flat client DTO now rides `GET /api/dashboard/snapshot` (`healthScore`);
/// `/api/analytics.healthScore` became the server's internal
/// `HealthScoreReport` and no longer decodes into ``HealthScore``. The store is
/// unchanged — ``AnalyticsRepository/healthScore(asOf:)`` reads the new wire.
///
/// **SWR adoption (F5/F6, v0.4.1):** mirrors `DashboardStore`'s shape —
/// cache-first emit then revalidate. The user-reported gap on iPhone 16 Pro
/// (medication-compliance card paints instantly while Health Score sits
/// multi-second blank) was a missing SWR adoption: every cold-launch fired
/// a fresh `/api/analytics` call after the tile mounted, with no cached
/// previous-session value to render in the meantime.
///
/// Falls back to direct-fetch when `swr` is `nil` (unit tests construct
/// the store without a coordinator); preserves the single-emit semantics
/// existing test expectations rely on.
@MainActor
@Observable
public final class HealthScoreStore {
    public private(set) var score: HealthScore? {
        didSet { onScoreDidChange?(score) }
    }

    /// **v0.15 companion-#3** — fires whenever the resolved `score` changes
    /// (cache emit, fresh fetch, logout-clear). `AppContainer+Widgets` chains
    /// onto this to refresh the App Group health-score-ring widget snapshot.
    /// Non-`@Observable` (plain closure) so it drives the widget side-effect
    /// without entering the view-observation graph.
    public var onScoreDidChange: (@MainActor (HealthScore?) -> Void)?

    public private(set) var lastFetched: Date?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    /// `true` while the visible payload was served from the SWR cache
    /// (`.cached` arm) and the revalidate is still in flight. Drives the
    /// "showing cached" badge on tile/detail surfaces.
    public private(set) var isShowingStaleCache: Bool = false

    private let repo: AnalyticsRepository
    private let swr: SWRCoordinator?

    public init(repo: AnalyticsRepository, swr: SWRCoordinator? = nil) {
        self.repo = repo
        self.swr = swr
    }

    public func load() async {
        // SWR-aware path — kicks in once `swr` is wired by `AppContainer`.
        // Falls back to direct fetch when nil (unit tests).
        // 14-06 — see `MedicationsStore.load`.
        defer {
            if isLoading {
                StoreEffectDiagnostics.recordRefusal(.loadInterrupted, store: .healthScore)
            }
            isLoading = false
        }
        guard let swr else {
            await loadDirect()
            return
        }
        // Reference repo via a local capture so the `@Sendable` closure
        // doesn't reach back into `self` (MainActor isolation).
        let repo = repo
        for await state in await swr.observe(.healthScore, decoding: HealthScore.self, fetch: {
            try await repo.healthScore()
        }) {
            switch state {
            case .empty:
                // First-ever load on this device, no cache yet. UI keeps
                // the skeleton; isLoading drives the spinner.
                isLoading = true
                error = nil
            case let .cached(value, _):
                // FIRST PAINT — sub-100ms when SwiftData is warm.
                score = value
                lastFetched = Date()
                isShowingStaleCache = true
                isLoading = false
            case let .fresh(value):
                score = value
                lastFetched = Date()
                isShowingStaleCache = false
                isLoading = false
                error = nil
            case let .failed(err, lastKnown):
                if let lastKnown {
                    score = lastKnown
                    isShowingStaleCache = true
                }
                isLoading = false
                error = err
            }
        }
    }

    /// Legacy direct-fetch path. Used when no SWR coordinator is injected
    /// (unit tests). Keeps the old single-emit semantics so existing test
    /// expectations against `score != nil` after `load()` still hold.
    private func loadDirect() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let result = try await repo.healthScore()
            score = result
            lastFetched = Date()
            isShowingStaleCache = false
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func refresh() async {
        await load()
    }

    public func clearOnLogout() {
        score = nil
        lastFetched = nil
        error = nil
        isShowingStaleCache = false
    }
}
