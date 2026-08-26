import Foundation
@testable import HealthLog
import Testing

/// Phase 07 / Plan 07-04 — the skip-reason vocabulary exists in two places and
/// must never drift.
///
/// `MeasurementBatchAcceptance` is part of the platform-free core, so it cannot
/// import `HealthKitServerSupportConfig` (iOS-only, HealthKit module) or
/// `DeployedMeasurementContract` (Phase-07 HealthKit contracts). It therefore
/// spells the reasons out itself. This suite is the seam that keeps the two
/// spellings identical: a reason renamed on one side without the other would
/// silently move an index from "holds" to "terminal", which is exactly the class
/// of false cursor advancement this phase closes.
@Suite("Measurement batch acceptance — reason vocabulary is pinned across modules")
struct MeasurementBatchAcceptanceReasonPinTests {
    @Test("the core gate spells every documented server reason exactly as the HealthKit config does")
    func reasonSpellingsMatch() {
        #expect(
            MeasurementBatchAcceptance.Reason.unmappableIdentifier
                == HealthKitServerSupportConfig.reasonUnmappableIdentifier
        )
        #expect(
            MeasurementBatchAcceptance.Reason.valueOutOfRange
                == HealthKitServerSupportConfig.reasonValueOutOfRange
        )
        #expect(
            MeasurementBatchAcceptance.Reason.unstableExternalId
                == HealthKitServerSupportConfig.reasonUnstableExternalId
        )
        #expect(
            MeasurementBatchAcceptance.Reason.supersededInBatch
                == DeployedMeasurementContract.supersededInBatchReason
        )
    }

    @Test("the allowlist is exactly the documented terminal reasons — unmappable included")
    func allowlistMatchesTheDocumentedSet() {
        // `unmappable_identifier` is terminal *for the batch envelope*: the POST
        // is complete and no retry of the same batch changes it. The one index it
        // affects is held separately by the sample importers, which is why it may
        // be in the allowlist without letting a stalled type advance.
        #expect(MeasurementBatchAcceptance.Policy.deployedMeasurementRoute.terminalSkipReasons == [
            HealthKitServerSupportConfig.reasonUnmappableIdentifier,
            HealthKitServerSupportConfig.reasonValueOutOfRange,
            HealthKitServerSupportConfig.reasonUnstableExternalId
        ])
    }

    @Test("the stable stat identity prefix matches the one the statistics path emits")
    func statPrefixMatchesProducedIdentity() {
        let row = HealthKitDailyStatRow(
            hkIdentifier: "HKQuantityTypeIdentifierStepCount",
            dayStart: Date(timeIntervalSince1970: 1_716_000_000),
            dayKey: "2026-05-16",
            value: 8345,
            unit: "steps"
        )
        #expect(row.externalId.hasPrefix(MeasurementBatchAcceptance.stableStatIdentityPrefix))
    }

    @Test("every deployed status word the contract names is classified by the shipped enum")
    func everyDeployedStatusIsNameable() {
        for status in DeployedMeasurementEntryStatus.allCases {
            let decoded = HealthKitEntryStatus(rawValue: status.rawValue)
            #expect(decoded != nil, "shipped decoder cannot name deployed status \(status.rawValue)")
            #expect(decoded != .unknown, "deployed status \(status.rawValue) fell into the catch-all")
        }
    }
}
