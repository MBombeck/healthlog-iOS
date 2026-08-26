// Diese Suite hängt an `AppContainer` (App-Target-only) — im SPM-Library-Build
// gibt es weder AppContainer noch AIConsentStore. Der Consent-Wipe wird
// ausschließlich aus dem iOS-App-Target getriggert.
#if !SWIFT_PACKAGE

    import Foundation
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif
    @testable import HealthLog

    /// **v0.12 W1 (security finding W1-1, Apple 5.1.2(i)) — AI-consent grant
    /// hygiene on logout / account-deletion / server-switch.**
    ///
    /// Pre-v0.12 the logout cascade wiped tokens + temp PHI PDFs + the outbox
    /// cipher key but left the per-provider `ai-consent.<provider>` Keychain
    /// grants intact on EVERY path. On a shared device, User B signing in after
    /// User A signed out inherited User A's granted consent → User B's health
    /// data would be transmitted off-device to the LLM provider without User B
    /// ever consenting. That is a hard 5.1.2(i) violation (consent must be
    /// per-user, informed, before first transmission).
    ///
    /// The fix revokes consent for every real provider in
    /// `performFullLocalLogout` on ALL reasons (consent is strictly
    /// per-signed-in-user; even a same-account `.userInitiated` /
    /// `.tokenExpired` sign-out must drop it). `AuthService.deleteAccount`
    /// mirrors the wipe on its direct keychain teardown as defence-in-depth.
    ///
    /// These tests pin the grant lifecycle at every logout reason so the
    /// regression can't land silently in a future cascade refactor.
    @MainActor
    @Suite("AI consent logout / account-deletion wipe")
    struct AIConsentLogoutWipeTests {
        @Test(
            "performFullLocalLogout clears AI consent for every reason",
            arguments: [LogoutReason.userInitiated, .tokenExpired, .accountDeleted, .switchServer]
        )
        func logoutClearsConsent(reason: LogoutReason) async throws {
            let keychain = InMemoryKeychain()
            let container = try AppContainer(
                environment: testEnvironment(),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )

            // Grant consent for two real providers + leave a decline marker on
            // a third — the shape a real signed-in user with prior AI use has.
            container.aiConsentStore.grant(for: .anthropic)
            container.aiConsentStore.grant(for: .openai)
            container.aiConsentStore.decline(for: .local)

            #expect(container.aiConsentStore.hasConsent(for: .anthropic))
            #expect(container.aiConsentStore.hasConsent(for: .openai))
            #expect(container.aiConsentStore.isAnyProviderGranted())
            // Raw-keychain sanity: the grant + declined entries are actually
            // persisted at the documented account prefixes.
            #expect(keychain.getString(forKey: AIConsentStore.keyPrefix + "anthropic") == "granted")
            #expect(keychain.getString(forKey: AIConsentStore.declinedKeyPrefix + "local") != nil)

            await container.performFullLocalLogout(reason: reason)

            // No real provider may retain consent after ANY logout reason.
            for provider in AIProvider.allCases where provider != .unconfigured {
                #expect(
                    !container.aiConsentStore.hasConsent(for: provider),
                    "consent for \(provider.rawValue) survived \(reason)"
                )
                #expect(keychain.getString(forKey: AIConsentStore.keyPrefix + provider.rawValue) == nil)
                #expect(keychain.getString(forKey: AIConsentStore.declinedKeyPrefix + provider.rawValue) == nil)
            }
            #expect(!container.aiConsentStore.isAnyProviderGranted())
            // aiMode must collapse to .none — no off-device path remains open.
            #expect(container.aiConsentStore.aiMode == .none)
        }

        @Test("performFullLocalLogout is idempotent when no consent was granted")
        func logoutWithoutConsentIsNoOp() async throws {
            let keychain = InMemoryKeychain()
            let container = try AppContainer(
                environment: testEnvironment(),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )

            #expect(!container.aiConsentStore.isAnyProviderGranted())
            await container.performFullLocalLogout(reason: .userInitiated)
            #expect(!container.aiConsentStore.isAnyProviderGranted())
        }

        // MARK: - Helpers

        private func testEnvironment() throws -> AppEnvironment {
            AppEnvironment(
                baseURL: URL(string: "https://example.invalid"),
                bundleID: "dev.healthlog.app.tests",
                appVersion: "0.0.0-test",
                buildNumber: "0"
            )
        }
    }

#endif // !SWIFT_PACKAGE
