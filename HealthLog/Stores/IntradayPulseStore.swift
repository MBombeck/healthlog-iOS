import Foundation
import Observation

/// `@Observable` wrapper over ``IntradayPulseRepository`` — drives the pulse
/// page's day-curve block (web `/insights/pulse` → `IntradayPulseChart`).
///
/// **Server-authoritative + honest.** The store surfaces ONLY the day the
/// server returned. It never fills a missing bucket, never derives a baseline,
/// and never keeps a previous day's shape on screen under a new day's label —
/// a `nil` payload leaves ``day`` `nil` and the block hides.
///
/// **Day navigator.** ``selectedDateKey`` is `nil` while the operator is on
/// TODAY, so a session left open across midnight follows the current day live
/// (web `intraday-pulse-chart.tsx:90-105`). Stepping back pins an explicit key;
/// stepping forward is capped at today in ``IntradayPulseMath/nextDayKey(after:todayKey:in:)``.
/// All day arithmetic runs in the PROFILE timezone the caller passes in.
///
/// **Server-derived (paired only).** Pure server compute, no on-device
/// fallback — the call site additionally gates on a cloud surface being
/// available so the block never appears in standalone / no-server.
@MainActor
@Observable
public final class IntradayPulseStore {
    /// The decoded day currently on screen, or `nil` when the server returned
    /// nothing renderable (module gated off, route absent, or an empty day).
    public private(set) var day: IntradayPulseDTO?
    /// The pinned day key, or `nil` while tracking TODAY live.
    public private(set) var selectedDateKey: String?
    public private(set) var isLoading: Bool = false
    /// `true` once a load settled at least once this session — lets the block
    /// tell "still loading" from "settled and empty".
    public private(set) var hasSettledOnce: Bool = false
    /// `true` when the last read threw a genuine transport error (not a gate).
    /// Drives the calm retry line; a gated-off surface never sets it.
    public private(set) var loadFailed: Bool = false

    private let repo: IntradayPulseRepository

    public init(repo: IntradayPulseRepository) {
        self.repo = repo
    }

    /// `true` when the block has something worth painting. An empty FIRST load
    /// keeps the whole block hidden (never a dead card body); once a day with
    /// content has been seen the navigator stays put so an empty day the
    /// operator paged INTO can still be paged out of.
    public var hasContent: Bool {
        day?.hasContent ?? false
    }

    /// `true` once the operator has navigated away from today — the block then
    /// keeps its shell (and its navigator) even on an empty day.
    public var isPinnedToPastDay: Bool {
        selectedDateKey != nil
    }

    /// `true` while the visible day IS today (the "next" chevron is disabled).
    public func isOnToday(in zone: TimeZone) -> Bool {
        selectedDateKey == nil || selectedDateKey == IntradayPulseMath.dayKey(in: zone)
    }

    /// The day key currently on screen, resolved against the profile zone.
    public func visibleDateKey(in zone: TimeZone) -> String {
        selectedDateKey ?? IntradayPulseMath.dayKey(in: zone)
    }

    /// Loads the visible day. Idempotent per appearance: a repeat call with a
    /// day already painted short-circuits unless `force` is set.
    public func load(in zone: TimeZone, force: Bool = false) async {
        if hasSettledOnce, !force { return }
        await fetch(in: zone)
    }

    /// Re-reads the visible day (pull-to-refresh / retry).
    public func refresh(in zone: TimeZone) async {
        await fetch(in: zone)
    }

    /// Steps one day back.
    public func goToPreviousDay(in zone: TimeZone) async {
        let current = visibleDateKey(in: zone)
        guard let previous = IntradayPulseMath.shift(dayKey: current, by: -1, in: zone) else { return }
        selectedDateKey = previous
        await fetch(in: zone)
    }

    /// Steps one day forward, capped at today. Landing exactly on today drops
    /// back to the live `nil` key so the block resumes following the day.
    public func goToNextDay(in zone: TimeZone) async {
        let current = visibleDateKey(in: zone)
        let todayKey = IntradayPulseMath.dayKey(in: zone)
        guard let next = IntradayPulseMath.nextDayKey(after: current, todayKey: todayKey, in: zone) else { return }
        selectedDateKey = next == todayKey ? nil : next
        await fetch(in: zone)
    }

    public func clearOnLogout() {
        day = nil
        selectedDateKey = nil
        hasSettledOnce = false
        loadFailed = false
    }

    // MARK: - Private

    private func fetch(in zone: TimeZone) async {
        let todayKey = IntradayPulseMath.dayKey(in: zone)
        isLoading = true
        defer {
            isLoading = false
            hasSettledOnce = true
        }
        do {
            day = try await repo.fetch(dateKey: selectedDateKey, todayKey: todayKey)
            loadFailed = false
        } catch {
            // A transport failure must not leave the previous day's curve on
            // screen under the new day's label — that would be a fabricated
            // shape. Drop the payload and offer a calm retry instead.
            day = nil
            loadFailed = true
        }
    }
}
