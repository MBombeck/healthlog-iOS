import Foundation
import Observation

/// SWR-backed store for the Daily Briefing surface.
///
/// **Background (A8 §5):** Until v0.4.0 the Insights screen bound `DailyBriefingHero`
/// to `InsightsStore.briefing → comprehensive.dailyBriefing`. The production
/// `/api/insights/comprehensive` route does **not** emit `dailyBriefing` —
/// it ships on `/api/insights/generate` only. The hero strip therefore never
/// painted real data; the top user-quoted gap.
///
/// **This store** owns the briefing surface end-to-end:
/// - Lazy fetch on Insights tab open (`load()`).
/// - SWR cache TTL 24h — server-side cache is also per-user-per-day, so
///   a hit on cached state burns no provider tokens.
/// - Explicit refresh (`refresh()`) sets `force=true`, bypassing the cache.
///
/// Mirrors `DashboardStore`'s SWR-aware shape (`isShowingStaleCache`,
/// `lastUpdatedAt`) so UI cards can badge stale data.
@MainActor
@Observable
public final class DailyBriefingStore {
    public private(set) var response: AIInsightResponse?
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    public private(set) var isShowingStaleCache: Bool = false
    /// Wall-clock when the visible payload was last refreshed.
    public private(set) var lastUpdatedAt: Date?

    private let repo: InsightsRepository
    private let swr: SWRCoordinator?

    /// Closure the store calls before any briefing fetch — must return true
    /// to proceed. Mirrors `InsightsStore.consentGate` so the AppContainer
    /// can wire `AIConsentStore` + active provider without DailyBriefingStore
    /// knowing about either. Default `nil` (no gate) keeps unit tests
    /// building. **Per Apple Guideline 5.1.2(i) (Nov 2025) and PA9 RC5:
    /// any off-device LLM call MUST consult this gate before transmitting
    /// health data.** Previously the briefing endpoint bypassed consent
    /// entirely — that hole is closed in v0.5.0+.
    public var consentGate: (@MainActor () -> Bool)?

    /// **v1.16.x (GH issue #15)** — best-effort fetch of the briefing slot on
    /// `GET /api/dashboard/snapshot`. Injected as a closure (AppContainer
    /// wires `DashboardRepository.snapshotBriefing`) so the store stays
    /// decoupled from the dashboard repo and unit tests can stub it. NOT
    /// consent-gated: the route is a read-only lift of the pre-generated
    /// cache — no LLM is reachable, no health data leaves the account.
    public var snapshotFetch: (@Sendable () async throws -> DashboardSnapshotBriefing?)?

    /// **BH-final-diff M4** — the profile (server) IANA timezone the briefing
    /// day-anchor buckets on. The dashboard + compliance day keys already
    /// migrated off a hardcoded `Europe/Berlin` onto the profile TZ
    /// (`MedicationDayKey.string(timeZone:)`); the briefing was left on Berlin,
    /// so a US-Pacific user's briefing rolled over at Berlin midnight (their
    /// mid-afternoon). Wired by `AppContainer` (resolves `settingsStore`'s
    /// profile TZ). Default `.current` keeps existing unit-test call-sites
    /// byte-unchanged.
    public var profileTimeZoneProvider: @Sendable () -> TimeZone = { .current }

    /// The briefing day-anchor in the profile TZ — the SWR cache-key
    /// discriminator that rolls the cached briefing over at the profile day
    /// boundary (consistent with dashboard/compliance).
    private func briefingDayKey() -> String {
        MedicationDayKey.string(timeZone: profileTimeZoneProvider())
    }

    /// Last successfully fetched snapshot briefing slot. Drives the
    /// `briefingStale` ("Stand HH:MM") + `no-provider` (deterministic
    /// fallback, never a spinner) render branches via ``snapshotRenderPolicy``.
    public private(set) var snapshotBriefing: DashboardSnapshotBriefing?

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

    /// Refreshes ``snapshotBriefing`` from the injected `snapshotFetch`.
    /// Best-effort + additive: a failed read keeps the last known slot and
    /// never surfaces an error — the generate-path response stays the
    /// authoritative briefing source; the snapshot only adds the
    /// stale/no-provider honesty signals.
    public func loadSnapshotBriefing() async {
        guard let snapshotFetch else { return }
        do {
            if let slot = try await snapshotFetch() {
                snapshotBriefing = slot
            }
        } catch {
            HLLog.ui.info("DailyBriefingStore snapshot briefing fetch failed — keeping last slot")
        }
    }

    /// First-paint / tab-open load. Uses SWR when wired: cache-first emit then
    /// revalidate. Falls back to direct fetch when `swr` is nil (unit tests).
    public func load() async {
        // The snapshot read is independent of the AI-consent gate (read-only,
        // no LLM server-side) — fetch it even when the generate-call is gated
        // so the stale/no-provider render branches stay honest.
        // 14-06 — see `MedicationsStore.load`. Declared before the first
        // suspension point: `.empty` raises `isLoading` and only a terminal
        // emission lowered it, so a cancelled stream stranded it for the life of
        // the process. The consent-gated and direct-fetch returns below settle
        // the flag harmlessly — it is not raised on either path.
        defer {
            if isLoading {
                StoreEffectDiagnostics.recordRefusal(.loadInterrupted, store: .dailyBriefing)
            }
            isLoading = false
        }
        await loadSnapshotBriefing()
        guard isConsentGateOpen() else {
            HLLog.ui.info("DailyBriefingStore.load gated by AI consent — skipped")
            return
        }
        guard let swr else {
            await loadDirect()
            return
        }
        let repo = repo
        // AUD-6 Critical #1 / BH-final-diff M4 — PROFILE-TZ-day-anchored key so a
        // new calendar day (in the user's server-profile zone) is a structural
        // cache miss (yesterday's briefing no longer served all of today).
        // Mirrors the dashboard/compliance day keys (profile TZ, not Berlin).
        for await state in await swr.observe(.dailyBriefing(day: briefingDayKey()), decoding: AIInsightResponse.self, fetch: {
            try await repo.generateBriefing(force: false)
        }) {
            switch state {
            case .empty:
                isLoading = true
                error = nil
            case let .cached(value, _):
                response = value
                lastUpdatedAt = Date()
                isShowingStaleCache = true
                isLoading = false
            case let .fresh(value):
                response = value
                lastUpdatedAt = Date()
                isShowingStaleCache = false
                isLoading = false
                error = nil
            case let .failed(err, lastKnown):
                if let lastKnown {
                    response = lastKnown
                    isShowingStaleCache = true
                }
                isLoading = false
                error = err
            }
        }
    }

    /// Explicit user-initiated refresh — bypasses the 24h cache. Writes the
    /// fresh result back into the SWR cache so subsequent observes get the
    /// new value as cached-arm.
    public func refresh() async {
        guard isConsentGateOpen() else {
            HLLog.ui.info("DailyBriefingStore.refresh gated by AI consent — skipped")
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let fresh = try await repo.generateBriefing(force: true)
            response = fresh
            lastUpdatedAt = Date()
            isShowingStaleCache = false
            await swr?.writeThrough(.dailyBriefing(day: briefingDayKey()), value: fresh)
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    private func loadDirect() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let fresh = try await repo.generateBriefing(force: false)
            response = fresh
            lastUpdatedAt = Date()
            isShowingStaleCache = false
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func clearOnLogout() {
        response = nil
        error = nil
        lastUpdatedAt = nil
        isShowingStaleCache = false
        snapshotBriefing = nil
    }
}

// MARK: - Convenience accessors

public extension DailyBriefingStore {
    /// Daily briefing block — `nil` when the server has no briefing yet.
    ///
    /// **v1.16.x (GH issue #15):** falls back to the snapshot-delivered
    /// briefing (fresh `ready` OR `briefingStale: true` last-good text) when
    /// the generate-path response carries none, so the hero paints the last
    /// generated prose instead of a preparing/empty state.
    var briefing: DailyBriefing? {
        response?.dailyBriefing ?? snapshotBriefing?.deliverableBriefing
    }

    /// Canonical render policy for the snapshot briefing slot — `nil` until a
    /// snapshot was fetched (surfaces then keep their pre-v1.16 behaviour).
    var snapshotRenderPolicy: DashboardBriefingRenderPolicy? {
        snapshotBriefing?.renderPolicy
    }

    /// The `briefingStale: true` honesty pair — the LAST generated briefing
    /// plus its generation instant. Non-nil ONLY when the surface is actually
    /// rendering stale snapshot prose (no fresh generate-path briefing in
    /// front of it), so the "Stand HH:MM" caption never mislabels fresh text.
    var staleBriefingAsOf: Date? {
        guard response?.dailyBriefing == nil,
              case let .prose(_, asOf, true) = snapshotBriefing?.renderPolicy else { return nil }
        return asOf
    }

    /// `true` when the server says no AI provider is configured anywhere
    /// (`briefingState: "no-provider"`) and no stale text was delivered —
    /// the surface renders the deterministic fallback prose (b155 A3
    /// period-narrative / Statistik-Mode path), NEVER a preparing state.
    var isServerBriefingUnavailable: Bool {
        snapshotRenderPolicy == .deterministicFallback
    }

    /// AI summary — the 2-3 sentence overview.
    var summary: String? {
        let s = response?.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// Paragraph content for the briefing surface — uses the strict
    /// `dailyBriefing.paragraph` when emitted, falls back to the AI
    /// `summary` because production `/api/insights/generate` routes
    /// through `insightResultSchema` today (no dailyBriefing slot).
    var paragraphContent: String? {
        briefing?.paragraph ?? summary
    }

    /// True iff we render the summary-fallback rather than the strict
    /// daily-briefing payload. UI surfaces an honest source-badge.
    var isUsingSummaryFallback: Bool {
        briefing == nil && summary != nil
    }

    var providerLabel: String? {
        response?.providerLabel
    }

    /// Severity-sorted recommendations from the generate-endpoint payload.
    var sortedRecommendations: [Recommendation] {
        guard let response else { return [] }
        return response.recommendations.sorted { lhs, rhs in
            lhs.severity.sortRank > rhs.severity.sortRank
        }
    }
}
