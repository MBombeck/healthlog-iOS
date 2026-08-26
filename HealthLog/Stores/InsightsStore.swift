import Foundation
import Observation

@MainActor
@Observable
public final class InsightsStore {
    /// Comprehensive payload — server metric digest. `nil` until the first
    /// successful fetch; presence does not imply freshness. Note that the
    /// production `/api/insights/comprehensive` route does not yet emit the
    /// AI-shaped fields (`summary`, `recommendations`, …) the W2b-A4 model
    /// was designed for, so most consumer-facing fields will be empty.
    public private(set) var comprehensive: AIInsightResponse?
    /// Server-rendered insight cards from `/api/insights/cards`. The list
    /// the UI actually paints — derived from the same data sources as
    /// comprehensive but already iOS-shaped (id/title/summary/severity).
    public private(set) var cards: [Insight] = []
    public private(set) var correlations: [CorrelationFinding] = []
    public private(set) var lastFetched: Date?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    /// IDs of recommendations the user has rated this session — UI disables
    /// the thumbs row to avoid double-submits per `15-insights-architecture
    /// §"Feedback row"`.
    public private(set) var feedbackSubmitted: Set<String> = []

    /// Set when the visible payload was served from cache (SWR `.cached` arm).
    public private(set) var isShowingStaleCache: Bool = false
    /// Wall-clock when the visible payload was last refreshed.
    public private(set) var lastUpdatedAt: Date?

    /// v0.7.1 B1.2 (W-INSIGHTS-SKELETON-GATE, A-UIUX-H-1) — latched the first
    /// time the comprehensive surface settles to ANY terminal SWR arm
    /// (`.cached` / `.fresh` / `.failed`) or a `loadDirect()` completes. Once
    /// the primary surface has resolved, the screen has enough to lay out a
    /// coherent first paint and must never re-flash the full-screen skeleton
    /// on a later revalidation — same SWR contract Medications / Dashboard
    /// already honour. Stays `false` only during the true cold-launch window
    /// where nothing has resolved yet.
    public private(set) var hasSettledOnce: Bool = false

    private let repo: InsightsRepository
    private let swr: SWRCoordinator?

    /// Closure the store calls before any insight fetch — must return true
    /// to proceed. Lets `AppContainer` wire the AIConsentStore + active
    /// provider without InsightsStore knowing about either. Default `nil`
    /// (no gate) keeps unit tests building.
    public var consentGate: (@MainActor () -> Bool)?

    public init(repo: InsightsRepository, swr: SWRCoordinator? = nil) {
        self.repo = repo
        self.swr = swr
    }

    /// True if the consent-gate has been wired AND consents the call.
    /// When the gate is nil we permit the call (back-compat for tests).
    private func isConsentGateOpen() -> Bool {
        guard let consentGate else { return true }
        return consentGate()
    }

    /// Load both surfaces in parallel — comprehensive (digest fields, cards)
    /// + cards list. Correlations are deliberately NOT fetched from the
    /// placeholder `/api/insights/correlations` endpoint anymore — v0.4.0
    /// Stream Golf sources them from `comprehensive.digest` instead (per A8
    /// §4: the placeholder route returns `[]` server-side).
    ///
    /// Failures surface via ``error`` and leave the previously-loaded payload
    /// intact (graceful degradation).
    public func load() async {
        guard isConsentGateOpen() else {
            HLLog.ui.info("InsightsStore.load gated by AI consent — skipped")
            return
        }
        // 14-06 — see `MedicationsStore.load`. `.insightsWarm` is a member of the
        // same bounded foreground pass, so this stream meets the same 250 ms
        // cancellation the medications list does. Declared before the first
        // suspension point, which is both where 13-03 put it and what keeps the
        // Phase-06 effect census unchanged.
        defer {
            if isLoading {
                StoreEffectDiagnostics.recordRefusal(.loadInterrupted, store: .insights)
            }
            isLoading = false
        }
        guard let swr else {
            await loadDirect()
            return
        }
        let repo = repo
        async let comprehensiveStream: () = consume(
            stream: swr.observe(.insightsComprehensive, decoding: AIInsightResponse.self, fetch: {
                try await repo.comprehensive()
            })
        )
        async let cardsStream: () = consumeCards(
            stream: swr.observe(.insightsCards, decoding: [Insight].self, fetch: {
                try await repo.cards()
            })
        )
        _ = await (comprehensiveStream, cardsStream)
        lastFetched = Date()
    }

    /// Direct-fetch path — used when no SWR coordinator is injected (unit tests).
    /// Keeps backward-compatibility with tests that assert post-load state.
    private func loadDirect() async {
        isLoading = true
        error = nil
        // v0.7.1 B1.2 — the surface has resolved once this returns regardless
        // of success/failure; a failed fetch still flips the skeleton gate so
        // the screen can paint its error/empty composition instead of
        // spinning the full silhouette forever.
        defer {
            isLoading = false
            hasSettledOnce = true
        }
        do {
            async let comp = repo.comprehensive()
            async let cardsResult = repo.cards()
            let (response, cardsList) = try await (comp, cardsResult)
            comprehensive = response
            cards = cardsList
            lastFetched = Date()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    private func consume(stream: AsyncStream<SWRState<AIInsightResponse>>) async {
        for await state in stream {
            switch state {
            case .empty:
                isLoading = true
                error = nil
            case let .cached(value, _):
                comprehensive = value
                isShowingStaleCache = true
                lastUpdatedAt = Date()
                isLoading = false
                // v0.7.1 B1.2 — a cache hit is enough to lay out a coherent
                // first paint; latch the skeleton gate so the SWR revalidate
                // that follows keeps the (stale) composition instead of
                // re-flashing the silhouette.
                hasSettledOnce = true
            case let .fresh(value):
                comprehensive = value
                isShowingStaleCache = false
                lastUpdatedAt = Date()
                isLoading = false
                error = nil
                hasSettledOnce = true
            case let .failed(err, lastKnown):
                if let lastKnown {
                    comprehensive = lastKnown
                    isShowingStaleCache = true
                }
                isLoading = false
                error = err
                // A failed fetch still resolves the surface — paint the
                // error/empty composition rather than spin forever.
                hasSettledOnce = true
            }
        }
    }

    private func consumeCards(stream: AsyncStream<SWRState<[Insight]>>) async {
        for await state in stream {
            switch state {
            case .empty:
                break
            case let .cached(value, _):
                cards = value
            case let .fresh(value):
                cards = value
            case let .failed(_, lastKnown):
                if let lastKnown {
                    cards = lastKnown
                }
            }
        }
    }

    /// User pulled to refresh — re-fetch from server (cached read).
    /// Per `A4-ai-features-plan.md §"Insights Screen Plan"`, **never**
    /// regenerate locally; that path is reserved for an explicit
    /// "Regenerate" button (rate-limited 10/hr server-side).
    public func refresh() async {
        await load()
    }

    public func submitFeedback(recommendationId: String, helpful: Bool, freeText: String? = nil) async {
        // Optimistic disable — re-enable if the POST throws.
        feedbackSubmitted.insert(recommendationId)
        do {
            try await repo.submitFeedback(
                recommendationId: recommendationId,
                helpful: helpful,
                freeText: freeText
            )
        } catch let err as HLError {
            feedbackSubmitted.remove(recommendationId)
            error = err
        } catch {
            feedbackSubmitted.remove(recommendationId)
            self.error = .unknown(String(describing: error))
        }
    }

    public func clearOnLogout() {
        comprehensive = nil
        cards = []
        correlations = []
        lastFetched = nil
        lastUpdatedAt = nil
        isShowingStaleCache = false
        feedbackSubmitted = []
        error = nil
        // v0.7.1 B1.2 — reset the skeleton latch so the next sign-in cold
        // path shows the coherent silhouette again instead of inheriting the
        // prior session's "already settled" state.
        hasSettledOnce = false
    }

    /// v0.7.1 B1.2 (W-INSIGHTS-SKELETON-GATE, A-UIUX-H-1) — pure fan-out
    /// readiness aggregator. The Insights surface fans out ~7 parallel loads
    /// (comprehensive + cards here, plus health-score / briefing /
    /// measurements / mood / dashboard / targets across sibling stores); with
    /// no aggregated gate each `if let` section flips independently and the
    /// screen flickers section-by-section as each store resolves.
    ///
    /// This collapses every readiness signal into a single decision: show the
    /// coherent full-screen skeleton **only** during the true cold-launch
    /// window where the primary surface has not settled once AND no source —
    /// neither this store nor any sibling feeding a visible section — carries
    /// data yet. The moment any source resolves (or the comprehensive surface
    /// settles to a terminal SWR arm), the gate flips and stays flipped, so a
    /// later SWR revalidation never re-flashes the silhouette.
    ///
    /// Pure + `nonisolated static` so the contract can be pinned by unit tests
    /// without a SwiftUI render pass or a live store graph.
    ///
    /// - Parameters:
    ///   - hasSettledOnce: the comprehensive surface reached a terminal arm.
    ///   - isLoading: a fetch is currently in flight.
    ///   - hasComprehensive: `comprehensive != nil`.
    ///   - hasCards: `!cards.isEmpty`.
    ///   - hasMeasurements: trend-input measurements are present.
    ///   - hasHealthScore: the Health Score tile has a payload.
    ///   - hasTargets: the Ziele tile-grid has at least one target.
    ///   - hasMood: a mood summary / entries are present.
    /// - Returns: `true` while the coherent first-paint silhouette should
    ///   replace the live composition.
    nonisolated static func isInitialSkeletonVisible(
        hasSettledOnce: Bool,
        isLoading: Bool,
        hasComprehensive: Bool,
        hasCards: Bool,
        hasMeasurements: Bool,
        hasHealthScore: Bool,
        hasTargets: Bool,
        hasMood: Bool
    ) -> Bool {
        // Any resolved data source — or the primary surface having settled —
        // means we can lay out a coherent paint; never show the silhouette.
        let anyDataPresent = hasComprehensive
            || hasCards
            || hasMeasurements
            || hasHealthScore
            || hasTargets
            || hasMood
        if hasSettledOnce || anyDataPresent { return false }
        // Cold launch: silhouette only while a fetch is actually in flight so
        // an idle pre-`.task` first frame doesn't paint a skeleton that never
        // had a request behind it.
        return isLoading
    }

    // B2 (v0.4.1): `setProvider(_:)` was removed. The AI-Provider is now owned by
    // a dedicated `AIProviderStore` backed by `GET/PATCH /api/user/ai-provider`
    // (see `HealthLog/Stores/AIProviderStore.swift`). InsightsStore is the
    // *consumer* of generated cards/briefings, not the editor of provider state.
}

// MARK: - Convenience accessors for the UI

public extension InsightsStore {
    /// Daily briefing slot from the comprehensive payload — `nil` when the
    /// server has no briefing yet (new user, < N measurements). v0.4.0 note:
    /// the comprehensive endpoint does **not** emit `dailyBriefing` — the
    /// briefing surface is owned by `DailyBriefingStore` against the
    /// generate endpoint. This accessor stays for back-compat.
    var briefing: DailyBriefing? {
        comprehensive?.dailyBriefing
    }

    /// Recommendations sorted by severity descending so the UI renders
    /// urgent-first per `15-insights-architecture` recommendation order.
    var sortedRecommendations: [Recommendation] {
        guard let comprehensive else { return [] }
        return comprehensive.recommendations.sorted { lhs, rhs in
            lhs.severity.sortRank > rhs.severity.sortRank
        }
    }

    /// The metric-digest half of the comprehensive payload. v0.4.0 Stream Golf
    /// — every comprehensive section (BMI, BP classification, correlations,
    /// alerts, mood summary, data quality) reads from this.
    var digest: ComprehensiveDigest? {
        comprehensive?.digest
    }
}
