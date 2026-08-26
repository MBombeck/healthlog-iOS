@testable import HealthLog
import Testing

/// **v0.6.2 W-SEC-A — Gravatar removed.**
///
/// `AvatarCache` is reduced to a disk-only migration shim post-W-SEC-A: it
/// sweeps any legacy on-disk PNG bytes from pre-v0.6.2 installs and clears
/// on logout, but never fetches a new image. The v0.7.1 cleanup dropped the
/// dead `loadImmediate` / `isStale` / `store` source-compat surface. This
/// suite pins the surviving clear contract.
@MainActor
@Suite("AvatarCache — migration shim (W-SEC-A)")
struct AvatarCacheTests {
    @Test("clearAll() succeeds without error — used by logout cascade")
    func clearAllSucceeds() async {
        // Logout / account-deletion paths call this unconditionally;
        // it must remain non-throwing + idempotent post-W-SEC-A.
        await AvatarCache.shared.clearAll()
        await AvatarCache.shared.clearAll()
    }
}
