import Foundation
@testable import HealthLog
import Testing

/// Phase 07 Wave 0 — State-of-Mind import durability.
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

    /// A failed durable enqueue must hold the State-of-Mind anchor, and the
    /// importer must reach its anchor through the shared commit contract
    /// instead of saving it after a swallowed error.
    @Test("an enqueue failure holds the anchor")
    func enqueueFailureHoldsAnchor() throws {
        var violations: [String] = []

        let lost = Self.outcome(retryPersisted: false, retryFailed: true, classification: .nonterminal)
        if HealthSyncCursorPolicy.installed.decide(lost) == .commit {
            violations.append("a lost durable enqueue still advanced the anchor")
        }

        let importer = try Self.source("HealthLog/Services/HealthKit/MoodStateOfMindImporter.swift")
        if !importer.contains("HealthSyncCursorPolicy") {
            violations.append("the importer does not consult the shared commit rule")
        }
        if importer.contains("saveAnchor(result.newAnchor)") {
            violations.append("the importer still saves the anchor at the tail of the sweep")
        }

        let repository = try Self.source("HealthLog/Repositories/MoodRepository.swift")
        if repository.contains("HLLog.outbox.error(\"Outbox enqueue failed") {
            violations.append("the mood repository still swallows a lost outbox write")
        }

        #expect(violations.isEmpty, "EXPECTED_RED: Mood enqueue failure advanced anchor")
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
