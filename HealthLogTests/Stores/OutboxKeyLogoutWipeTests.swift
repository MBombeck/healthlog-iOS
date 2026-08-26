// Diese Suite hängt an `AppContainer` (App-Target-only). Im SPM-Library-Build
// gibt es weder AppContainer noch das KeychainKey.outboxPayloadKey-Constant,
// also überspringen wir das File hier — der Wipe wird ausschließlich aus dem
// iOS-App-Target getriggert.
#if !SWIFT_PACKAGE

    import Foundation
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif
    @testable import HealthLog

    /// **v0.6.2.3 F3-SEC (A-SEC NEW-M-1) — outbox AES-GCM key hygiene.**
    ///
    /// Pre-v0.6.2.3 the per-install outbox-payload key
    /// (`KeychainKey.outboxPayloadKey`) survived both `handleLocalLogout()`
    /// and the account-deletion `localCleanupHook`. A second user signing
    /// in on the same device then inherited the previous user's cipher —
    /// any leftover ciphertext row (eg. a stalled BG-replay row that wrote
    /// pre-401) decrypted under the new session, leaking the predecessor's
    /// queued payload into the new account's outbox dispatcher.
    ///
    /// **v0.7.1 C-1 correction.** The wipe was over-broad: every logout
    /// path wiped the key, but only some paths *also* clear the encrypted
    /// outbox rows. The key wipe is now gated on the SAME `clearsOutbox`
    /// flag as the row clear so the two always move together:
    ///
    /// - `.userInitiated` / `.tokenExpired` KEEP rows + key — same account,
    ///   same server, so a re-login replays pending optimistic writes.
    ///   Wiping the key while keeping the rows would strand them
    ///   undecryptable and `OutboxStore.snapshot()` would drop them.
    /// - `.accountDeleted` CLEARS rows + key — the rows point at a deleted
    ///   account.
    /// - `.switchServer` CLEARS rows + key — the queued writes were minted
    ///   against the previous server and must not replay against the new
    ///   host (`SettingsServerScreen.commit()` re-points at a different
    ///   server). Outbox-wise it belongs with account-deletion, not with
    ///   the same-account row-preserving paths.
    ///
    /// These tests pin the key lifecycle at every call site so the
    /// regression (in either direction — orphaned rows OR a leaked key)
    /// can't land silently in a future logout/account-deletion refactor.
    @MainActor
    @Suite("OutboxPayloadKey logout + account-deletion wipe")
    struct OutboxKeyLogoutWipeTests {
        // MARK: - Key alignment (cheap unit pin)

        /// Two literals declare the same Keychain account: the runtime
        /// constant the cipher reads (`OutboxPayloadCipher.defaultKeyAccount`)
        /// and the symbolic one the logout/account-deletion paths wipe
        /// (`KeychainKey.outboxPayloadKey`). Drift between them would
        /// strand ciphertext rows undecryptable while leaving the actual
        /// persisted key in place — pin the equality here so a typo in
        /// either site fails fast at build-test time.
        @Test("KeychainKey.outboxPayloadKey is the cipher's default account")
        func keyAccountAlignment() {
            #expect(KeychainKey.outboxPayloadKey == OutboxPayloadCipher.defaultKeyAccount)
            #expect(KeychainKey.outboxPayloadKey == "outbox.payload.key")
        }

        // MARK: - Same-account row-preserving logout KEEPS the key (v0.7.1 C-1)

        @Test("performFullLocalLogout(.userInitiated) keeps the outbox-payload key")
        func userInitiatedLogoutKeepsOutboxKey() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setData(Data(repeating: 0xAB, count: 32), forKey: KeychainKey.outboxPayloadKey)

            let container = try AppContainer(
                environment: testEnvironment(),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )

            await container.performFullLocalLogout(reason: .userInitiated)

            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) != nil)
        }

        @Test("performFullLocalLogout(.tokenExpired) keeps the outbox-payload key")
        func tokenExpiredLogoutKeepsOutboxKey() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setData(Data(repeating: 0xAB, count: 32), forKey: KeychainKey.outboxPayloadKey)

            let container = try AppContainer(
                environment: testEnvironment(),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )

            await container.performFullLocalLogout(reason: .tokenExpired)

            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) != nil)
        }

        // MARK: - Outbox-clearing logout DROPS the key (v0.7.1 C-1)

        @Test("handleLocalLogout() (.switchServer) drops the outbox-payload key")
        func switchServerLogoutWipesOutboxKey() async throws {
            let keychain = InMemoryKeychain()
            // Seed the key the way `OutboxPayloadCipher.fetchOrCreateKey`
            // would, plus auth bundle bytes so the surrounding wipes have
            // something realistic to observe.
            try keychain.setData(Data(repeating: 0xAB, count: 32), forKey: KeychainKey.outboxPayloadKey)
            try keychain.setString("bearer-fixture", forKey: KeychainKey.authToken)

            let container = try AppContainer(
                environment: testEnvironment(),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )

            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) != nil)

            // `.switchServer` clears the encrypted outbox rows (they were
            // minted against the previous server), so the key that decrypts
            // them is wiped in lockstep — no orphaned rows, no leaked key
            // into the new host's session.
            await container.handleLocalLogout()

            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) == nil)
        }

        @Test("performFullLocalLogout(.accountDeleted) drops the outbox-payload key")
        func accountDeletedLogoutWipesOutboxKey() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setData(Data(repeating: 0xAB, count: 32), forKey: KeychainKey.outboxPayloadKey)

            let container = try AppContainer(
                environment: testEnvironment(),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )

            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) != nil)

            // Account-deletion clears the rows AND the key together, so the
            // cross-user leakage defense the original wipe provided is intact.
            await container.performFullLocalLogout(reason: .accountDeleted)

            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) == nil)
        }

        @Test("performFullLocalLogout(.accountDeleted) is idempotent when no key is present")
        func accountDeletedLogoutWithoutKeyIsNoOp() async throws {
            let keychain = InMemoryKeychain()
            let container = try AppContainer(
                environment: testEnvironment(),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )

            // Must not throw / crash even when the key was never persisted.
            await container.performFullLocalLogout(reason: .accountDeleted)

            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) == nil)
        }

        // MARK: - Account-deletion cleanup-hook wipe

        @Test("AuthStore.localCleanupHook drops the outbox-payload key on account-deletion")
        func accountDeletionWipesOutboxKey() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setData(Data(repeating: 0xCD, count: 32), forKey: KeychainKey.outboxPayloadKey)

            let container = try AppContainer(
                environment: testEnvironment(),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )

            // `AppContainer.init` wires `authStore.localCleanupHook` to the
            // closure that wipes server-stats + outbox + Keychain key. We
            // invoke it directly here — that's the same path `AuthStore.
            // deleteAccount()` takes after the server-side DELETE returns
            // 2xx. (We don't drive the full deleteAccount flow because
            // that requires a live API client; the hook is the unit under
            // test for this regression.)
            let hook = try #require(container.authStore.localCleanupHook)
            await hook()

            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) == nil)
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
