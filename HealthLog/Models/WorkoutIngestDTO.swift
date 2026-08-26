import Foundation

// MARK: - Workout ingest (POST /api/workouts/batch)

/// Single workout the iOS client POSTs to `POST /api/workouts/batch`
/// (server v1.5, schema `createWorkoutSchema` in
/// `src/lib/validations/workout.ts`). Mapped 1:1 from `HKWorkout` by
/// ``WorkoutHealthKitMapping``.
///
/// **Field shape (verbatim from the Zod contract):** the server expects
/// `sportType` as one of the locked sport-type enum strings, `startedAt`
/// / `endedAt` as ISO-8601 **with offset** (the `.hlBatch` encoder emits
/// this), and a flat set of optional numeric fields. Heart-rate fields
/// are integer beats/min; `source` defaults to `MANUAL` server-side but
/// we always send `APPLE_HEALTH` for HK-sourced workouts (the exact
/// spelling the `MeasurementSource` enum uses — not "HEALTHKIT").
///
/// **Anti-duplicate / idempotency:** `externalId` is the `HKWorkout`
/// `uuid.uuidString`. The server's `@@unique([userId, source,
/// externalId])` composite index means a re-posted batch upserts to
/// `duplicate` rather than inserting a second row, so a doubly-delivered
/// observer wakeup is idempotent. We additionally drop any HKWorkout we
/// wrote ourselves (carrying `HKMetadataKeyExternalUUID`) before mapping
/// — the standard PROJECT_GUIDE.md echo guard.
///
/// **`samples` (GH #86).** The per-session HR curve rides along as the
/// optional `samples` array — `[{ t, hr }]`, the shape
/// `workoutHrSamplesSchema` locks. Until #86 we shipped only the typed
/// HR aggregates, so the web had nothing to draw a session curve from
/// (`workout_samples` stayed empty server-side) while the iOS detail
/// screen read the full series HK-locally. `route` (GPS geometry) stays
/// omitted — it is a separate read path and unrelated to the curve.
///
/// **Empty ≠ absent.** A workout without a usable HR point OMITS the
/// field entirely; it never ships `samples: []`. The server's schema is
/// `.min(1, "samples requires at least 1 point")`, so an empty array is
/// a 422 that fails the WHOLE batch — and semantically `[]` would claim
/// "measured, zero points" where the honest statement is "we have
/// nothing to add" (leaving the door open for another source to attach
/// a series later).
///
/// `Codable` (not just `Encodable`) since the Outbox-Mandate fix
/// (audit v0.14.8 C4.1): a failed batch upload persists these DTOs in
/// `OutboxQueue.Payloads.UploadWorkoutBatch`, and the replay path must
/// decode them back out of the on-disk payload.
public struct WorkoutIngestDTO: Codable, Sendable, Equatable {
    public let sportType: String
    public let startedAt: Date
    public let endedAt: Date
    public let totalEnergyKcal: Double?
    public let totalDistanceM: Double?
    public let avgHeartRate: Int?
    public let maxHeartRate: Int?
    public let minHeartRate: Int?
    public let stepCount: Int?
    public let elevationM: Double?
    public let source: String
    public let externalId: String?
    /// Per-session HR curve. `nil` (omitted on the wire) when the workout
    /// carries no usable HR point — NEVER `[]`, which the server rejects.
    public let samples: [Sample]?

    /// One point of the per-session series (`workoutHrSamplesSchema`).
    /// `t` encodes through the `.hlBatch` `.iso8601` strategy, `hr` is the
    /// integer beats/min the schema demands (`z.number().int().min(20).max(300)`).
    /// The companion channels the schema also accepts (`speedMs` / `power` /
    /// `cadence`) are deliberately not modelled — we read none of them from
    /// HealthKit, and adding them later is additive on both sides.
    public struct Sample: Codable, Sendable, Equatable {
        public let t: Date
        public let hr: Int?

        public init(t: Date, hr: Int?) {
            self.t = t
            self.hr = hr
        }
    }

    public init(
        sportType: String,
        startedAt: Date,
        endedAt: Date,
        totalEnergyKcal: Double? = nil,
        totalDistanceM: Double? = nil,
        avgHeartRate: Int? = nil,
        maxHeartRate: Int? = nil,
        minHeartRate: Int? = nil,
        stepCount: Int? = nil,
        elevationM: Double? = nil,
        source: String = "APPLE_HEALTH",
        externalId: String? = nil,
        samples: [Sample]? = nil
    ) {
        self.sportType = sportType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.totalEnergyKcal = totalEnergyKcal
        self.totalDistanceM = totalDistanceM
        self.avgHeartRate = avgHeartRate
        self.maxHeartRate = maxHeartRate
        self.minHeartRate = minHeartRate
        self.stepCount = stepCount
        self.elevationM = elevationM
        self.source = source
        self.externalId = externalId
        self.samples = samples
    }
}

/// Request envelope for `POST /api/workouts/batch` — `{ workouts: [...] }`.
/// Mirrors the measurements-batch shape so the same retry / cursor
/// plumbing applies. Server caps the array at
/// ``WorkoutIngestDTO/maxWorkoutsPerBatch`` entries.
public struct WorkoutBatchPayload: Encodable, Sendable, Equatable {
    public let workouts: [WorkoutIngestDTO]

    public init(workouts: [WorkoutIngestDTO]) {
        self.workouts = workouts
    }
}

/// Per-entry + aggregate response of `POST /api/workouts/batch`. Mirrors
/// the measurements-batch response so the importer can advance its
/// sync cursor identically. `inserted | duplicate | enriched` are accepted
/// terminal outcomes. `skipped`, unknown statuses, or incomplete index
/// coverage are rejected by ``WorkoutBatchAcceptance`` so a caller never
/// checkpoints work the server did not durably accept.
///
/// **GH #86 — the per-entry array.** The server has always emitted an
/// `entries` array alongside the sums; we used to throw it away. The HR
/// backfill sweep needs it: only the per-entry status distinguishes "the
/// server attached our series" (`enriched`) from "the server ignored it"
/// (`duplicate`), which is how we learn whether the enrichment path is
/// live at all.
public struct WorkoutBatchResponseDTO: Decodable, Sendable, Equatable {
    public let processed: Int
    public let inserted: Int
    public let duplicates: Int
    /// Per-entry outcomes, index-aligned with the posted batch. Empty when
    /// the server omits the array (older builds) or when it fails to decode
    /// — never a hard error, the sums stay usable.
    public let entries: [Entry]

    /// One per-entry outcome. Unknown / future keys are ignored.
    public struct Entry: Decodable, Sendable, Equatable {
        public let index: Int
        public let status: Status
        public let reason: String?

        public init(index: Int, status: Status, reason: String? = nil) {
            self.index = index
            self.status = status
            self.reason = reason
        }
    }

    /// **Deliberately NOT an enum.** `enriched` does not exist on the
    /// server yet (the enrichment path ships after this client), and the
    /// roster is explicitly additive — a strict `enum` would throw
    /// `dataCorrupted` on the first unknown value and take the whole batch
    /// response down with it, which is exactly the failure mode we already
    /// ate twice. An open `RawRepresentable` wrapper decodes any string,
    /// keeps `==` comparisons against the known cases readable, and lets an
    /// unrecognised status flow through as data.
    public struct Status: RawRepresentable, Decodable, Sendable, Equatable, Hashable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        /// A new workout row was created (and its `samples`, if any, stored).
        public static let inserted = Status(rawValue: "inserted")
        /// The row already existed; the entry changed nothing.
        public static let duplicate = Status(rawValue: "duplicate")
        /// The server refused to store the entry (carries a `reason`).
        public static let skipped = Status(rawValue: "skipped")
        /// GH #86 — the entry attached its HR series to an existing workout
        /// that had none. The workout's own fields stayed untouched.
        public static let enriched = Status(rawValue: "enriched")
    }

    public init(processed: Int, inserted: Int, duplicates: Int, entries: [Entry] = []) {
        self.processed = processed
        self.inserted = inserted
        self.duplicates = duplicates
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case processed, inserted, duplicates, entries
    }

    /// Tolerant decode: the sums are required (they always were), the
    /// per-entry array is best-effort. A malformed / absent `entries`
    /// degrades to `[]` instead of failing the response — the sums alone
    /// still let the importer log and move on.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        processed = try c.decode(Int.self, forKey: .processed)
        inserted = try c.decode(Int.self, forKey: .inserted)
        duplicates = try c.decode(Int.self, forKey: .duplicates)
        // `try?` flattens the double optional: an absent key and a malformed
        // array both land in the `else` branch as an empty list.
        if let decoded = try? c.decodeIfPresent([Entry].self, forKey: .entries) {
            entries = decoded
        } else {
            entries = []
        }
    }
}

/// Privacy-safe typed failure for an HTTP-successful workout batch whose
/// per-entry results do not prove complete durable acceptance.
///
/// Only aggregate counts cross the error boundary. Server-provided `reason`
/// strings are deliberately excluded because they are not guaranteed to be
/// free of identifiers or health-adjacent input values.
public struct WorkoutBatchAcceptanceError: Error, Sendable, Equatable, CustomStringConvertible {
    public let postedCount: Int
    public let acceptedCount: Int
    public let rejectedCount: Int
    public let missingCount: Int
    public let duplicateIndexCount: Int
    public let outOfRangeIndexCount: Int

    public var description: String {
        "workout batch not fully accepted "
            + "(posted=\(postedCount), accepted=\(acceptedCount), rejected=\(rejectedCount), "
            + "missing=\(missingCount), duplicateIndices=\(duplicateIndexCount), "
            + "outOfRangeIndices=\(outOfRangeIndexCount))"
    }
}

/// Complete per-entry acceptance gate shared by incremental import and HR
/// history enrichment. Entries are keyed by their posted index rather than
/// trusted by array order.
public enum WorkoutBatchAcceptance {
    public static func validate(
        postedCount: Int,
        response: WorkoutBatchResponseDTO
    ) throws {
        let expectedCount = max(0, postedCount)
        var seen = Set<Int>()
        var acceptedCount = 0
        var rejectedCount = 0
        var duplicateIndexCount = 0
        var outOfRangeIndexCount = 0

        for entry in response.entries {
            guard (0 ..< expectedCount).contains(entry.index) else {
                outOfRangeIndexCount += 1
                continue
            }
            guard seen.insert(entry.index).inserted else {
                duplicateIndexCount += 1
                continue
            }
            switch entry.status {
            case .inserted, .duplicate, .enriched:
                acceptedCount += 1
            default:
                rejectedCount += 1
            }
        }

        let missingCount = expectedCount - seen.count
        guard rejectedCount == 0,
              missingCount == 0,
              duplicateIndexCount == 0,
              outOfRangeIndexCount == 0 else
        {
            throw WorkoutBatchAcceptanceError(
                postedCount: expectedCount,
                acceptedCount: acceptedCount,
                rejectedCount: rejectedCount,
                missingCount: missingCount,
                duplicateIndexCount: duplicateIndexCount,
                outOfRangeIndexCount: outOfRangeIndexCount
            )
        }
    }
}

public extension WorkoutIngestDTO {
    /// Server-side cap (`MAX_WORKOUTS_PER_BATCH` in
    /// `src/lib/validations/workout.ts`). The importer chunks larger
    /// backfills below this so a multi-year HKWorkout history never
    /// trips the 400 `workout.batch.too_large` gate.
    static let maxWorkoutsPerBatch = 100

    /// **GH #86** — batch cap for entries that CARRY a series. The route's
    /// hard limit is a 5 MB request body: a worst-case session
    /// (``maxSamplesPerWorkout`` … in practice the HK fetch stops at 5 000
    /// points) serialises to roughly 200 KB of `{"t":…,"hr":…}` rows, so
    /// 100 of them would blow the ceiling and earn a 413. Ten keeps the
    /// worst case near 2 MB and the typical case (≈600 points/session) at a
    /// few hundred KB.
    static let maxWorkoutsPerSeriesBatch = 10

    /// Server-side cap (`MAX_WORKOUT_HR_SAMPLES`). Unreachable in practice —
    /// ``HealthKitWorkoutDetailService`` stops at 5 000 points — but the
    /// mapper enforces it so a future / injected series source can never
    /// hand the server an over-cap array.
    static let maxSamplesPerWorkout = 30000
}
