import Foundation

/// **v0.5.5 W-UX-1 → v0.6.2 W-SEC-A (Gravatar removed).**
///
/// Earlier revisions persisted the operator's Gravatar PNG under
/// `<sandbox>/Library/Caches/dev.healthlog.app/avatars/<emailHash>.png`
/// so the Dashboard's inline header + Profile-screen hero could paint a
/// cached image on cold launch. That ladder is gone — `HLProfileAvatar`
/// now renders initials unconditionally and never issues a third-party
/// network request (M-3 finding, v0.6.2.9 security audit).
///
/// This class survives as a **disk-only migration shim**:
///
/// - `preWarm(email:sizePx:)` no longer fetches anything; instead it
///   sweeps the legacy `avatars/` directory on cold launch so any PNG
///   left over from a prior install (pre-v0.6.2 cache) lands in the OS
///   reclaim pool. One-shot, idempotent.
/// - `clearAll()` retains its account-deletion / logout contract: wipes
///   any residual disk slot. Still wired from `performFullLocalLogout`.
///
/// **v0.7.1 cleanup** — the `loadImmediate` / `isStale` / `store` /
/// `staleAfter` / `hardEvictAfter` source-compat surface was dead (only
/// tests read it) and removed; the type is the legacy disk sweep + clear
/// only. No data leaves the device from any code path on this type.
public final class AvatarCache: @unchecked Sendable {
    public static let shared = AvatarCache()

    private let fileManager = FileManager.default
    private let lock = NSLock()

    /// **v0.8.0 W11 — in-memory self-hosted avatar bytes.**
    ///
    /// The Gravatar removal (W-SEC-A) left this type as a disk-sweep shim.
    /// W11 brings a real avatar back — served from the OWN authenticated,
    /// owner-scoped endpoint — so we re-introduce a cache. It is
    /// deliberately **in-memory only** (no disk write): the bytes are
    /// PHI-adjacent, so keeping them off the disk avoids a residue file
    /// that would outlive a crash-during-logout. RAM is wiped on process
    /// exit, and `clearAll()` (already wired into every logout path via
    /// `performFullLocalLogout`) drops it on sign-out so a re-login as a
    /// different user never inherits the previous photo.
    ///
    /// Keyed by the cache-busting URL string (`/api/user/avatar/{id}?v=<ms>`)
    /// so a re-upload — which flips `?v=` — misses the cache and refetches,
    /// while a stable URL hits. Single-entry: only one signed-in user has an
    /// avatar at a time, and a flipped key supersedes the old one.
    private var memoryEntry: (key: String, bytes: Data)?

    private init() {}

    // MARK: - In-memory avatar bytes (W11)

    /// Returns the cached bytes for `key` (the `?v=`-suffixed avatar URL) or
    /// `nil` on a miss / superseded key.
    public func cachedBytes(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = memoryEntry, entry.key == key else { return nil }
        return entry.bytes
    }

    /// Stores `bytes` under `key`, replacing any prior entry (a re-upload
    /// flips `?v=` so the previous key is dropped, not accumulated).
    public func storeBytes(_ bytes: Data, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        memoryEntry = (key, bytes)
    }

    // MARK: - Migration sweep (cold-launch)

    /// **W-SEC-A migration sweep.** Removes any legacy PNG bytes that a
    /// pre-v0.6.2 install left behind under
    /// `<sandbox>/Library/Caches/dev.healthlog.app/avatars/`. Idempotent —
    /// safe to call on every cold launch. The `email` / `sizePx`
    /// parameters are accepted for source-compatibility with the old
    /// `preWarm(email:)` call site (`AppContainer.preWarmAvatarOnLaunch`)
    /// but the email is intentionally **not** read — no hashing, no
    /// network round-trip happens here under any input.
    public func preWarm(email _: String? = nil, sizePx _: Int = 200) async {
        clearDiskSync()
        HLLog.cache.debug("AvatarCache legacy disk sweep complete (no network)")
    }

    // MARK: - Logout sweep

    /// Removes any residual on-disk slot. Invoked from
    /// `AppContainer.handleLocalLogout` so a re-sign-in with a different
    /// email never inherits a stale PNG from a pre-v0.6.2 install.
    public func clearAll() async {
        clearDiskSync()
        clearMemory()
        HLLog.cache.debug("AvatarCache cleared")
    }

    /// Drops the in-memory avatar bytes (W11). Pulled out of `clearAll()` so
    /// it can be exercised directly in tests and reused without the disk
    /// sweep when only the RAM copy needs invalidation.
    public func clearMemory() {
        lock.lock()
        defer { lock.unlock() }
        memoryEntry = nil
    }

    private nonisolated func clearDiskSync() {
        lock.lock()
        defer { lock.unlock() }
        if let dir = Self.cacheDirectory(fileManager: fileManager) {
            try? fileManager.removeItem(at: dir)
        }
    }

    // MARK: - Path resolution

    /// `<sandbox>/Library/Caches/dev.healthlog.app/avatars/`. Retained so
    /// the migration sweep targets the right legacy directory.
    private nonisolated static func cacheDirectory(fileManager: FileManager) -> URL? {
        guard let caches = try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return caches
            .appendingPathComponent("dev.healthlog.app", isDirectory: true)
            .appendingPathComponent("avatars", isDirectory: true)
    }
}
