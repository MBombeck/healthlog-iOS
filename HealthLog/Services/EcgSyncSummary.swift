import Foundation

// Phase 07 / plan 07-06 — the ECG sweep's result vocabulary.
//
// Split out of `EcgSyncCoordinator.swift` under the `PROJECT_GUIDE.md` file
// budget once the coordinator gained its captured-owner teardown. These three
// types are the *answer* an ECG pass gives; the coordinator is how it is
// reached. Neither definition changed in the move.

/// Why one recording was not uploaded. Every reason retains the HealthKit
/// anchor: only a released server success (`inserted` / `updated` /
/// `duplicate`) is allowed to consume a recording from the anchored stream.
public enum EcgSyncSkipReason: String, Sendable, Equatable, CaseIterable {
    /// More voltage readings than the route accepts (32 768).
    ///
    /// **The recording is skipped, never truncated.** Cutting a strip to fit
    /// would make the uploaded trace a different measurement than the one the
    /// device recorded, and the server would then derive `durationSeconds` from
    /// the truncated length and state it as fact. A missing recording is an
    /// absence; a shortened one is a falsehood in the record. So: skip, count,
    /// and let the archive-import path (which has no such ceiling) remain the
    /// way in for it.
    ///
    /// Recognised from METADATA, before the waveform is ever read — the sample
    /// count is known up front, so an over-long strip costs no memory at all.
    case tooManySamples
    /// A voltage reading could not be expressed as an integer microvolt value
    /// (non-finite, or out of range). Partial traces are not sent.
    case unreadableSample
    /// HealthKit refused to hand over the trace.
    case waveformUnavailable
    /// The server understood the body and refused it (a 4xx that is not a gate
    /// and not a rate limit — most pointedly the 422 for an unknown field).
    /// The cursor remains fail-closed so a fixed candidate can retry it.
    case rejectedByServer
}

/// Why a sweep ended before it ran out of recordings. The anchor is **held** in
/// every one of these cases, so nothing is lost — the next wake resumes from
/// the same place.
public enum EcgSyncStopReason: String, Sendable, Equatable, CaseIterable {
    /// `403` — the `insights` module or the `insightStatus` surface is off.
    /// Stop; do not retry. The operator turned something off, and hammering the
    /// route would neither change that nor inform anyone.
    case gated
    /// `401` — the session is not (or no longer) authenticated. Stop; the
    /// refresh/re-login path owns the recovery, and the anchor waits.
    case unauthorized
    /// `429` — too many recordings per minute for this account. Stop and wait;
    /// `APIClient` already honoured `Retry-After` within the request, so
    /// reaching here means the budget is genuinely spent.
    case rateLimited
    /// Network failure, offline, 5xx, timeout. Stop; retry on the next wake.
    case transport
    /// The new HealthKit anchor could not be durably read back after writing.
    /// The old position remains authoritative and the next wake retries.
    case persistence
}

/// Tally of one sweep. `inserted` / `updated` / `duplicate` mirror the server's
/// own outcome vocabulary — **all three are successes**, and `duplicate` in
/// particular is the idempotent no-op that makes a re-sync after an archive
/// import harmless.
public struct EcgSyncSummary: Sendable, Equatable {
    public var inserted: Int = 0
    public var updated: Int = 0
    public var duplicate: Int = 0
    public var skipped: [EcgSyncSkipReason: Int] = [:]
    public var stoppedBecause: EcgSyncStopReason?

    public init(
        inserted: Int = 0,
        updated: Int = 0,
        duplicate: Int = 0,
        skipped: [EcgSyncSkipReason: Int] = [:],
        stoppedBecause: EcgSyncStopReason? = nil
    ) {
        self.inserted = inserted
        self.updated = updated
        self.duplicate = duplicate
        self.skipped = skipped
        self.stoppedBecause = stoppedBecause
    }

    public static let zero = EcgSyncSummary()

    /// Recordings the server accepted, in any of its three success shapes.
    public var accepted: Int {
        inserted + updated + duplicate
    }

    /// Recordings not accepted during this pass. Any non-zero value retains
    /// the shared HealthKit anchor for a later fixed/recovered candidate.
    public var skippedCount: Int {
        skipped.values.reduce(0, +)
    }

    mutating func record(_ status: EcgIngestStatus) {
        switch status {
        case .inserted: inserted += 1
        case .updated: updated += 1
        case .duplicate: duplicate += 1
        }
    }

    mutating func skip(_ reason: EcgSyncSkipReason) {
        skipped[reason, default: 0] += 1
    }
}
