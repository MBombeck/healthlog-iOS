import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import Testing

/// Phase 07 Wave 0 — heart and mobility event durability.
///
/// The event importer runs one anchored sweep per category type from a
/// fire-and-forget observer task. It holds its anchor only when the uploader
/// throws; a cancelled sweep (logout, background expiration, teardown) and a
/// lost account lease still reach `saveAnchor`, and the observer's completion
/// handler fires before the owned work is durable.
@Suite("Heart health event importer durability")
struct HeartHealthEventImporterTests {
    private static func outcome(cancelled: Bool, leaseIsCurrent: Bool) -> HealthSyncPageOutcome {
        HealthSyncPageOutcome(
            postedCount: 1,
            entries: [
                HealthSyncEntryOutcome(index: 0, stableIdentity: "hk-event-1", classification: .terminalAccepted)
            ],
            transportThrew: false,
            durableRetryPersisted: false,
            durableRetryFailed: false,
            leaseIsCurrent: leaseIsCurrent,
            wasCancelled: cancelled
        )
    }

    #if canImport(HealthKit)
        @Test("the seven documented event types are still observed")
        func eventTypesAreComplete() {
            let identifiers = Set(HeartHealthEventImporter.eventCategoryTypes().map(\.identifier))
            #expect(identifiers == Set([
                HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue,
                HKCategoryTypeIdentifier.highHeartRateEvent.rawValue,
                HKCategoryTypeIdentifier.lowHeartRateEvent.rawValue,
                HKCategoryTypeIdentifier.appleWalkingSteadinessEvent.rawValue,
                HKCategoryTypeIdentifier.sleepApneaEvent.rawValue,
                HKCategoryTypeIdentifier.environmentalAudioExposureEvent.rawValue,
                HKCategoryTypeIdentifier.headphoneAudioExposureEvent.rawValue
            ]))
        }
    #endif

    @Test("the required rule holds a cancelled or unleased sweep")
    func requiredRuleHoldsCancelledAndUnleasedWork() {
        #expect(
            HealthSyncCursorPolicy.required.decide(Self.outcome(cancelled: true, leaseIsCurrent: true))
                == .hold(reason: .cancelled)
        )
        #expect(
            HealthSyncCursorPolicy.required.decide(Self.outcome(cancelled: false, leaseIsCurrent: false))
                == .hold(reason: .leaseLost)
        )
        #expect(
            HealthSyncCursorPolicy.required.decide(Self.outcome(cancelled: false, leaseIsCurrent: true))
                == .commit
        )
    }

    @Test("an observer trigger stays bounded to its own signalled source")
    func observerBudgetIsBounded() {
        let budget = HealthSyncBudget.required(for: .observer)
        #expect(budget.maxPagesPerType == 1)
        #expect(!budget.allowsFirstHistoryImport)
        #expect(HealthSyncCompositionPlan.required(for: .observer).isEmpty)
    }

    // MARK: - RED

    /// Cancelled event work must not move the per-type cursor, and the importer
    /// must own its observer task through a lease instead of a detached sweep.
    @Test("cancelled heart event work holds the cursor")
    func cancellationHoldsCursor() throws {
        var violations: [String] = []

        if HealthSyncCursorPolicy.installed.decide(Self.outcome(cancelled: true, leaseIsCurrent: true)) == .commit {
            violations.append("a cancelled sweep still advanced the per-type cursor")
        }
        if HealthSyncCursorPolicy.installed.decide(Self.outcome(cancelled: false, leaseIsCurrent: false)) == .commit {
            violations.append("a sweep that lost its lease still advanced the per-type cursor")
        }

        let importer = try Self.source("HealthLog/Services/HealthKit/HeartHealthEventImporter.swift")
        if !importer.contains("Task.isCancelled") {
            violations.append("the importer never checks cancellation across its awaits")
        }
        if !importer.contains("HealthSyncCursorPolicy") {
            violations.append("the importer does not consult the shared commit rule")
        }

        #expect(violations.isEmpty, "EXPECTED_RED: cancelled heart event work advanced cursor")
    }

    // MARK: - Source access

    private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
