import CryptoKit
import Foundation

/// **v0.6.2 W-SEC-A (M-4).** AES-GCM round-trip helper for the SwiftData
/// `OutboxOperation.payload` blob.
///
/// ## Why this exists
///
/// Pre-v0.6.2 the outbox stored `payload` plaintext: every queued POST/PUT
/// body landed verbatim in `<sandbox>/Library/Application Support/HealthLog/
/// Outbox/outbox.sqlite`. The SQLite file has
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`-equivalent file
/// protection (`completeUntilFirstUserAuthentication`) so it's unreadable
/// before first unlock — but **after** first unlock the bytes are
/// readable to anyone with file-system access (jailbreak, forensic
/// extraction, backup-restore-to-attacker-device when device password is
/// known). For an outbox that can hold free-text health notes
/// ("Kopfschmerzen seit drei Tagen, sexuell aktiv mit X, …"),
/// at-rest encryption is the right defense-in-depth ladder.
///
/// W-SEC-A wraps the payload in AES-GCM with a per-payload random nonce.
/// The 256-bit key lives in the Keychain at
/// `KeychainKey.outboxPayloadKey` with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — matches the
/// SQLite file's own protection class, so BGProcessingTask wakeups on a
/// locked-but-unlocked-since-boot device can still decrypt and replay.
///
/// ## On-disk format
///
/// Each ciphertext blob is laid out as:
///
/// ```
/// byte 0      : version tag (0x02)
/// bytes 1..12 : AES-GCM nonce (12 bytes, random per payload)
/// bytes 13..N : AES-GCM ciphertext + 16-byte tag (CryptoKit combined)
/// ```
///
/// The version tag `0x02` was chosen because every legacy plaintext
/// payload is JSON — starts with `{` (0x7B), `[` (0x5B), or whitespace
/// (`{ ` after pretty-print, leading ASCII 0x20). `0x02` is an
/// unprintable control byte (`STX`) that no JSON encoder we use would
/// emit at offset zero. The discriminator is therefore unambiguous and
/// the migration path (read plaintext → re-encrypt + persist) is safe
/// against false positives.
///
/// ## Threading
///
/// The cipher is a value type and is `Sendable`. Key fetching from the
/// Keychain serialises through `KeychainStore` which is itself
/// `Sendable`. Per-call `SymmetricKey` allocations stay on the calling
/// thread.
///
/// **v0.7.0 W-SEC-M-4 fix:** first-call concurrent access used to race
/// inside `fetchOrCreateKey()`. Two writers entering before any key was
/// persisted would each generate their own random key, each call
/// `setData`, and the second call's `SecItemDelete` + `SecItemAdd` would
/// silently overwrite the first key — leaving the first writer's
/// ciphertext blob mathematically undecryptable for the rest of the
/// install. The fix is a process-wide `NSLock` (`Self.firstCallLock`)
/// that serialises the read-or-create branch. Re-entries after the key
/// is persisted bypass the lock-fast path (`getData` is cheap + lock-
/// free relative to other readers) — the lock is only contested on the
/// very first call.
public struct OutboxPayloadCipher: Sendable {
    /// Discriminator byte at offset 0 of an encrypted payload. Picked
    /// deliberately to fall outside the plaintext JSON byte range
    /// (see file-level docs).
    public static let versionTag: UInt8 = 0x02

    /// Keychain account under which the per-install AES-GCM key lives.
    /// Mirrored as `KeychainKey.outboxPayloadKey` (v0.6.2.3 F3-SEC) so
    /// the logout + account-deletion paths can wipe the key by name
    /// without taking a dependency on this type from the `Stores/` layer.
    /// Drift between the two constants would strand ciphertext rows
    /// undecryptable while leaving the key persisted, so they are
    /// intentionally identical string literals — pinned by
    /// `OutboxKeychainKeyAlignmentTests`.
    public static let defaultKeyAccount = KeychainKey.outboxPayloadKey

    private let keychain: any KeychainStoring
    private let keyAccount: String

    /// Process-wide lock that guards the first-call read-or-create branch
    /// in `fetchOrCreateKey()`. `NSLock` is `Sendable` on Apple platforms
    /// (documented and assumed by `Foundation`) so this static is safe
    /// under strict concurrency.
    ///
    /// **Why not actor-isolate the whole type?** The cipher is invoked
    /// from the SwiftData `@ModelActor` writer context. Hopping to a
    /// dedicated actor for each encrypt/decrypt would push every payload
    /// through an additional executor jump, which adds noticeable latency
    /// to the BGProcessingTask replay loop. A static `NSLock` keeps the
    /// hot path lock-free after the first call has persisted the key.
    private static let firstCallLock = NSLock()

    public init(
        keychain: any KeychainStoring = KeychainStore(),
        keyAccount: String = OutboxPayloadCipher.defaultKeyAccount
    ) {
        self.keychain = keychain
        self.keyAccount = keyAccount
    }

    // MARK: - Round-trip

    /// Encrypts `plaintext` with the persisted key (generating one on
    /// first use). Output is a self-contained blob: `[0x02 | 12-byte
    /// nonce | ciphertext+tag]`. Throws on key-fetch / Keychain failure
    /// or on the (vanishingly unlikely) AES-GCM seal failure.
    public func encrypt(_ plaintext: Data) throws -> Data {
        let key = try fetchOrCreateKey()
        let sealed = try AES.GCM.seal(plaintext, using: key)
        // `combined` is `nonce(12) || ciphertext || tag(16)`. We prepend
        // the version tag so the read path can discriminate plaintext
        // vs ciphertext deterministically.
        guard let combined = sealed.combined else {
            throw CipherError.sealFailed
        }
        var out = Data(capacity: combined.count + 1)
        out.append(Self.versionTag)
        out.append(combined)
        return out
    }

    /// Decrypts a blob produced by `encrypt(...)`. Throws if the blob is
    /// truncated, has a bad tag, or the Keychain key is missing.
    public func decrypt(_ ciphertext: Data) throws -> Data {
        guard !ciphertext.isEmpty, ciphertext[ciphertext.startIndex] == Self.versionTag else {
            throw CipherError.unrecognizedFormat
        }
        let body = ciphertext.dropFirst()
        let key = try fetchOrCreateKey()
        let box = try AES.GCM.SealedBox(combined: body)
        return try AES.GCM.open(box, using: key)
    }

    /// `true` when the blob carries the W-SEC-A version tag, `false`
    /// when it's still pre-encryption plaintext. Used by the read path
    /// to drive lazy migration without touching `decrypt(...)`.
    public static func isCiphertext(_ blob: Data) -> Bool {
        guard let first = blob.first else { return false }
        return first == versionTag
    }

    // MARK: - Key management

    /// Returns the persisted 256-bit symmetric key, generating + persisting
    /// one on first use.
    ///
    /// **Concurrency contract (v0.7.0 W-SEC-M-4):** two writers entering
    /// this method simultaneously *before* a key has been persisted used
    /// to each call `SymmetricKey(size: .bits256)` and each call
    /// `keychain.setData(...)`. Because `KeychainStore.setData` does
    /// `SecItemDelete` then `SecItemAdd`, whichever writer landed second
    /// would silently overwrite the first writer's key — and the first
    /// writer's `encrypt(...)` had already sealed a ciphertext blob with
    /// the now-overwritten key. That blob was undecryptable for the rest
    /// of the install lifetime: a payload loss under contention.
    ///
    /// The fix is a process-wide `NSLock` around the read-or-create
    /// branch with a double-check: the fast path stays lock-free for
    /// every subsequent call (the persisted key is read straight back
    /// from the Keychain), the lock is only ever contested on the very
    /// first call after install / re-sign-in (when the
    /// `localCleanupHook` wipes the key, see
    /// `AppContainer+Logout.handleLocalLogout`).
    ///
    /// The key is stored under
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (the default in
    /// `KeychainStore.setData`) so that:
    ///   * The key never leaves the device (no iCloud Keychain sync).
    ///   * After first unlock the BGProcessingTask wake-ups can still
    ///     fetch + decrypt — the outbox replay runs on those wakeups.
    ///   * Before first unlock no decrypt happens, but neither does the
    ///     SwiftData file open: the Outbox SQLite has matching protection
    ///     (`completeUntilFirstUserAuthentication`), so the two readiness
    ///     gates align.
    public func fetchOrCreateKey() throws -> SymmetricKey {
        // Fast path — already persisted. Lock-free read.
        if let existing = keychain.getData(forKey: keyAccount), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        // Slow path — serialise the read-or-create branch. Second
        // entrant re-checks the keychain under the lock and returns the
        // first entrant's persisted key, so only one random key is ever
        // generated per install.
        Self.firstCallLock.lock()
        defer { Self.firstCallLock.unlock() }
        if let existing = keychain.getData(forKey: keyAccount), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        // First-use: generate a fresh 256-bit random key via the system
        // CSPRNG. `SymmetricKey(size:)` defers to `SecRandomCopyBytes` /
        // `CCRandomGenerateBytes` under the hood, so we don't reach for
        // SecRandomCopyBytes ourselves.
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try keychain.setData(keyData, forKey: keyAccount)
        return key
    }

    public enum CipherError: Error, Sendable, Equatable {
        case sealFailed
        case unrecognizedFormat
    }
}
