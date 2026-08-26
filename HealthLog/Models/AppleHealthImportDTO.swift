import Foundation

// DTOs for the one-shot Apple-Health `export.zip` import.
//
// Server contract (verbatim, READ 2026-06-02):
// - `POST /api/import/apple-health-export`
//   (`src/app/api/import/apple-health-export/route.ts`) — multipart upload,
//   field name `file`, streamed to disk. Responds `202` with the envelope
//   payload ``AppleHealthImportKickoffDTO`` (`{ jobId, status, idempotent? }`).
// - `GET /api/import/apple-health-export/[jobId]/status`
//   (`.../[jobId]/status/route.ts`) — returns ``AppleHealthImportStatusDTO``
//   verbatim (`{ jobId, status, startedAt, completedAt, uploadBytes,
//   exportedAt, progress, result, failureReason }`).
//
// Phase + progress + result shapes mirror
// `src/lib/measurements/import-apple-health-export.ts`
// (`ImportJobPhase` / `ImportJobProgress` / `ImportJobResult`).

// MARK: - Kickoff (POST response)

/// `202` payload returned by the kickoff endpoint. `idempotent` is `true` when a
/// re-upload of identical bytes (server-side SHA-256 dedup) short-circuited to a
/// pre-existing job row.
public struct AppleHealthImportKickoffDTO: Codable, Sendable, Equatable {
    public let jobId: String
    public let status: String
    public let idempotent: Bool?

    public init(jobId: String, status: String, idempotent: Bool? = nil) {
        self.jobId = jobId
        self.status = status
        self.idempotent = idempotent
    }
}

// MARK: - Phase

/// Lifecycle phase of an import job. Mirrors server `ImportJobPhase`. Decoded
/// leniently (``other``) so a future server phase never breaks polling.
public enum AppleHealthImportPhase: String, Codable, Sendable, Equatable {
    case queued
    case unpacking
    case parsing
    case upserting
    case done
    case failed
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AppleHealthImportPhase(rawValue: raw) ?? .other
    }

    /// Terminal phases — polling stops here.
    public var isTerminal: Bool {
        self == .done || self == .failed
    }
}

// MARK: - Progress (live snapshot)

/// Live progress snapshot the worker writes every tick. Mirrors server
/// `ImportJobProgress`. All fields optional — the server's `progress` is an open
/// `Record<string, unknown>` and is `{}` before the first tick.
public struct AppleHealthImportProgressDTO: Codable, Sendable, Equatable {
    public let currentPhase: String?
    public let recordsRead: Int?
    public let rowsUpserted: Int?
    /// Best-effort; stays `null` until the parser reaches `</HealthData>`.
    public let percent: Int?
    public let elapsedMs: Int?

    public init(
        currentPhase: String? = nil,
        recordsRead: Int? = nil,
        rowsUpserted: Int? = nil,
        percent: Int? = nil,
        elapsedMs: Int? = nil
    ) {
        self.currentPhase = currentPhase
        self.recordsRead = recordsRead
        self.rowsUpserted = rowsUpserted
        self.percent = percent
        self.elapsedMs = elapsedMs
    }
}

// MARK: - Result (terminal outcome)

/// Per-type counters in the terminal result. Mirrors the inner record of server
/// `ImportJobResult.perType`.
public struct AppleHealthImportTypeStatsDTO: Codable, Sendable, Equatable {
    public let read: Int?
    public let inserted: Int?
    public let updated: Int?
    public let durationMs: Int?

    public init(read: Int? = nil, inserted: Int? = nil, updated: Int? = nil, durationMs: Int? = nil) {
        self.read = read
        self.inserted = inserted
        self.updated = updated
        self.durationMs = durationMs
    }
}

/// Aggregate totals carried on a terminal `done` result.
public struct AppleHealthImportTotalsDTO: Codable, Sendable, Equatable {
    public let recordsRead: Int?
    public let rowsUpserted: Int?
    public let durationMs: Int?

    public init(recordsRead: Int? = nil, rowsUpserted: Int? = nil, durationMs: Int? = nil) {
        self.recordsRead = recordsRead
        self.rowsUpserted = rowsUpserted
        self.durationMs = durationMs
    }
}

/// ECG counters on a terminal result — server v1.34.1, `ImportJobResult.ecg`.
///
/// The `export.zip` archive carries the Apple-Watch ECG strips as their own CSV
/// files next to the XML; the server parses them into `EcgRecording` rows and
/// reports what it did with them here. This is currently the **only** path by
/// which an ECG reaches HealthLog — there is no JSON ingest route and no
/// HealthKit live-sync (GH #74, blocked on the identity question: the archive
/// importer derives `externalRecordingId` as a content hash over the full sample
/// array, a live sync would naturally send `HKSample.uuid`, and the same
/// physical recording would land twice).
///
/// All five counters are non-negative integers server-side; they are typed
/// optional here for the same reason as every other field in this file — a
/// pre-v1.34.1 server simply omits the block, and a missing counter must not
/// fail the whole poll decode.
public struct AppleHealthImportEcgStatsDTO: Codable, Sendable, Equatable {
    /// ECG files found in the archive.
    public let discovered: Int?
    /// Newly created recordings.
    public let imported: Int?
    /// Recordings that already existed and were refreshed.
    public let updated: Int?
    /// Recordings deliberately not taken (e.g. unchanged duplicates).
    public let skipped: Int?
    /// Recordings the parser could not take.
    public let failed: Int?

    public init(
        discovered: Int? = nil,
        imported: Int? = nil,
        updated: Int? = nil,
        skipped: Int? = nil,
        failed: Int? = nil
    ) {
        self.discovered = discovered
        self.imported = imported
        self.updated = updated
        self.skipped = skipped
        self.failed = failed
    }
}

/// Terminal result envelope. Mirrors server `ImportJobResult`. Only the fields
/// the iOS summary surfaces are typed; the rest stay implicitly tolerated.
public struct AppleHealthImportResultDTO: Codable, Sendable, Equatable {
    public let perType: [String: AppleHealthImportTypeStatsDTO]?
    public let totals: AppleHealthImportTotalsDTO?
    /// Server v1.34.1 — ECG-specific counters, `nil` on older servers.
    public let ecg: AppleHealthImportEcgStatsDTO?

    public init(
        perType: [String: AppleHealthImportTypeStatsDTO]? = nil,
        totals: AppleHealthImportTotalsDTO? = nil,
        ecg: AppleHealthImportEcgStatsDTO? = nil
    ) {
        self.perType = perType
        self.totals = totals
        self.ecg = ecg
    }
}

// MARK: - Status (GET response)

/// Canonical status envelope returned by the poll endpoint, mirrored verbatim
/// from `ImportJobStatusResponse`.
public struct AppleHealthImportStatusDTO: Codable, Sendable, Equatable {
    public let jobId: String
    public let status: AppleHealthImportPhase
    public let startedAt: String
    public let completedAt: String?
    public let uploadBytes: Int
    public let exportedAt: String?
    public let progress: AppleHealthImportProgressDTO?
    public let result: AppleHealthImportResultDTO?
    public let failureReason: String?

    public init(
        jobId: String,
        status: AppleHealthImportPhase,
        startedAt: String,
        completedAt: String? = nil,
        uploadBytes: Int,
        exportedAt: String? = nil,
        progress: AppleHealthImportProgressDTO? = nil,
        result: AppleHealthImportResultDTO? = nil,
        failureReason: String? = nil
    ) {
        self.jobId = jobId
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.uploadBytes = uploadBytes
        self.exportedAt = exportedAt
        self.progress = progress
        self.result = result
        self.failureReason = failureReason
    }
}
