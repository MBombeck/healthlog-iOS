import Foundation
@testable import HealthLog
import Testing

/// Phase 07 Wave 0 — restart and replay identity.
///
/// A process that dies between a durable enqueue and the cursor write, or
/// between server acceptance and the cursor write, must replay under exactly
/// the identity it used before. Minting a fresh local id and a fresh
/// idempotency key on every attempt — what the mood write path does today —
/// turns a retry into a second row.
@Suite("HealthKit sync restart recovery")
struct HealthSyncRestartRecoveryTests {
    // MARK: - Deterministic identity

    @Test("a rebuilt envelope derives the same idempotency key")
    func envelopeIsDeterministicAcrossRestart() throws {
        let before = try #require(
            HealthSyncRetryEnvelope(ownerID: "account-a", source: .mood, stableIdentity: "hk-sample-1")
        )
        let afterRelaunch = try #require(
            HealthSyncRetryEnvelope(ownerID: "account-a", source: .mood, stableIdentity: "hk-sample-1")
        )

        #expect(before == afterRelaunch)
        #expect(before.idempotencyKey == afterRelaunch.idempotencyKey)
        #expect(before.idempotencyKey.count == 36)
        #expect(before.idempotencyKey.split(separator: "-").count == 5)
    }

    @Test("owner, source, and identity all participate in the retry identity")
    func envelopeSeparatesOwnersAndSources() throws {
        let base = try #require(
            HealthSyncRetryEnvelope(ownerID: "account-a", source: .mood, stableIdentity: "hk-sample-1")
        )
        let otherOwner = try #require(
            HealthSyncRetryEnvelope(ownerID: "account-b", source: .mood, stableIdentity: "hk-sample-1")
        )
        let otherSource = try #require(
            HealthSyncRetryEnvelope(ownerID: "account-a", source: .heartEvent, stableIdentity: "hk-sample-1")
        )
        let otherIdentity = try #require(
            HealthSyncRetryEnvelope(ownerID: "account-a", source: .mood, stableIdentity: "hk-sample-2")
        )

        let keys = Set([base, otherOwner, otherSource, otherIdentity].map(\.idempotencyKey))
        #expect(keys.count == 4)
        #expect(HealthSyncRetryEnvelope(ownerID: " ", source: .mood, stableIdentity: "hk-sample-1") == nil)
        #expect(HealthSyncRetryEnvelope(ownerID: "account-a", source: .mood, stableIdentity: "") == nil)
    }

    @Test("a freshly minted idempotency key is not restart stable")
    func mintedKeysAreNotStable() {
        #expect(IdempotencyKey().raw != IdempotencyKey().raw)
    }

    @Test("a durable enqueue permits the cursor to advance, a lost one does not")
    func durableEnqueueGatesTheCursor() {
        let rejected = [
            HealthSyncEntryOutcome(index: 0, stableIdentity: "hk-sample-1", classification: .nonterminal)
        ]
        func outcome(persisted: Bool, lost: Bool) -> HealthSyncPageOutcome {
            HealthSyncPageOutcome(
                postedCount: 1,
                entries: rejected,
                transportThrew: false,
                durableRetryPersisted: persisted,
                durableRetryFailed: lost,
                leaseIsCurrent: true,
                wasCancelled: false
            )
        }

        #expect(HealthSyncCursorPolicy.required.decide(outcome(persisted: true, lost: false)) == .commit)
        #expect(
            HealthSyncCursorPolicy.required.decide(outcome(persisted: false, lost: true))
                == .hold(reason: .retryPersistenceFailed)
        )
    }

    // MARK: - RED

    /// Both restart points — after a durable enqueue and after server
    /// acceptance — must replay one stable identity. The mood write path still
    /// mints a new local id and a new idempotency key per attempt and swallows
    /// a lost enqueue, and no importer derives its retry identity from the
    /// HealthKit sample it came from.
    @Test("a restart reuses the stable retry identity")
    func restartReusesStableRetryIdentity() throws {
        var violations: [String] = []

        let bindings = [
            ("HealthLog/Repositories/MoodRepository.swift", "HealthSyncRetryEnvelope"),
            ("HealthLog/Services/HealthKit/MoodStateOfMindImporter.swift", "HealthSyncRetryEnvelope"),
            ("HealthLog/Services/HealthKit/HeartHealthEventImporter.swift", "HealthSyncRetryEnvelope")
        ]
        for (path, symbol) in bindings {
            let contents = try Self.source(path)
            if !contents.contains(symbol) {
                violations.append("\(path) does not derive a restart-stable identity via \(symbol)")
            }
        }

        // The mood repository still creates a per-attempt local id, so a replay
        // after relaunch cannot resolve to the row the first attempt intended.
        let moodRepository = try Self.source("HealthLog/Repositories/MoodRepository.swift")
        if moodRepository.contains("MoodEntry(id: \"local-\\(UUID().uuidString)\"") {
            violations.append("the mood write path mints a new local identity per attempt")
        }

        #expect(violations.isEmpty, "EXPECTED_RED: restart minted a new retry identity")
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
