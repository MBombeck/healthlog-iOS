import Foundation
@testable import HealthLog
import Testing

/// The executable definition of "sync everything".
///
/// A manual or foreground sweep must reach every enabled importer, a short
/// background wake must stay incremental, an observer must touch only the
/// source it was signalled for, and cold activation must install the chosen
/// backfill cutoff before the first query. Anything disabled, unsupported, or
/// postponed is named, never silently omitted.
@Suite("Complete HealthKit sync composition")
struct CompleteHealthSyncCompositionTests {
    // MARK: - Inventories

    @Test("the sample registry is exactly the forty-two collected identifiers plus the OS-gated ones")
    func sampleRegistryIsExact() {
        #expect(HealthLogSampleTypeRegistry.baseIdentifiers.count == 57)
        #expect(HealthLogSampleTypeRegistry.knownIdentifiers.count == HealthLogSampleTypeRegistry.expectedCount)
        #expect(HealthLogSampleTypeRegistry.contains("HKQuantityTypeIdentifierHeartRate"))
        #expect(HealthLogSampleTypeRegistry.contains("HKQuantityTypeIdentifierTimeInDaylight"))
        #expect(!HealthLogSampleTypeRegistry.contains("HKQuantityTypeIdentifierBloodAlcoholContent"))
    }

    @Test("every non-sample importer is a distinct named capability")
    func nonSampleImportersAreNamed() {
        let nonSample = HealthSyncCapability.allCases.filter { !$0.isSampleCollection }
        // MIRROR (1.5) — the server mirror is the eleventh, the Health
        // Records labs (1.7) the twelfth.
        #expect(nonSample.count == 12)
        #expect(Set(nonSample.map(\.source)).count == nonSample.count)
        #expect(Set(HealthSyncCapability.allCases.map(\.rawValue)).count == HealthSyncCapability.allCases.count)

        let optIn = HealthSyncCapability.allCases.filter(\.requiresExplicitOptIn).map(\.rawValue).sorted()
        #expect(optIn == [
            "appleMedicationImport",
            "clinicalLabRecords",
            "cycleImport",
            "ecgUpload",
            "moodStateOfMindImport",
            "nutrientDailyTotals"
        ])
    }

    @Test("background scheduling makes no fixed-period claim")
    func schedulingClaimIsHonest() {
        #expect(!HealthSyncSchedulingTruth.guaranteesFixedPeriod)
        let claim = HealthSyncSchedulingTruth.claim.lowercased()
        for forbidden in ["every ", "minute", "hour", "alle ", "stünd"] {
            #expect(!claim.contains(forbidden), "the scheduling claim promises a cadence: \(forbidden)")
        }
    }

    // MARK: - RED

    /// Manual, foreground, processing, and post-authentication passes must reach
    /// every capability; short wakes must reach the incremental set; cold
    /// activation must install the cutoff first; and every inventoried direct
    /// trigger must enter the orchestrator.
    @Test("the exact registry and every direct trigger are complete")
    func exactRegistryAndEveryDirectTriggerAreComplete() {
        var violations: [String] = []

        for trigger in HealthSyncTrigger.allCases {
            let required = HealthSyncCompositionPlan.required(for: trigger)
            let installed = HealthSyncCompositionPlan.installed(for: trigger)
            let missing = required.subtracting(installed)
            if !missing.isEmpty {
                violations.append("\(trigger.rawValue) omits \(missing.count) capability(ies)")
            }
        }

        if HealthSyncCompositionPlan.installedInstallsCutoffBeforeFirstQuery
            != HealthSyncCompositionPlan.requiredInstallsCutoffBeforeFirstQuery
        {
            violations.append("cold activation queries before the chosen cutoff is installed")
        }

        #expect(violations.isEmpty, "registry or direct trigger coverage was incomplete")
    }
}
