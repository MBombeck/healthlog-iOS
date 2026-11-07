import Foundation

// MIRROR (1.5, public #28, #152) — the server→Apple-Health mirror in the
// background.
//
// Up to 1.4 the mirror ran only when `MeasurementsStore` loaded a fresh page,
// which in practice meant with the app open: a weight a scale sent through the
// import API reached Apple Health the next time someone opened HealthLog. This
// pass is the `.serverMirror` capability of the background health sync. It runs
// only on an App Refresh or a Processing wake, only against a server that
// resolves `appleHealthMirror` itself (1.46.0 and later), and it is bounded:
//
//   * exactly one request: the rows the server marks for Apple Health from the
//     last seven days, at most 200 (`ServerMirrorSource`);
//   * at most 50 readings written per wake, newest first; the rest waits for the
//     next window, where the duplicate probes skip what this one wrote;
//   * the window is asked before every reading and once more before the save.
//     A pass that runs out of time saves nothing, so a wake never leaves half a
//     batch behind.
//
// Every row still goes through the same planner as the foreground page: the
// server's per-row answer (the source rule only where the key is missing), the
// kind's write type, the person's direction per kind, the limited-history
// boundary of iOS 27, the deletion tombstones and both duplicate probes. Nothing
// here deletes anything from Apple Health.
//
// No reader for `/api/sync/changes`: without a cursor that feed starts at the
// oldest row of six domains, so for an account with years of Apple Health data
// it would be the whole history. The source is a small seam so a later feed
// reader swaps only the source (the server request is drafted in the MIRROR
// report).

/// What one bounded mirror write did. Counts only.
struct ServerMirrorWriteOutcome: Sendable, Equatable {
    /// `false` when the person's direction was not known and nothing was written
    /// for that reason (B5 (1.4)).
    var decided = true
    /// Readings saved into Apple Health (a blood pressure counts once).
    var written = 0
    /// Candidates left for the next window: not looked at (row limit or window
    /// end) or planned but not saved because the window closed.
    var unexamined = 0
    /// `true` when the window closed during the pass.
    var stopped = false
    /// `true` when HealthKit refused the save.
    var saveFailed = false
}

/// The bounded half of the mirror, implemented by `HealthKitService`.
protocol BoundedServerMirrorWriting: Sendable {
    /// Writes at most `rowLimit` readings of `measurements` and asks `isExpired`
    /// before every reading and before the save.
    func mirrorServerMeasurements(
        _ measurements: [Measurement],
        rowLimit: Int,
        isExpired: @escaping @Sendable () -> Bool
    ) async -> ServerMirrorWriteOutcome
}

/// Where the background mirror gets its rows. Today one list request
/// (`MeasurementsRepository`); a later feed reader replaces only this.
protocol ServerMirrorSource: Sendable {
    /// Rows the server marks for Apple Health, measured at or after `since`,
    /// newest first, at most `limit`.
    func rowsForServerMirror(since: Date, limit: Int) async throws -> [Measurement]
}

/// Today's source: one list request (`rowsForServerMirror(since:limit:)` in
/// `MeasurementsRepository+HistoricalBackfill.swift`).
extension MeasurementsRepository: ServerMirrorSource {}

enum ServerMirrorBackgroundPass {
    /// The first server that resolves `appleHealthMirror` per row and filters the
    /// list by it. An older server ignores the filter and returns every source.
    static let minimumServerVersion = Measurement.appleHealthMirrorMinimumServerVersion
    /// How far back one wake looks.
    static let lookback: TimeInterval = 7 * 24 * 60 * 60
    /// Rows in the one request.
    static let fetchLimit = 200
    /// Readings written per wake.
    static let rowLimit = 50
    /// The wakes that run the pass. Every other trigger has the app in front,
    /// where the measurement list mirrors its fresh page itself.
    static let triggers: Set<HealthSyncTrigger> = [.appRefresh, .processing]

    /// Everything the pass reads, injected so a test can play every branch.
    struct Environment: Sendable {
        var source: (any ServerMirrorSource)?
        var writer: (any BoundedServerMirrorWriting)?
        /// `KnownServerVersion.isAtLeast(minimumServerVersion)`; unknown is no.
        var serverIsNewEnough: @Sendable () -> Bool
        var isStandalone: @Sendable () -> Bool
        /// The signed-in account, captured once; `nil` when nobody is admitted.
        var lease: @Sendable () -> AuthenticatedSessionLease?
        var now: @Sendable () -> Date = { Date() }
    }

    static func run(_ context: HealthSyncRunContext, environment: Environment) async -> HealthSyncCapabilityResult {
        guard triggers.contains(context.trigger) else { return .disabled(.serverMirror) }
        guard let source = environment.source, let writer = environment.writer else {
            return .unsupported(.serverMirror)
        }
        guard !environment.isStandalone(), environment.serverIsNewEnough() else { return .disabled(.serverMirror) }
        guard let lease = environment.lease() else { return .refused(.serverMirror, .notAdmitted) }
        if Task.isCancelled { return .cancelled(.serverMirror) }
        if context.isExpired() { return .expired(.serverMirror) }

        let rows: [Measurement]
        do {
            rows = try await source.rowsForServerMirror(since: environment.now() - lookback, limit: fetchLimit)
        } catch is CancellationError {
            return .cancelled(.serverMirror)
        } catch {
            return .refused(.serverMirror, .transport)
        }
        guard lease.isCurrent else { return .refused(.serverMirror, .staleSession) }

        let outcome = await writer.mirrorServerMeasurements(
            rows,
            rowLimit: rowLimit,
            isExpired: { Task.isCancelled || context.isExpired() || !lease.isCurrent }
        )
        return result(for: outcome)
    }

    /// The named answer for one outcome.
    static func result(for outcome: ServerMirrorWriteOutcome) -> HealthSyncCapabilityResult {
        if outcome.saveFailed {
            return HealthSyncCapabilityResult(
                capability: .serverMirror,
                disposition: .failed,
                itemsHeld: outcome.unexamined,
                failure: .persistence
            )
        }
        if outcome.stopped {
            return HealthSyncCapabilityResult(
                capability: .serverMirror,
                disposition: .expired,
                itemsSubmitted: outcome.written,
                itemsSettled: outcome.written,
                itemsHeld: outcome.unexamined,
                failure: .expired
            )
        }
        guard outcome.decided, outcome.unexamined == 0 else {
            // The person's direction was not known, or the row limit left rows
            // for the next window: owed, not failed.
            return HealthSyncCapabilityResult(
                capability: .serverMirror,
                disposition: .deferred,
                itemsSubmitted: outcome.written,
                itemsSettled: outcome.written,
                itemsHeld: outcome.unexamined
            )
        }
        return .succeeded(.serverMirror, submitted: outcome.written, settled: outcome.written)
    }
}
