import CryptoKit
import Foundation
@testable import HealthLog
import Testing

/// **v0.7.0 W-SEC-M-4 — OutboxPayloadCipher first-call race.**
///
/// Pins the contract that two writers entering `fetchOrCreateKey()`
/// simultaneously *before* any key has been persisted must each end up
/// holding **the same** key — not two random keys with whichever one
/// landed in the Keychain last winning.
///
/// Pre-fix bug: `KeychainStore.setData` does `SecItemDelete` +
/// `SecItemAdd`, so two parallel `fetchOrCreateKey()` calls each
/// generated a random key, each persisted it, and the second persist
/// wiped the first persist. The first writer's already-sealed
/// ciphertext blob then decrypted with `SecItemCopyMatching` → got the
/// second writer's key → AES-GCM tag mismatch → blob lost forever.
///
/// The fix is the static `firstCallLock` `NSLock` added to
/// `OutboxPayloadCipher`. This test would have failed deterministically
/// against the pre-fix code on a multicore device, and now passes.
@Suite("OutboxPayloadCipher — concurrent first-call key invariant (W-SEC-M-4)")
struct OutboxPayloadCipherRaceTests {
    /// **Invariant:** N parallel first-call `encrypt` operations against a
    /// single `OutboxPayloadCipher` instance must all round-trip
    /// successfully through `decrypt`. If any encrypt-then-decrypt
    /// returns a tag-mismatch error, the first-call race has re-emerged.
    ///
    /// We spawn 16 concurrent `Task`s — high enough to virtually
    /// guarantee contention on any multicore simulator/host, low enough
    /// to keep the test under 200 ms.
    @Test("16 concurrent first-call encrypts all decrypt under a shared cipher")
    func concurrentFirstCallProducesOneStableKey() async throws {
        // Tracked-keychain stub: counts how many distinct keys land in
        // the Keychain. With the lock, exactly one. Without the lock,
        // potentially up to N.
        let stub = RaceTrackingKeychain()
        let cipher = OutboxPayloadCipher(
            keychain: stub,
            keyAccount: "test.outbox.key.race"
        )

        let writerCount = 16
        let plaintexts: [Data] = (0 ..< writerCount).map { idx in
            Data(#"{"writer":\#(idx),"value":\#(idx * 7)}"#.utf8)
        }

        // Encrypt phase — parallel TaskGroup.
        let ciphertexts: [Data] = try await withThrowingTaskGroup(
            of: (Int, Data).self
        ) { group in
            for (idx, payload) in plaintexts.enumerated() {
                group.addTask {
                    let blob = try cipher.encrypt(payload)
                    return (idx, blob)
                }
            }
            var collected: [(Int, Data)] = []
            for try await pair in group {
                collected.append(pair)
            }
            collected.sort { $0.0 < $1.0 }
            return collected.map(\.1)
        }

        // Decrypt phase — sequential, after the dust has settled. If
        // any writer's blob is undecryptable, the race has re-emerged.
        for (idx, blob) in ciphertexts.enumerated() {
            let recovered = try cipher.decrypt(blob)
            #expect(recovered == plaintexts[idx], "writer \(idx) blob did not round-trip — key race regression")
        }

        // Stronger structural assertion — exactly one key landed in the
        // Keychain. Without the lock, you'd see `setDataCallCount` equal
        // to the number of writers that hit the slow path (1..N). With
        // the lock, exactly one write because the second entrant
        // returns under the double-check.
        #expect(
            stub.setDataCallCount == 1,
            "setData called \(stub.setDataCallCount) times — first-call race re-emerged"
        )
        #expect(
            stub.distinctKeysSeen.count == 1,
            "Keychain saw \(stub.distinctKeysSeen.count) distinct keys — first-call race re-emerged"
        )
    }
}

// MARK: - Race-tracking keychain stub

/// Specialised stub for the W-SEC-M-4 race test — wraps `StubKeychain`'s
/// `NSLock`-protected dictionary semantics but additionally records:
///  * `setDataCallCount` — total writes (regression signal).
///  * `distinctKeysSeen` — every distinct key value that was ever
///    persisted (regression signal).
///
/// The wrapped store still does upsert-semantics (overwrite on every
/// `setData`), faithful to the production `KeychainStore.setData`
/// behaviour so the pre-fix code path would actually corrupt the key.
final class RaceTrackingKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    private var _setDataCallCount = 0
    private var _distinctKeysSeen: Set<Data> = []

    var setDataCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _setDataCallCount
    }

    var distinctKeysSeen: Set<Data> {
        lock.lock()
        defer { lock.unlock() }
        return _distinctKeysSeen
    }

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
        _setDataCallCount += 1
        _distinctKeysSeen.insert(data)
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
