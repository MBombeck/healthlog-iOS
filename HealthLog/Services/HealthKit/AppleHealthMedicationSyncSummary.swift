import Foundation

// Phase 07 Wave 3 — split out of `AppleHealthMedicationImporter.swift`.
//
// The importer file crossed the 600-line gate when the date watermark was
// replaced by per-dose progression. The sweep tally and the one user-facing
// obstruction it can produce were always a separate concern from the sweep
// itself: they are what `MedicationHealthSyncStore` renders, not what the
// importer does.

/// **CU-10 — the one thing about a sweep the user has to be told.**
///
/// Everything else the importer tallies is operator-grade detail for the log. A
/// mirror that structurally cannot complete is not: the user turned a switch on
/// and it is not doing what the switch promises, so the reason gets its own copy
/// on the settings surface rather than a generic "something went wrong".
public enum AppleHealthMirrorIssue: Sendable, Equatable, CaseIterable {
    /// Server v1.32.25 — 30 medications are already mirrored from Apple Health,
    /// so a *new* mirror row is refused. Existing mirrors keep syncing.
    case limitReached
    /// Server v1.32.37 (or the CU-10 client pre-flight) — an `externalId` this
    /// client produced is not a stable identity. Defensive: after CU-10 the
    /// reader only mints SHA-256 hex, so seeing this means the archiving seam
    /// broke and the phantom-row defect is live again.
    case unstableExternalId
}

/// Tally of one Apple-Health medication sweep.
public struct AppleHealthMedicationSyncSummary: Sendable, Equatable {
    public var medicationsMirrored: Int
    public var medicationsFailed: Int
    public var dosesInserted: Int
    public var dosesUpdated: Int
    public var dosesDuplicate: Int
    public var dosesSkipped: Int
    /// Doses withheld because their med isn't mirrored yet (source-exclusive).
    public var dosesHeldBackNotMirrored: Int
    /// Doses whose HK log status is neither taken nor skipped (not imported).
    public var dosesIgnored: Int
    /// Whole-chunk POST failures (network / 5xx).
    public var failedBatches: Int
    /// Times the server rejected a chunk with `apple_health_not_mirrored`.
    public var notMirroredRejections: Int
    /// **CU-10** — concepts already mirrored (server-true, else registry) that
    /// were therefore NOT re-posted. On a steady-state sweep this is the whole
    /// medication list and `medicationsMirrored` is 0.
    public var medicationsSkippedKnown: Int
    /// **CU-10 / v1.32.25** — mirror creates refused by the growth cap.
    public var mirrorLimitRejections: Int
    /// **CU-10 / v1.32.37** — mirror creates refused for an unstable `externalId`
    /// (server 422 or the client pre-flight).
    public var unstableExternalIDRejections: Int
    /// **CU-10 / v1.32.37** — dose entries the bulk route skipped with
    /// `reason: "unstable_external_id"`. The rest of the batch landed.
    public var dosesSkippedUnstableExternalID: Int

    public init(
        medicationsMirrored: Int = 0,
        medicationsFailed: Int = 0,
        dosesInserted: Int = 0,
        dosesUpdated: Int = 0,
        dosesDuplicate: Int = 0,
        dosesSkipped: Int = 0,
        dosesHeldBackNotMirrored: Int = 0,
        dosesIgnored: Int = 0,
        failedBatches: Int = 0,
        notMirroredRejections: Int = 0,
        medicationsSkippedKnown: Int = 0,
        mirrorLimitRejections: Int = 0,
        unstableExternalIDRejections: Int = 0,
        dosesSkippedUnstableExternalID: Int = 0
    ) {
        self.medicationsMirrored = medicationsMirrored
        self.medicationsFailed = medicationsFailed
        self.dosesInserted = dosesInserted
        self.dosesUpdated = dosesUpdated
        self.dosesDuplicate = dosesDuplicate
        self.dosesSkipped = dosesSkipped
        self.dosesHeldBackNotMirrored = dosesHeldBackNotMirrored
        self.dosesIgnored = dosesIgnored
        self.failedBatches = failedBatches
        self.notMirroredRejections = notMirroredRejections
        self.medicationsSkippedKnown = medicationsSkippedKnown
        self.mirrorLimitRejections = mirrorLimitRejections
        self.unstableExternalIDRejections = unstableExternalIDRejections
        self.dosesSkippedUnstableExternalID = dosesSkippedUnstableExternalID
    }

    public static let zero = AppleHealthMedicationSyncSummary()

    public var dosesLanded: Int {
        dosesInserted + dosesUpdated + dosesDuplicate
    }

    /// The user-facing issue this sweep produced, if any. An unstable identifier
    /// outranks the cap: it means the mirror is minting garbage, which is the
    /// worse of the two and the one that has already cost a live instance 23
    /// phantom rows.
    public var issue: AppleHealthMirrorIssue? {
        if unstableExternalIDRejections > 0 || dosesSkippedUnstableExternalID > 0 {
            return .unstableExternalId
        }
        if mirrorLimitRejections > 0 { return .limitReached }
        return nil
    }
}
