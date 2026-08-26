import CryptoKit
import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// **v0.6.2 W-SEC-A (M-4) — Outbox payload encryption.**
///
/// Pins the at-rest encryption contract for the SwiftData
/// `OutboxOperation.payload` blob:
///
///  1. `OutboxPayloadCipher.encrypt` then `decrypt` round-trips byte-for-byte.
///  2. A tampered ciphertext fails to decrypt (AES-GCM tag check).
///  3. An `OutboxStore.enqueue(...)` writes ciphertext (version-tagged) to
///     the SwiftData row, and the subsequent `snapshot()` returns plaintext.
///  4. A pre-v0.6.2 plaintext row is migrated on read: the next snapshot
///     returns plaintext + the underlying row's `payload` field has
///     transitioned to ciphertext-with-version-tag.
@Suite("OutboxStore — payload encryption (W-SEC-A M-4)")
struct OutboxEncryptionTests {
    // MARK: - Cipher unit contract

    @Test("Encrypt then decrypt round-trips byte-for-byte")
    func roundTripIdentity() throws {
        let stub = StubKeychain()
        let cipher = OutboxPayloadCipher(keychain: stub, keyAccount: "test.outbox.key.a")
        let plain = Data(#"{"value":120,"note":"BP rose after coffee"}"#.utf8)

        let ciphertext = try cipher.encrypt(plain)
        let recovered = try cipher.decrypt(ciphertext)

        #expect(recovered == plain)
        // The version-tag is the first byte of the output.
        #expect(ciphertext.first == OutboxPayloadCipher.versionTag)
        // The ciphertext is strictly larger than the plaintext (nonce + tag).
        #expect(ciphertext.count > plain.count + 12 + 16)
    }

    @Test("Tampered ciphertext fails to decrypt — AES-GCM tag check")
    func tamperingDetected() throws {
        let stub = StubKeychain()
        let cipher = OutboxPayloadCipher(keychain: stub, keyAccount: "test.outbox.key.b")
        let plain = Data("payload-with-pii".utf8)
        var ciphertext = try cipher.encrypt(plain)
        // Flip a byte in the middle of the ciphertext body (skip the
        // version tag at index 0 + the 12-byte nonce that follows).
        ciphertext[ciphertext.count / 2] ^= 0xFF

        #expect(throws: (any Error).self) {
            _ = try cipher.decrypt(ciphertext)
        }
    }

    @Test("Decrypt rejects blob without the version tag (would-be plaintext)")
    func plaintextRejected() throws {
        let stub = StubKeychain()
        let cipher = OutboxPayloadCipher(keychain: stub, keyAccount: "test.outbox.key.c")
        let bogus = Data("{ \"plaintext\": true }".utf8)
        #expect(throws: OutboxPayloadCipher.CipherError.unrecognizedFormat) {
            _ = try cipher.decrypt(bogus)
        }
    }

    @Test("isCiphertext discriminator: plaintext JSON → false, sealed blob → true")
    func discriminatorDistinguishesPlaintextAndCiphertext() throws {
        let stub = StubKeychain()
        let cipher = OutboxPayloadCipher(keychain: stub, keyAccount: "test.outbox.key.d")
        let plain = Data(#"{"k":"v"}"#.utf8)
        #expect(OutboxPayloadCipher.isCiphertext(plain) == false)
        let arrayShape = Data(#"["a","b"]"#.utf8)
        #expect(OutboxPayloadCipher.isCiphertext(arrayShape) == false)
        let sealed = try cipher.encrypt(plain)
        #expect(OutboxPayloadCipher.isCiphertext(sealed) == true)
    }

    @Test("Key is generated on first use and persisted for subsequent calls")
    func keyPersistsAcrossInstances() throws {
        let stub = StubKeychain()
        let account = "test.outbox.key.e"
        let cipherA = OutboxPayloadCipher(keychain: stub, keyAccount: account)
        let plain = Data("hello".utf8)
        let sealed = try cipherA.encrypt(plain)

        // A second cipher instance over the same keychain account must
        // resurrect the same key and decrypt the sealed blob.
        let cipherB = OutboxPayloadCipher(keychain: stub, keyAccount: account)
        let recovered = try cipherB.decrypt(sealed)
        #expect(recovered == plain)
    }

    // MARK: - Store integration

    @Test("enqueue writes ciphertext to the SwiftData row, snapshot returns plaintext")
    func enqueueWritesCiphertextSnapshotReturnsPlaintext() async throws {
        let container = try OutboxStore.makeInMemory()
        let store = OutboxStore(modelContainer: container)
        let stub = StubKeychain()
        await store.useCipher(OutboxPayloadCipher(keychain: stub, keyAccount: "test.outbox.key.f"))

        let id = UUID()
        let plain = Data(#"{"id":"abc","note":"sensitive"}"#.utf8)
        try await store.enqueue(
            id: id,
            kindRaw: OutboxQueue.Operation.Kind.createMeasurement.rawValue,
            payload: plain,
            idempotencyKey: UUID().uuidString.lowercased(),
            createdAt: .now
        )

        // Snapshot must surface plaintext to the dispatcher.
        let snap = try await store.snapshot()
        try #require(snap.count == 1)
        #expect(snap[0].payload == plain)

        // The underlying row's payload must NOT match the plaintext —
        // it has to be the version-tagged ciphertext blob.
        let rawPayload = try await rawPayload(forId: id, in: container)
        #expect(rawPayload != plain)
        #expect(rawPayload.first == OutboxPayloadCipher.versionTag)
        #expect(OutboxPayloadCipher.isCiphertext(rawPayload))
    }

    @Test("Legacy plaintext row is migrated on read — next snapshot is ciphertext on disk")
    func plaintextMigrationOnRead() async throws {
        let container = try OutboxStore.makeInMemory()
        // Seed a plaintext row through the ModelContainer directly,
        // bypassing the cipher to mimic a pre-v0.6.2 install's outbox.
        let id = UUID()
        let legacyPlaintext = Data(#"{"value":42}"#.utf8)
        try await seedRawRow(
            id: id,
            payload: legacyPlaintext,
            in: container
        )

        let store = OutboxStore(modelContainer: container)
        let stub = StubKeychain()
        await store.useCipher(OutboxPayloadCipher(keychain: stub, keyAccount: "test.outbox.key.g"))

        // First snapshot returns plaintext (the dispatch contract) AND
        // re-encrypts the row in place.
        let snap1 = try await store.snapshot()
        try #require(snap1.count == 1)
        #expect(snap1[0].payload == legacyPlaintext)

        // The underlying row now holds version-tagged ciphertext.
        let raw = try await rawPayload(forId: id, in: container)
        #expect(OutboxPayloadCipher.isCiphertext(raw))
        #expect(raw != legacyPlaintext)

        // A second snapshot still returns plaintext but reads via decrypt.
        let snap2 = try await store.snapshot()
        try #require(snap2.count == 1)
        #expect(snap2[0].payload == legacyPlaintext)
    }

    // MARK: - Helpers

    /// Reads the raw on-disk `payload` bytes for a given row id, without
    /// going through `OutboxStore.snapshot()` (which decrypts).
    @MainActor
    private func rawPayload(forId id: UUID, in container: ModelContainer) throws -> Data {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<OutboxOperation>(
            predicate: #Predicate { $0.id == id }
        )
        guard let row = try context.fetch(descriptor).first else {
            Issue.record("Row \(id) not found in container")
            return Data()
        }
        return row.payload
    }

    /// Seeds a raw row directly via a fresh `ModelContext` — used to
    /// stage the legacy-plaintext fixture.
    @MainActor
    private func seedRawRow(id: UUID, payload: Data, in container: ModelContainer) throws {
        let context = ModelContext(container)
        let op = OutboxOperation(
            id: id,
            kindRaw: OutboxQueue.Operation.Kind.createMeasurement.rawValue,
            payload: payload,
            idempotencyKey: UUID().uuidString.lowercased(),
            createdAt: .now
        )
        context.insert(op)
        try context.save()
    }
}

// MARK: - Stub keychain (in-process, no SecItem round-trip)

/// In-memory `KeychainStoring` for unit tests. Mirrors the
/// `KeychainStore` semantics needed by `OutboxPayloadCipher`:
/// upsert + opaque lookup. Not Sendable-needed for the test harness,
/// but marked anyway so the cipher's `Sendable` claim doesn't
/// blink at strict-concurrency.
final class StubKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]

    func setString(_ value: String, forKey key: String) throws {
        try setData(Data(value.utf8), forKey: key)
    }

    func getString(forKey key: String) -> String? {
        guard let data = getData(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setData(_ data: Data, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        store[key] = data
    }

    func getData(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    func remove(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key)
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
    }
}
