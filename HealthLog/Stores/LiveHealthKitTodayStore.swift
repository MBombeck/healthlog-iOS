import Foundation
import Observation

/// v0.6.2.x bug-c10-ios-direct — main-actor store that holds today's
/// HealthKit-direct step total so the dashboard tile + chart-detail today-
/// segment can paint a fresh number even when the server `stats:` row is
/// frozen (the `/api/measurements/batch` route is insert-only on the
/// `(type, externalId)` unique-key pair, so same-day updates after the
/// first sync land as `duplicate` no-ops — see
/// `.planning/v056-marathon/v0628-C10-redux-report.md`).
///
/// **Boundary:** today only. Historical days (yesterday and earlier) still
/// flow through the server snapshot via `dailyStats` cache — that side of
/// the architecture is not broken, and routing it through HK would lose
/// cross-device aggregation.
///
/// **Cache TTL:** 30 seconds so a heavily-scrolling dashboard re-render
/// doesn't hammer `HKStatisticsCollectionQuery` on every layout pass. The
/// query itself is system-cached and cheap, but a short TTL also dampens
/// the actor-hop chatter the chart-detail screen would otherwise generate
/// on every range-picker tap.
///
/// **Fallback:** every accessor returns `Double?`. `nil` means "no HK
/// answer for today" — caller falls back to the existing server-snapshot
/// display path. `0` is reserved for "HK returned but today has 0 steps"
/// (rare but real on a fresh boot, before the first walk of the day).
@MainActor
@Observable
public final class LiveHealthKitTodayStore {
    /// Latest HK-direct step total for today. `nil` until the first
    /// successful read after launch / a permission grant; never reverts
    /// to `nil` on a transient HK error (we keep the last known value
    /// rather than silently blanking the tile).
    public private(set) var todayStepCount: Double?

    /// Wall-clock of the most recent successful HK read. Drives the TTL
    /// gate so back-to-back `refresh()` calls collapse to a single
    /// underlying HK query.
    private var lastRefreshedAt: Date?

    /// Cache window in seconds — see type-level doc.
    private let cacheTTL: TimeInterval

    /// Injectable so the SwiftUI previews + tests can swap in a stub or a
    /// `nil`-returning reader without touching HK. Production wires
    /// `AppContainer.healthKitDailyStatsSync?.liveTodayStepCount` via a
    /// closure capture.
    private let reader: @Sendable () async -> Double?

    /// Monotonic counter that prevents an in-flight refresh from being
    /// overwritten by an older one (e.g. user pull-to-refresh fires, then
    /// scenePhase=.active also fires — we want the newer answer to win).
    private var inFlightTicket: UInt = 0

    public init(
        cacheTTL: TimeInterval = 30,
        reader: @escaping @Sendable () async -> Double? = { nil }
    ) {
        self.cacheTTL = cacheTTL
        self.reader = reader
    }

    /// Force a fresh HK read, bypassing the TTL gate. Called from
    /// scenePhase=.active hooks + pull-to-refresh on the dashboard so the
    /// operator's explicit "give me current numbers" signal always wins.
    public func refresh() async {
        await performRefresh(force: true)
    }

    /// TTL-aware refresh — no-op when the last successful read is still
    /// fresh. Called from view `.task` modifiers so revisiting the
    /// dashboard mid-session doesn't trigger redundant HK queries.
    public func refreshIfStale(now: Date = .now) async {
        if let lastRefreshedAt, now.timeIntervalSince(lastRefreshedAt) < cacheTTL {
            return
        }
        await performRefresh(force: false)
    }

    private func performRefresh(force _: Bool) async {
        inFlightTicket &+= 1
        let ticket = inFlightTicket
        let value = await reader()
        // Outdated answer — a newer refresh started while we were
        // awaiting. Drop on the floor to avoid clobbering the fresher
        // read's result.
        guard ticket == inFlightTicket else { return }
        if let value {
            todayStepCount = value
            lastRefreshedAt = .now
        }
        // value == nil → keep the previously cached number visible
        // instead of blanking the tile on a transient HK glitch.
    }

    /// v0.14.8 W3 (AUDIT-SECURITY-B175 M-1) — blank the cached today-total on
    /// logout so the next user's dashboard never flashes the previous user's
    /// HK step count. Bumping the ticket drops any in-flight refresh that
    /// started pre-logout.
    public func clearOnLogout() {
        inFlightTicket &+= 1
        todayStepCount = nil
        lastRefreshedAt = nil
    }
}
