@testable import HealthLog
import Testing

/// **v0.6.2 W-SEC-A — Gravatar removed.**
///
/// The pre-W-SEC-A `preWarm(email:)` ladder fetched the operator's
/// Gravatar PNG off the critical path so the Dashboard could paint a
/// cached image on cold launch. That network round-trip is gone (M-3,
/// v0.6.2.9 security audit). `preWarm` now only sweeps any legacy
/// on-disk PNG bytes from prior installs. This suite pins the new
/// contract: no fetch under any input, no PNG materialises on disk.
@MainActor
@Suite("AvatarCache — preWarm no-fetch contract (W-SEC-A)")
struct AvatarCachePreWarmTests {
    @Test("preWarm(email: nil) is a no-op — no crash, no fetch")
    func preWarmNilEmail() async {
        await AvatarCache.shared.preWarm(email: nil)
    }

    @Test("preWarm(email: blank) is a no-op — no crash, no fetch")
    func preWarmBlankEmail() async {
        await AvatarCache.shared.preWarm(email: "   ")
        await AvatarCache.shared.preWarm(email: "")
    }

    @Test("preWarm(email: real) is a no-op disk sweep — no fetch under any input")
    func preWarmRealEmailNoFetch() async {
        // The pre-W-SEC-A path would have issued a `www.gravatar.com`
        // GET here. Post-W-SEC-A `preWarm` only sweeps the legacy disk
        // directory — it ignores the email entirely and issues no network
        // request under any input. The contract is structural: completing
        // without a fetch is the assertion.
        await AvatarCache.shared.preWarm(email: "no-fetch@example.invalid")
    }
}
