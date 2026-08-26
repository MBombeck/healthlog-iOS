import Foundation

/// Stable newest-first history boundary. HealthKit only offers a date range,
/// not an offset or UUID cursor, so rows sharing the boundary timestamp are
/// remembered until every tie has been drained.
struct WorkoutHRBackfillCursor: Codable, Sendable, Equatable {
    var startDate: Date
    var excludedIdentifiersAtStart: Set<String>

    init(startDate: Date, excludedIdentifiersAtStart: Set<String> = []) {
        self.startDate = startDate
        self.excludedIdentifiersAtStart = excludedIdentifiersAtStart
    }
}

/// **GH #86 — where the HR-series backfill stands, per user.**
///
/// The sweep walks the HealthKit workout history BACKWARDS (newest first, the
/// order the user cares about) and re-posts each known workout with its HR
/// series attached. That walk has to survive app launches — a backfill that
/// starts over every launch never reaches 2019 — so its whole state is this
/// one value type, persisted by ``WorkoutHRBackfillStore``.
///
/// Pure + `Codable` on purpose: every progression decision
/// (``isDue(now:)``) is testable without UserDefaults, HealthKit or a server.
struct WorkoutHRBackfillState: Codable, Sendable, Equatable {
    /// Exclusive upper bound of the next chunk: the next page covers workouts
    /// that STARTED strictly before this instant. `nil` = never ran, start at
    /// "now" and walk into the past.
    var cursor: WorkoutHRBackfillCursor?

    /// `true` while a successful empty history read is cooling down. HealthKit
    /// cannot distinguish genuine exhaustion from a revoked read grant, so
    /// this is deliberately a retryable candidate rather than terminal truth.
    var isDone = false

    /// Absolute deadline for the next bounded exhaustion probe.
    var nextExhaustionProbeAt: Date?

    /// A bulk direct page arrived while an older history walk was active. Keep
    /// that cursor stable, then begin one newest-first pass when it exhausts.
    var restartFromNewestAfterCurrentWalk = false

    /// `true` once the server answered a series-bearing entry with `enriched`
    /// — proof the enrichment path is live. Latched: once seen, never
    /// re-probed.
    var serverSupportsEnrichment = false

    /// When we last found a server WITHOUT the enrichment path (a batch of
    /// series-bearing entries that came back all-`duplicate`). Starts the
    /// backoff — we rest rather than hammering a server that cannot use what
    /// we send.
    var lastUnsupportedProbeAt: Date?

    /// Running count of entries the server reported as `enriched`. Operator
    /// telemetry only (log line), never a control input.
    var enrichedCount = 0

    /// How long the sweep rests after finding no enrichment support. One day:
    /// long enough that a missing server path costs one wasted request per
    /// day, short enough that the backfill starts itself within a day of the
    /// server release — no app update, no user action.
    static let unsupportedBackoff: TimeInterval = 24 * 60 * 60
    static let exhaustionProbeBackoff: TimeInterval = 24 * 60 * 60

    init(
        cursor: WorkoutHRBackfillCursor? = nil,
        isDone: Bool = false,
        nextExhaustionProbeAt: Date? = nil,
        restartFromNewestAfterCurrentWalk: Bool = false,
        serverSupportsEnrichment: Bool = false,
        lastUnsupportedProbeAt: Date? = nil,
        enrichedCount: Int = 0
    ) {
        self.cursor = cursor
        self.isDone = isDone
        self.nextExhaustionProbeAt = nextExhaustionProbeAt
        self.restartFromNewestAfterCurrentWalk = restartFromNewestAfterCurrentWalk
        self.serverSupportsEnrichment = serverSupportsEnrichment
        self.lastUnsupportedProbeAt = lastUnsupportedProbeAt
        self.enrichedCount = enrichedCount
    }

    /// Tolerant decode — every field falls back to its default. A blob written
    /// by an older build (or one field added later) must not strand the sweep
    /// on an undecodable state.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cursorIsNil = try !c.contains(.cursor) || (c.decodeNil(forKey: .cursor))
        let migratedUnsafeCursor: Bool
        if cursorIsNil {
            cursor = nil
            migratedUnsafeCursor = false
        } else if let composite = try? c.decode(WorkoutHRBackfillCursor.self, forKey: .cursor) {
            cursor = composite
            migratedUnsafeCursor = false
        } else {
            // A legacy Date-only cursor cannot describe which UUIDs at that
            // exact timestamp were already drained. Restarting is idempotent;
            // converting it to an empty composite cursor could silently skip
            // every tied workout. Corrupt cursor shapes take the same safe path.
            cursor = nil
            migratedUnsafeCursor = true
        }
        let decodedIsDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        let decodedProbe = try c.decodeIfPresent(Date.self, forKey: .nextExhaustionProbeAt)
        let legacyTerminal = decodedIsDone && decodedProbe == nil
        if migratedUnsafeCursor || legacyTerminal {
            // Old terminal blobs may already hide workouts accepted after the
            // walk completed. Restarting newest-first is idempotent and safe.
            cursor = nil
            isDone = false
            nextExhaustionProbeAt = nil
        } else {
            isDone = decodedIsDone
            nextExhaustionProbeAt = decodedProbe
        }
        restartFromNewestAfterCurrentWalk = try c
            .decodeIfPresent(Bool.self, forKey: .restartFromNewestAfterCurrentWalk) ?? false
        if migratedUnsafeCursor || legacyTerminal {
            restartFromNewestAfterCurrentWalk = false
        }
        serverSupportsEnrichment = try c
            .decodeIfPresent(Bool.self, forKey: .serverSupportsEnrichment) ?? false
        lastUnsupportedProbeAt = try c.decodeIfPresent(Date.self, forKey: .lastUnsupportedProbeAt)
        enrichedCount = try c.decodeIfPresent(Int.self, forKey: .enrichedCount) ?? 0
    }

    /// Should the sweep run at all right now?
    ///
    /// - exhaustion candidate → only at/after its bounded probe deadline.
    /// - server support proven → yes, keep walking.
    /// - support never probed → yes, one chunk decides it.
    /// - support probed and missing → only after ``unsupportedBackoff``.
    func isDue(now: Date) -> Bool {
        if isDone {
            guard let nextExhaustionProbeAt, now >= nextExhaustionProbeAt else { return false }
        }
        guard !serverSupportsEnrichment else { return true }
        guard let lastUnsupportedProbeAt else { return true }
        return now.timeIntervalSince(lastUnsupportedProbeAt) >= Self.unsupportedBackoff
    }

    /// Advances to the oldest start in a page while retaining every identifier
    /// already drained at that exact timestamp. A subsequent HealthKit query
    /// widens its finite fetch by this tie count and filters these rows, so a
    /// boundary containing more than one server page cannot be skipped.
    static func nextCursor(
        after cursor: WorkoutHRBackfillCursor,
        oldestStart: Date?,
        oldestStartIdentifiers: Set<String>
    ) -> WorkoutHRBackfillCursor {
        guard let oldestStart else { return cursor }
        if oldestStart == cursor.startDate {
            return WorkoutHRBackfillCursor(
                startDate: cursor.startDate,
                excludedIdentifiersAtStart: cursor.excludedIdentifiersAtStart.union(oldestStartIdentifiers)
            )
        }
        return WorkoutHRBackfillCursor(
            startDate: min(oldestStart, cursor.startDate),
            excludedIdentifiersAtStart: oldestStartIdentifiers
        )
    }
}
