import Foundation
@testable import HealthLog
import Testing

/// CU-15 (catchup-v134 A5) — the native passkey **enrolment** path is gone.
///
/// `POST /api/auth/passkey/register-options` / `register-verify` are cookie-only
/// plus re-proof-gated since server v1.34.1; a Bearer client can only ever get
/// `401 "Fresh existing-factor proof required"` out of them. The screen now
/// points at the web UI instead, and this suite pins the two properties that
/// make that pointer honest:
///
/// 1. it resolves against the **configured** server, and
/// 2. it lands on `/settings/security`, the section that actually hosts the
///    passkey list on the web (`src/components/settings/security-section`).
///
/// Same contract as `ServerAuthStep`/`SettingsAboutScreen`'s privacy link — see
/// `ServerAuthStepTests` for the sibling cases.
@Suite("Passkeys — web-management link (CU-15)", .serialized)
struct PasskeyManagementWebLinkTests {
    @Test("link resolves against the configured server")
    @MainActor
    func linkUsesConfiguredServer() throws {
        let kc = InMemoryKeychain()
        try kc.setString("https://meinserver.example.com", forKey: KeychainKey.serverURL)
        let url = try #require(PasskeyManagementScreen.webPasskeyManagementURL(keychain: kc))
        #expect(url.host == "meinserver.example.com")
        #expect(url.path == "/settings/security")
    }

    /// Ohne eingerichteten Server gibt es keine Kontoflaeche — der Absprung
    /// entfaellt, statt auf einen erfundenen Host zu zeigen.
    @Test("ohne Server gibt es keinen Absprung")
    @MainActor
    func linkAbsentWithoutServer() {
        #expect(PasskeyManagementScreen.webPasskeyManagementURL(keychain: nil) == nil)
    }

    /// A server URL carrying a trailing slash (the Settings → Server field
    /// accepts one) must not produce a double slash in the path.
    @Test("trailing slash on the configured server does not double up")
    @MainActor
    func trailingSlashIsNormalised() throws {
        let kc = InMemoryKeychain()
        try kc.setString("https://meinserver.example.com/", forKey: KeychainKey.serverURL)
        let url = try #require(PasskeyManagementScreen.webPasskeyManagementURL(keychain: kc))
        #expect(url.path == "/settings/security")
        #expect(!url.absoluteString.contains("//settings"))
    }
}
