import Foundation

/// Reads the two derived payloads behind the sleep page's rhythm cards and its
/// multi-night stage chart (parity Build 4 · item 4.7).
///
///   - `GET /api/sleep/rhythm` → ``SleepRhythmDTO`` — sleep debt, chronotype
///     and average-per-night in ONE read (the web page fetches the same single
///     cache entry for all three of its cards, so this repository does too).
///   - `GET /api/analytics` → the `sleepStages` block → ``SleepStageBreakdownDTO``
///     — the trailing-30-night per-stage series the composition chart slices.
///
/// A thin, read-only `actor` over the shared `APIClient`, mirroring
/// ``SleepNightRepository``: no outbox `Kind` (reads are never queued), an
/// in-memory per-session cache for the stale half of stale-while-revalidate.
///
/// **Both reads are module-gated server-side** (`requireModuleEnabled(…,
/// "sleep")` → `403`). A gated-off or absent surface returns `nil`, not an
/// error: the sleep page then simply omits these sections instead of showing a
/// failure card for a feature the account has deliberately switched off.
public actor SleepInsightsRepository {
    private let api: APIClientProtocol

    private var cachedRhythm: SleepRhythmDTO?
    private var cachedBreakdown: SleepStageBreakdownDTO?
    /// Sticky "the server told us this surface is off" flags. Once a gate or a
    /// missing route answered, the screen stops re-asking on every revisit.
    private var rhythmUnavailable = false
    private var breakdownUnavailable = false

    public init(api: APIClientProtocol) {
        self.api = api
    }

    // MARK: - Rhythm (debt / chronotype / average)

    /// The cached rhythm payload, if a load already landed this session.
    public func cachedRhythmPayload() -> SleepRhythmDTO? {
        cachedRhythm
    }

    /// Fetches `GET /api/sleep/rhythm`.
    ///
    /// - Returns: the payload, or `nil` when the sleep module is disabled
    ///   (`403`) or the route is absent on an older server (`404`) — both are
    ///   "nothing to render", not failures.
    public func rhythm() async throws -> SleepRhythmDTO? {
        if rhythmUnavailable { return nil }
        let req: APIRequest<SleepRhythmDTO> = .get("/api/sleep/rhythm")
        do {
            let payload = try await api.send(req)
            cachedRhythm = payload
            return payload
        } catch let HLError.server(status, _, _) where status == 403 || status == 404 {
            rhythmUnavailable = true
            return nil
        }
    }

    // MARK: - Multi-night stage composition

    /// The cached stage breakdown, if a load already landed this session.
    public func cachedStageBreakdown() -> SleepStageBreakdownDTO? {
        cachedBreakdown
    }

    /// Fetches the `sleepStages` block off `GET /api/analytics`.
    ///
    /// - Returns: the breakdown, or `nil` when the account has no stage-bearing
    ///   sleep rows at all (the server omits the block — `computeSleepStageBreakdown`
    ///   returns `null` for an empty window), or the read is gated / absent.
    public func stageBreakdown() async throws -> SleepStageBreakdownDTO? {
        if breakdownUnavailable { return nil }
        let req: APIRequest<AnalyticsSleepStagesEnvelope> = .get("/api/analytics")
        do {
            let envelope = try await api.send(req)
            cachedBreakdown = envelope.sleepStages
            return envelope.sleepStages
        } catch let HLError.server(status, _, _) where status == 403 || status == 404 {
            breakdownUnavailable = true
            return nil
        }
    }
}
