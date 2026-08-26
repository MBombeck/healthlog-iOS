import CryptoKit
import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// **v0.7.1 C-1 — queued offline writes survive a benign (row-preserving) logout.**
///
/// The logout cascade (`AppContainer.performFullLocalLogout(reason:)`) keeps
/// the encrypted outbox rows on the same-account, same-server paths
/// (`.userInitiated` / `.tokenExpired`), so a re-login can replay pending
/// optimistic writes. Pre-v0.7.1 the cascade nonetheless wiped the AES-GCM
/// cipher key on *every* path — leaving the kept rows mathematically
/// undecryptable. `OutboxStore.snapshot()` then deleted every row it could not
/// decrypt, silently destroying the very writes the row-preservation set out
/// to protect.
///
/// The fix gates the key wipe on the same `clearsOutbox` flag as the row
/// clear. These tests reproduce the end-to-end interaction at the store + key
/// layer the bug lived in:
///
///  1. **Benign logout (key kept)** → the enqueued row still decrypts on the
///     next `snapshot()`, exactly as a same-account re-login would replay it.
///  2. **Outbox-clearing logout (key wiped — `.accountDeleted` /
///     `.switchServer`)** → the row drops at the snapshot boundary,
///     confirming the cross-user / cross-server leakage defense still holds
///     when the rows are being cleared anyway.
///
/// The `OutboxKeyLogoutWipeTests` suite pins the key lifecycle at the
/// `AppContainer` level; this suite pins the *consequence* on the persisted
/// rows so the regression can't reappear in either layer.
@Suite("Outbox survives a benign logout (C-1)")
struct OutboxSurvivesBenignLogoutTests {
    /// `.userInitiated` / `.tokenExpired` keep the cipher key, so a row
    /// enqueued while offline still decrypts after the logout.
    @Test("Row enqueued offline survives a row-preserving logout and re-snapshots decryptable")
    func benignLogoutPreservesEnqueuedRow() async throws {
        let container = try OutboxStore.makeInMemory()
        let store = OutboxStore(modelContainer: container)

        // The cipher shares the keychain the logout cascade wipes, keyed at
        // the production account name so the gating contract is exercised
        // against the real constant.
        let keychain = InMemoryKeychain()
        let cipher = OutboxPayloadCipher(keychain: keychain, keyAccount: KeychainKey.outboxPayloadKey)
        await store.useCipher(cipher)

        // Offline write lands in the outbox (cipher generates + persists the key).
        let id = UUID()
        let plain = Data(#"{"value":120,"note":"logged while offline"}"#.utf8)
        try await store.enqueue(
            id: id,
            kindRaw: OutboxQueue.Operation.Kind.createMeasurement.rawValue,
            payload: plain,
            idempotencyKey: UUID().uuidString.lowercased(),
            createdAt: .now
        )
        #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) != nil)

        // Benign logout (.userInitiated / .tokenExpired): rows kept → key
        // kept. The production gate is `LogoutReason.userInitiated.clearsOutbox`
        // which is `false`, so the cascade does NOT remove the key here. We
        // assert the gate's value to keep this test honest if the gate flips.
        // `.switchServer` is NOT a benign path — it clears the outbox because
        // the rows were minted against the previous server, so its gate is
        // `true` (covered by `OutboxKeyLogoutWipeTests`).
        #expect(LogoutReason.userInitiated.clearsOutbox == false)
        #expect(LogoutReason.tokenExpired.clearsOutbox == false)
        #expect(LogoutReason.switchServer.clearsOutbox == true)
        // (No key removal — the row-preserving path leaves the key in place.)

        // Same-account re-login: the next snapshot must still surface the
        // pending write as plaintext, and the row must remain on disk.
        let snap = try await store.snapshot()
        try #require(snap.count == 1)
        #expect(snap[0].id == id)
        #expect(snap[0].payload == plain)
        let stillPresent = try await rowExists(forId: id, in: container)
        #expect(stillPresent == true)
    }

    /// Account-deletion clears the rows AND the key, so by the time a snapshot
    /// runs there is nothing to strand — confirming the leakage defense is
    /// preserved on the only path that wipes the key.
    @Test("Account-deletion wipes the key and the row drops at the snapshot boundary")
    func accountDeletionWipesKeyAndDropsRow() async throws {
        let container = try OutboxStore.makeInMemory()
        let store = OutboxStore(modelContainer: container)

        let keychain = InMemoryKeychain()
        let cipher = OutboxPayloadCipher(keychain: keychain, keyAccount: KeychainKey.outboxPayloadKey)
        await store.useCipher(cipher)

        let id = UUID()
        let plain = Data(#"{"value":80}"#.utf8)
        try await store.enqueue(
            id: id,
            kindRaw: OutboxQueue.Operation.Kind.createMeasurement.rawValue,
            payload: plain,
            idempotencyKey: UUID().uuidString.lowercased(),
            createdAt: .now
        )

        // Account-deletion path: rows cleared + key wiped together.
        #expect(LogoutReason.accountDeleted.clearsOutbox == true)
        try keychain.remove(forKey: KeychainKey.outboxPayloadKey)

        // Even if a row survived a missed clearAll, the snapshot can no longer
        // decrypt it (fresh key minted on access) and drops it — never leaking
        // the previous account's queued payload to the next user.
        let snap = try await store.snapshot()
        #expect(snap.isEmpty)
        let stillPresent = try await rowExists(forId: id, in: container)
        #expect(stillPresent == false)
    }

    // MARK: - Helpers

    @MainActor
    private func rowExists(forId id: UUID, in container: ModelContainer) throws -> Bool {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id }
        )
        return try !context.fetch(descriptor).isEmpty
    }
}
