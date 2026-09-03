@testable import HealthLog
import Testing

/// Build 272 — the "Sign in with Passkey" primary CTA must only be offered
/// where the native ceremony can actually run. In the distributed build no
/// relying-party host is configured, so every server is "self-hosted" for the
/// passkey seam; a primary button whose tap only re-reveals an already open
/// password form reads as a broken control to a reviewer.
@Suite("Sign-in step — passkey CTA visibility")
struct PasskeyCTAVisibilityTests {
    @Test("no passkey CTA on a host the app cannot assert a passkey for")
    func hiddenWhenUnsupported() {
        let v = AuthStepFormVisibility(
            prefersWebHandoff: false, availability: .unavailable, latched: false, passkeySupported: false
        )
        #expect(v.showsPasskeyCTA == false)
        #expect(v.showsEmailSection == true)
    }

    @Test("passkey CTA on a supported host without a web handoff")
    func shownWhenSupported() {
        let v = AuthStepFormVisibility(
            prefersWebHandoff: false, availability: .unavailable, latched: false, passkeySupported: true
        )
        #expect(v.showsPasskeyCTA == true)
    }

    @Test("a live web-handoff CTA replaces the passkey CTA even on a supported host")
    func handoffReplacesPasskey() {
        let v = AuthStepFormVisibility(
            prefersWebHandoff: true, availability: .available, latched: false, passkeySupported: true
        )
        #expect(v.showsPasskeyCTA == false)
        #expect(v.showsWebHandoffCTA == true)
    }
}
