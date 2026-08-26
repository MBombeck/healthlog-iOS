import CryptoKit
import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// **v0.6.2.3 F3-SEC (A-CODE M-1) — silent outbox loss on decrypt failure.**
///
/// Pre-v0.6.2.3 the snapshot path returned the raw ciphertext as the
/// "plaintext" payload whenever `OutboxPayloadCipher.decrypt(...)` threw
/// (corrupt blob / wiped key / tag mismatch / version drift). The replay
/// dispatcher then JSON-decoded the cipher bytes, hit the non-retriable
/// arm of the catch, and dropped the row with a generic "verworfen"
/// warning — indistinguishable from a real schema-drift bug and giving
/// no signal that the loss was the user's queued health data, not a
/// server-rejected one.
///
/// The fix moves the failure handling into `OutboxStore.snapshot()`
/// itself: corrupt rows are deleted at the actor boundary, a distinct
/// `decrypt failed for record …` log line lands in the `outbox`
/// category, and the dispatcher never sees the corruption.
///
/// These tests pin the three branches:
///  1. Corrupt ciphertext (tag-flip) → row deleted, not returned.
///  2. Key swap (post-logout-wipe scenario) → row deleted, not returned.
///  3. Healthy row → unchanged path, returned as plaintext.
@Suite("OutboxStore.snapshot — decrypt-failure handling (F3-SEC M-1)")
struct OutboxSnapshotDecryptFailureTests {
    // MARK: - Corrupt ciphertext branch

    @Test("Tampered ciphertext row is deleted at snapshot boundary, not surfaced")
    func corruptCiphertextRowIsDeleted() async throws {
        let container = try OutboxStore.makeInMemory()
        let store = OutboxStore(modelContainer: container)
        let stub = StubKeychain()
        let cipher = OutboxPayloadCipher(keychain: stub, keyAccount: "test.snapshot.corrupt")
        await store.useCipher(cipher)

        // Enqueue a healthy row + a corrupt one. After the snapshot pass,
        // the healthy row must still be there; the corrupt row must be
        // deleted both from the SwiftData store and from the snapshot
        // slice.
        let healthyID = UUID()
        let healthyPlain = Data(#"{"value":120,"systolic":true}"#.utf8)
        try await store.enqueue(
            id: healthyID,
            kindRaw: OutboxQueue.Operation.Kind.createMeasurement.rawValue,
            payload: healthyPlain,
            idempotencyKey: UUID().uuidString.lowercased(),
            createdAt: .now
        )

        let corruptID = UUID()
        // Build a well-formed sealed blob then flip a byte in the body to
        // force an AES-GCM tag-check failure on read.
        var corrupt = try cipher.encrypt(Data(#"{"value":999}"#.utf8))
        corrupt[corrupt.count / 2] ^= 0xFF
        try await seedRowDirectly(
            id: corruptID,
            payload: corrupt,
            createdAt: Date(timeIntervalSinceNow: 1),
            in: container
        )

        let snap = try await store.snapshot()

        // Snapshot must contain only the healthy row.
        #expect(snap.count == 1)
        #expect(snap.first?.id == healthyID)
        #expect(snap.first?.payload == healthyPlain)

        // The SwiftData row for the corrupt id must be gone — the
        // snapshot boundary deleted it in-place, not the dispatcher.
        let stillPresent = try await rowExists(forId: corruptID, in: container)
        #expect(stillPresent == false)

        // The healthy row stays.
        let healthyStill = try await rowExists(forId: healthyID, in: container)
        #expect(healthyStill == true)
    }

    // MARK: - Wiped-key branch (post-logout scenario)

    @Test("Row encrypted under a previous key is deleted after the key is wiped")
    func wipedKeyRowIsDeleted() async throws {
        let container = try OutboxStore.makeInMemory()
        let store = OutboxStore(modelContainer: container)
        let stub = StubKeychain()
        let account = "test.snapshot.wiped-key"
        let cipherA = OutboxPayloadCipher(keychain: stub, keyAccount: account)
        await store.useCipher(cipherA)

        let id = UUID()
        let plain = Data(#"{"note":"sensitive"}"#.utf8)
        try await store.enqueue(
            id: id,
            kindRaw: OutboxQueue.Operation.Kind.createMeasurement.rawValue,
            payload: plain,
            idempotencyKey: UUID().uuidString.lowercased(),
            createdAt: .now
        )

        // Simulate the logout-wipe: drop the persisted key, then let the
        // cipher resurrect a fresh one on the next snapshot.
        // `fetchOrCreateKey` will regenerate on miss, so the cipher tries
        // to decrypt the existing row with a key that DOESN'T match the
        // one that sealed it — should fail the tag check.
        try stub.remove(forKey: account)

        let snap = try await store.snapshot()

        #expect(snap.isEmpty)
        let stillPresent = try await rowExists(forId: id, in: container)
        #expect(stillPresent == false)
    }

    // MARK: - Healthy-row regression guard

    @Test("Healthy ciphertext row passes through snapshot unchanged")
    func healthyRowUnchanged() async throws {
        let container = try OutboxStore.makeInMemory()
        let store = OutboxStore(modelContainer: container)
        let stub = StubKeychain()
        await store.useCipher(OutboxPayloadCipher(keychain: stub, keyAccount: "test.snapshot.healthy"))

        let id = UUID()
        let plain = Data(#"{"id":"abc","kind":"measurement"}"#.utf8)
        try await store.enqueue(
            id: id,
            kindRaw: OutboxQueue.Operation.Kind.createMeasurement.rawValue,
            payload: plain,
            idempotencyKey: UUID().uuidString.lowercased(),
            createdAt: .now
        )

        let snap = try await store.snapshot()
        try #require(snap.count == 1)
        #expect(snap[0].id == id)
        #expect(snap[0].payload == plain)

        // Row stays on disk — no false-positive deletion in the healthy
        // branch.
        let stillPresent = try await rowExists(forId: id, in: container)
        #expect(stillPresent == true)
    }

    @Test("Mixed batch: corrupt rows removed, plaintext-migration row retained, healthy row stays")
    func mixedBatchPartialDeletion() async throws {
        let container = try OutboxStore.makeInMemory()
        let store = OutboxStore(modelContainer: container)
        let stub = StubKeychain()
        let cipher = OutboxPayloadCipher(keychain: stub, keyAccount: "test.snapshot.mixed")
        await store.useCipher(cipher)

        // Healthy ciphertext row.
        let healthyID = UUID()
        let healthyPlain = Data(#"{"k":"healthy"}"#.utf8)
        try await store.enqueue(
            id: healthyID,
            kindRaw: OutboxQueue.Operation.Kind.createMeasurement.rawValue,
            payload: healthyPlain,
            idempotencyKey: UUID().uuidString.lowercased(),
            createdAt: Date(timeIntervalSinceNow: 0)
        )

        // Pre-v0.6.2 plaintext row (no version tag) — migration-on-read
        // path, must NOT be deleted.
        let legacyID = UUID()
        let legacyPlain = Data(#"{"k":"legacy"}"#.utf8)
        try await seedRowDirectly(
            id: legacyID,
            payload: legacyPlain,
            createdAt: Date(timeIntervalSinceNow: 1),
            in: container
        )

        // Corrupt ciphertext row — must be deleted.
        let corruptID = UUID()
        var corrupt = try cipher.encrypt(Data(#"{"k":"corrupt"}"#.utf8))
        corrupt[corrupt.count - 2] ^= 0xFF // flip a byte in the tag region
        try await seedRowDirectly(
            id: corruptID,
            payload: corrupt,
            createdAt: Date(timeIntervalSinceNow: 2),
            in: container
        )

        let snap = try await store.snapshot()
        let ids = Set(snap.map(\.id))
        #expect(ids == [healthyID, legacyID])
        #expect(try await rowExists(forId: healthyID, in: container) == true)
        #expect(try await rowExists(forId: legacyID, in: container) == true)
        #expect(try await rowExists(forId: corruptID, in: container) == false)
    }

    // MARK: - Helpers

    @MainActor
    private func seedRowDirectly(
        id: UUID,
        payload: Data,
        createdAt: Date,
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let op = OutboxOperation(
            id: id,
            kindRaw: OutboxQueue.Operation.Kind.createMeasurement.rawValue,
            payload: payload,
            idempotencyKey: UUID().uuidString.lowercased(),
            createdAt: createdAt
        )
        context.insert(op)
        try context.save()
    }

    @MainActor
    private func rowExists(forId id: UUID, in container: ModelContainer) throws -> Bool {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id }
        )
        return try !context.fetch(descriptor).isEmpty
    }
}
