import Foundation
import Observation

/// Drives the sleep page's rhythm cards + multi-night stage composition
/// (parity Build 4 · item 4.7).
///
/// Deliberately a SCREEN-SCOPED store, owned by the sleep metric page via
/// `@State`, rather than another slot on `AppContainer`: both reads serve
/// exactly one surface, and neither feeds a widget, a tile, or the dashboard.
/// Adding them to the container would have widened the app-wide graph for a
/// page-local concern.
///
/// Cache-first then revalidate, mirroring the store shapes around it: a
/// revisit inside one app session repaints instantly from the repository's
/// in-memory cache while the fresh read lands.
///
/// **Honest empties.** `nil` from either read means "the server has nothing to
/// show here" (module gated off, route absent, or no stage-bearing rows at
/// all) and the matching section self-suppresses. A genuine transport failure
/// keeps whatever was already painted and sets ``loadFailed`` — the page never
/// swaps real cards for an error banner it cannot act on.
@MainActor
@Observable
public final class SleepInsightsStore {
    public private(set) var rhythm: SleepRhythmDTO?
    public private(set) var breakdown: SleepStageBreakdownDTO?
    public private(set) var isLoading = false
    /// `true` when the last revalidate threw. Only meaningful while nothing is
    /// painted — with content on screen the stale content wins.
    public private(set) var loadFailed = false

    private var hasLoaded = false

    public init() {}

    /// Loads both payloads, cache-first. Idempotent per app session: the
    /// `.task` that calls this fires on every appearance of the sleep page, so
    /// a second call short-circuits to the already-resolved state unless
    /// `force` is set (pull-to-refresh).
    public func load(repo: SleepInsightsRepository?, force: Bool = false) async {
        guard let repo else { return }
        if hasLoaded, !force { return }
        // Stale half — repaint whatever this session already fetched.
        if let cached = await repo.cachedRhythmPayload() { rhythm = cached }
        if let cached = await repo.cachedStageBreakdown() { breakdown = cached }
        isLoading = rhythm == nil && breakdown == nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        // Revalidate half. The two reads are INDEPENDENT — `/api/sleep/rhythm`
        // failing must not deny the composition chart its section, and vice
        // versa — so each outcome is captured on its own rather than thrown
        // through one shared `try` that would discard the sibling's result.
        async let rhythmOutcome = Self.attempt { try await repo.rhythm() }
        async let breakdownOutcome = Self.attempt { try await repo.stageBreakdown() }
        let (rhythmResult, breakdownResult) = await (rhythmOutcome, breakdownOutcome)

        if rhythmResult.succeeded { rhythm = rhythmResult.value }
        if breakdownResult.succeeded { breakdown = breakdownResult.value }
        // Only a total wipe-out with nothing painted is worth telling the user
        // about; a partial failure just leaves that one section absent.
        let anyFailed = !rhythmResult.succeeded || !breakdownResult.succeeded
        loadFailed = anyFailed && rhythm == nil && breakdown == nil
    }

    /// One read's result, captured rather than propagated.
    ///
    /// Deliberately NOT `Result<T?, any Error>`: `any Error` is not `Sendable`,
    /// and this value crosses an isolation boundary on its way back from the
    /// `async let`. The failure detail is not needed — the caller only decides
    /// between "keep what is painted" and "say nothing loaded" — so the type
    /// carries the flag and drops the error.
    private struct Outcome<Value: Sendable> {
        let value: Value?
        let succeeded: Bool
    }

    /// Runs one read and captures its outcome, so two concurrent reads can
    /// fail independently instead of one `try` discarding the sibling.
    private nonisolated static func attempt<T: Sendable>(
        _ operation: @Sendable () async throws -> T?
    ) async -> Outcome<T> {
        do {
            let value = try await operation()
            return Outcome(value: value, succeeded: true)
        } catch {
            return Outcome(value: nil, succeeded: false)
        }
    }
}
