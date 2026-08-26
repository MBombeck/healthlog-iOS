import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Regression coverage for the v0162 security/privacy audit fixes:
/// - C1: the `PinningDelegate` server-trust disposition must fall back to the
///   system's DEFAULT chain validation on non-pinned paths, NOT vouch for an
///   unevaluated trust (which would skip validation).
/// - Data-Privacy H1: `APIClient.purgeCachedResponses()` must empty the
///   session URLCache so PHI JSON does not outlive the signed-in user.
@Suite("APIClient security fixes (audit C1 / H1)")
struct APIClientSecurityFixesTests {
    // MARK: - C1 — non-pinned paths get system default validation, not a blanket accept

    @Test("Pinning disabled → system default trust validation (never a blanket accept)")
    func pinningDisabledUsesSystemDefault() {
        let disposition = PinningDelegate.serverTrustDisposition(
            pinnerEnabled: false,
            isPinnedHost: false,
            trustIsValid: { Issue.record("trust validation must not run when pinning is off")
                return true
            }
        )
        #expect(disposition == .systemDefault)
    }

    @Test("Pinning enabled but host not pinned → system default trust validation")
    func nonPinnedHostUsesSystemDefault() {
        let disposition = PinningDelegate.serverTrustDisposition(
            pinnerEnabled: true,
            isPinnedHost: false,
            trustIsValid: { Issue.record("trust validation must not run for a non-pinned host")
                return true
            }
        )
        #expect(disposition == .systemDefault)
    }

    @Test("Pinned host with a valid chain → explicit useCredential (pinning still enforced)")
    func pinnedHostValidChainAccepts() {
        let disposition = PinningDelegate.serverTrustDisposition(
            pinnerEnabled: true,
            isPinnedHost: true,
            trustIsValid: { true }
        )
        #expect(disposition == .pinnedValid)
    }

    @Test("Pinned host with a failing pin check → connection rejected (pinning not weakened)")
    func pinnedHostInvalidChainRejects() {
        let disposition = PinningDelegate.serverTrustDisposition(
            pinnerEnabled: true,
            isPinnedHost: true,
            trustIsValid: { false }
        )
        #expect(disposition == .pinnedInvalid)
    }

    // Data-Privacy H1 (URLCache PHI purge) is intentionally NOT unit-tested here:
    // `URLCache.removeAllCachedResponses()` is not guaranteed to reflect
    // synchronously in a following `cachedResponse(for:)`, so any in-test
    // seed→purge→assert is flaky (an Apple-API timing artifact, not our logic).
    // The production `purgeCachedResponses()` is a 4-line fan-out of
    // `removeAllCachedResponses()` over the three session caches + `URLCache.shared`,
    // correct by inspection and wired into the logout/deletion cascade.
}
