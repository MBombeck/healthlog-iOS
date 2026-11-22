import Foundation
@testable import HealthLog
import Testing

/// State-of-Mind import durability.
///
/// `MoodStateOfMindImporter.runAnchoredSweep` imports each foreign sample and
/// then saves the query's new anchor. A per-item failure is logged and
/// swallowed, and the repository's own outbox write can fail behind the
/// original error, so a sample can be dropped while its anchor moves past it.
@Suite("State of Mind import durability")
struct MoodImportDurabilityTests {
    private static func outcome(
        retryPersisted: Bool,
        retryFailed: Bool,
        classification: HealthSyncAcceptanceClass?
    ) -> HealthSyncPageOutcome {
        HealthSyncPageOutcome(
            postedCount: 1,
            entries: [
                HealthSyncEntryOutcome(index: 0, stableIdentity: "hk-mood-1", classification: classification)
            ],
            transportThrew: false,
            durableRetryPersisted: retryPersisted,
            durableRetryFailed: retryFailed,
            leaseIsCurrent: true,
            wasCancelled: false
        )
    }

    @Test("a lost enqueue holds the anchor under the required rule")
    func requiredRuleHoldsOnLostEnqueue() {
        let lost = Self.outcome(retryPersisted: false, retryFailed: true, classification: .nonterminal)
        #expect(HealthSyncCursorPolicy.required.decide(lost) == .hold(reason: .retryPersistenceFailed))

        let persisted = Self.outcome(retryPersisted: true, retryFailed: false, classification: .nonterminal)
        #expect(HealthSyncCursorPolicy.required.decide(persisted) == .commit)
    }

    @Test("mood retry identity comes from the HealthKit sample, not the attempt")
    func moodIdentityIsDerivedFromTheSample() throws {
        let first = try #require(
            HealthSyncRetryEnvelope(ownerID: "account-a", source: .mood, stableIdentity: "hk-mood-1")
        )
        let retry = try #require(
            HealthSyncRetryEnvelope(ownerID: "account-a", source: .mood, stableIdentity: "hk-mood-1")
        )
        #expect(first.idempotencyKey == retry.idempotencyKey)
    }

    @Test("mood is a named capability with an explicit opt-in disposition")
    func moodIsNamedInTheCapabilityInventory() {
        #expect(HealthSyncCapability.moodStateOfMindImport.source == .mood)
        #expect(HealthSyncCapability.moodStateOfMindImport.requiresExplicitOptIn)
        #expect(!HealthSyncCapability.moodStateOfMindImport.isSampleCollection)
        #expect(HealthSyncDisposition.allCases.contains(.disabled))
    }

    // MARK: - RED

    /// A failed durable enqueue must hold the State-of-Mind anchor.
    @Test("an enqueue failure holds the anchor")
    func enqueueFailureHoldsAnchor() {
        var violations: [String] = []

        let lost = Self.outcome(retryPersisted: false, retryFailed: true, classification: .nonterminal)
        if HealthSyncCursorPolicy.installed.decide(lost) == .commit {
            violations.append("a lost durable enqueue still advanced the anchor")
        }

        #expect(violations.isEmpty, "Mood enqueue failure advanced anchor")
    }
}
