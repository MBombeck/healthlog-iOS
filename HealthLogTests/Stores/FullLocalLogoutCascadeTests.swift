// Diese Suite hängt an `AppContainer` (App-Target-only) — im SPM-Library-Build
// gibt es weder AppContainer noch `KeychainKey.outboxPayloadKey`, also wird die
// Datei dort übersprungen. Der Cascade wird ausschließlich aus dem iOS-App-Target
// getriggert.
#if !SWIFT_PACKAGE

    import Foundation
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif
    @testable import HealthLog

    /// **v0.7.0 W-LOGOUT (A-SEC NEW-H-1) — single-source logout cascade.**
    ///
    /// Pre-v0.7.0 only the "switch server" path (`handleLocalLogout()`) ran the
    /// full local teardown. `AuthStore.logout()` (user-tap), the APIClient 401
    /// bridge (`UnauthorizedHandlerRef.invoke`), and the account-deletion
    /// `localCleanupHook` each ran their own slightly different inline cleanup —
    /// and three of the four skipped the outbox AES-GCM key wipe + the
    /// on-device AI caches. A normal sign-out → sign-in on the same device then
    /// leaked previous-user data into the next session.
    ///
    /// `AppContainer.performFullLocalLogout(reason:)` is now the single source
    /// of truth, wired into all four paths. These tests pin that each entry
    /// point triggers the same cascade.
    ///
    /// **Completion signal (v0.7.1 C-1, re-based in 08-06).** The original
    /// suite used the outbox-payload Keychain key as the cascade signal because
    /// every path wiped it. C-1 changed that: the key now follows outbox-row
    /// retention, so `.userInitiated` / `.tokenExpired` deliberately KEEP it
    /// (same account → pending optimistic writes replay on re-login). C-1 then
    /// moved the universal signal onto `LOINCReviewRegistry.reviewerName`,
    /// which 08-06 deleted together with the local clinical-attestation
    /// feature.
    ///
    /// The signal is now `notificationClearOnLogoutHook` — the LOGOUT-NOTIF
    /// seam awaited on the **last line** of `performFullLocalLogout(reason:)`.
    /// That is deliberately a *stronger* statement than the one it replaces,
    /// not an equivalent one: the registry wipe sat in the middle of the
    /// cascade (step 4 of 8), so a cleared reviewer name proved the teardown
    /// had *started* and said nothing about the notification purge, the coach
    /// transcript wipe or the AI-settings box that follow it. A fired tail hook
    /// proves the entry point drove the cascade all the way to its final
    /// statement, so every step the old signal covered is still covered and
    /// four more are covered now.
    ///
    /// The spy **chains** the wired production hook rather than replacing it,
    /// so the real notification/badge purge still runs inside these tests.
    /// `LogoutCompletenessTests+NotifAndTask` also watches this seam, but from
    /// the other side: it calls `performFullLocalLogout(reason:)` directly and
    /// asserts the seam fires exactly once. This suite's distinct claim is that
    /// each of the four *entry points* reaches that cascade at all — the hook
    /// is the observation, the entry point is the subject.
    ///
    /// The outbox-key expectation is asserted PER PATH against the C-1
    /// invariant: kept on `.userInitiated`/`.tokenExpired`, wiped on
    /// `.switchServer`/`.accountDeleted`.
    @MainActor
    @Suite("Full local-logout cascade — all four paths")
    struct FullLocalLogoutCascadeTests {
        // MARK: - Path 1: user-initiated (AuthStore.onPostLogoutHook)

        /// User-tap sign-out routes through `AuthStore.onPostLogoutHook`, which
        /// the Composition-Root wires to `performFullLocalLogout(.userInitiated)`.
        /// We invoke the hook directly (mirroring `OutboxKeyLogoutWipeTests`'
        /// rationale for `localCleanupHook`): driving the full `AuthStore.logout()`
        /// flow needs a live API client, but the hook is the unit under test for
        /// this regression.
        @Test("userInitiated logout runs the cascade and keeps the outbox-payload key")
        func userInitiatedRunsCascade() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setData(Data(repeating: 0xA1, count: 32), forKey: KeychainKey.outboxPayloadKey)
            try keychain.setString("bearer-fixture", forKey: KeychainKey.authToken)

            let container = makeContainer(keychain: keychain)
            let cascade = armCascadeCompletionSignal(container)
            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) != nil)

            let hook = try #require(container.authStore.onPostLogoutHook)
            await hook()

            // Cascade ran to its last line: the universal teardown signal fired.
            #expect(cascade.completions == 1)
            // Same-account sign-out keeps rows → key MUST survive (C-1) so a
            // re-login can decrypt + replay the pending optimistic writes.
            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) != nil)
        }

        // MARK: - Path 2: 401 bridge (UnauthorizedHandlerRef.invoke)

        /// A terminal 401 fires `UnauthorizedHandlerRef.invoke()`, whose handler
        /// the Composition-Root sets to call `AuthStore.handleUnauthorized()`
        /// (phase + auth-bundle wipe) followed by
        /// `performFullLocalLogout(.tokenExpired)`. We drive the ref directly —
        /// that is exactly what `APIClient.onUnauthorized` calls.
        @Test("401 bridge runs the cascade, keeps the outbox key, wipes the auth bundle")
        func tokenExpiredRunsCascade() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setData(Data(repeating: 0xB2, count: 32), forKey: KeychainKey.outboxPayloadKey)
            try keychain.setString("bearer-fixture", forKey: KeychainKey.authToken)

            let container = makeContainer(keychain: keychain)
            let cascade = armCascadeCompletionSignal(container)
            // `handleUnauthorized()` only wipes the auth bundle from an active
            // session phase (.authenticated / .authenticating); drop the test
            // container into `.authenticated` so the bridge takes the full path.
            container.authStore.setPhaseForTesting(
                .authenticated(User(id: "u1", email: nil, username: nil, displayName: nil, createdAt: .now))
            )
            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) != nil)

            await container.unauthorizedRef.invoke()

            // Cascade ran to its last line.
            #expect(cascade.completions == 1)
            // A 401 is a same-account, same-server expiry — rows kept → key
            // MUST survive (C-1) so the writes replay after re-auth.
            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) != nil)
            // The 401 bridge ALSO wipes the auth-bundle via
            // `handleUnauthorized()` — pin that so a future refactor that drops
            // the inline phase-wipe step can't pass silently.
            #expect(keychain.getString(forKey: KeychainKey.authToken) == nil)
        }

        // MARK: - Path 3: account-deletion (AuthStore.localCleanupHook)

        /// Account-deletion runs `localCleanupHook` after the server DELETE
        /// returns 2xx — wired to `performFullLocalLogout(.accountDeleted)`,
        /// which additionally drops the outbox queue + GLP-1 store on top of the
        /// shared cleanup.
        @Test("account-deletion runs the cascade and drops the outbox-payload key")
        func accountDeletedWipesOutboxKey() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setData(Data(repeating: 0xC3, count: 32), forKey: KeychainKey.outboxPayloadKey)

            let container = makeContainer(keychain: keychain)
            let cascade = armCascadeCompletionSignal(container)
            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) != nil)

            let hook = try #require(container.authStore.localCleanupHook)
            await hook()

            #expect(cascade.completions == 1)
            // Account-deletion clears rows AND key together (C-1) — the
            // cross-user leakage defense the original wipe provided is intact.
            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) == nil)
        }

        // MARK: - Path 4: switch-server (handleLocalLogout shim)

        /// The "switch server" path keeps the `handleLocalLogout()` call-site in
        /// `SettingsServerScreen`; the shim forwards to
        /// `performFullLocalLogout(.switchServer)`. Unlike the same-account
        /// paths, switch-server CLEARS the outbox (rows + key): the queued
        /// writes were minted against the previous server and must not replay
        /// against the new host — see `LogoutReason.switchServer` / `.clearsOutbox`.
        @Test("switch-server logout runs the cascade and drops the outbox-payload key")
        func switchServerWipesOutboxKey() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setData(Data(repeating: 0xD4, count: 32), forKey: KeychainKey.outboxPayloadKey)

            let container = makeContainer(keychain: keychain)
            let cascade = armCascadeCompletionSignal(container)
            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) != nil)

            await container.handleLocalLogout()

            #expect(cascade.completions == 1)
            // Re-pointing at a different server clears the old server's queued
            // writes, so the key that decrypts them is wiped in lockstep (C-1
            // invariant: outbox-key retention matches outbox-row retention).
            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) == nil)
        }

        // MARK: - Standalone mirror wipe (v0.11 RISK-2)

        /// **RISK-2 cross-account leak.** The standalone local mirror
        /// (`localRepo`) is the offline history the adopt-upload hook pushes
        /// into whatever account the user next pairs. If it survived a server
        /// switch, the flow standalone → pair A → switch server → standalone →
        /// pair B would adopt-upload A's offline history into B. The
        /// `.switchServer` cascade must wipe the mirror so the next pairing
        /// starts empty.
        @Test("switch-server logout wipes the standalone local mirror (no cross-account leak)")
        func switchServerWipesStandaloneMirror() async throws {
            let keychain = InMemoryKeychain()
            let container = makeContainer(keychain: keychain)

            // Seed the standalone mirror with one offline measurement.
            _ = try await container.localRepo.addMeasurement(
                kind: "WEIGHT",
                value: 72.5,
                unit: "kg",
                recordedAt: .now
            )
            let before = try await container.localRepo.measurements()
            #expect(before.count == 1, "Precondition: mirror seeded with one row")

            await container.handleLocalLogout() // .switchServer

            let after = try await container.localRepo.measurements()
            #expect(after.isEmpty, "Standalone mirror MUST be empty after a server switch")
        }

        /// Account-deletion already wiped the mirror pre-fix; pin it so the
        /// shared `clearsStandaloneMirror` gate keeps covering both reasons.
        @Test("account-deletion wipes the standalone local mirror")
        func accountDeletionWipesStandaloneMirror() async throws {
            let keychain = InMemoryKeychain()
            let container = makeContainer(keychain: keychain)

            _ = try await container.localRepo.addMeasurement(
                kind: "PULSE",
                value: 61,
                unit: "bpm",
                recordedAt: .now
            )
            #expect(try await container.localRepo.measurements().count == 1)

            let hook = try #require(container.authStore.localCleanupHook)
            await hook() // .accountDeleted

            #expect(try await container.localRepo.measurements().isEmpty)
        }

        /// Same-account paths (`.userInitiated`) must NOT wipe the mirror — the
        /// standalone history legitimately belongs to the same identity, so a
        /// plain sign-out followed by re-login preserves the offline ledger.
        @Test("userInitiated logout preserves the standalone local mirror")
        func userInitiatedPreservesStandaloneMirror() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setString("bearer-fixture", forKey: KeychainKey.authToken)
            let container = makeContainer(keychain: keychain)

            _ = try await container.localRepo.addMeasurement(
                kind: "WEIGHT",
                value: 70,
                unit: "kg",
                recordedAt: .now
            )

            let hook = try #require(container.authStore.onPostLogoutHook)
            await hook() // .userInitiated

            let after = try await container.localRepo.measurements()
            #expect(after.count == 1, "Same-account sign-out must keep the standalone mirror")
        }

        // MARK: - Cascade idempotency

        /// Running every path back-to-back must not crash or throw even when the
        /// key was already wiped by a prior path — the cascade is `try?`-guarded
        /// throughout. Guards against a future re-order introducing a hard wipe.
        /// `.switchServer` (first) clears the key; the same-account paths then
        /// run as no-ops against the already-absent key, and account-deletion
        /// (last) is idempotent — final state is key-absent regardless.
        @Test("running all four paths in sequence is idempotent")
        func allPathsIdempotent() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setData(Data(repeating: 0xE5, count: 32), forKey: KeychainKey.outboxPayloadKey)
            let container = makeContainer(keychain: keychain)

            let postLogout = try #require(container.authStore.onPostLogoutHook)
            let cleanup = try #require(container.authStore.localCleanupHook)

            await container.handleLocalLogout() // .switchServer — wipes key
            await postLogout() // .userInitiated — no-op on absent key
            await container.unauthorizedRef.invoke() // .tokenExpired — no-op
            await cleanup() // .accountDeleted — idempotent wipe

            #expect(keychain.getData(forKey: KeychainKey.outboxPayloadKey) == nil)
        }

        // MARK: - Helpers

        /// Arms the universal cascade-completion signal and returns the counter
        /// to assert against after the path under test has run.
        ///
        /// `notificationClearOnLogoutHook` is awaited on the final line of
        /// `performFullLocalLogout(reason:)`, so a count of exactly 1 proves
        /// the entry point drove the *whole* cascade — not merely that it
        /// started one. The wired production hook is captured and re-invoked
        /// first, so arming the spy observes the teardown instead of replacing
        /// a step of it; the count also pins "exactly once", which a boolean
        /// flag would not.
        private func armCascadeCompletionSignal(_ container: AppContainer) -> CascadeCompletionSpy {
            let spy = CascadeCompletionSpy()
            let wired = container.notificationClearOnLogoutHook
            container.notificationClearOnLogoutHook = { @MainActor in
                await wired?()
                spy.completions += 1
            }
            #expect(spy.completions == 0, "Precondition: the cascade has not run yet")
            return spy
        }

        private func makeContainer(keychain: InMemoryKeychain) -> AppContainer {
            AppContainer(
                environment: testEnvironment(),
                keychain: keychain,
                passkey: TestPasskeyService(),
                healthKit: MockHealthKitWriter()
            )
        }

        private func testEnvironment() -> AppEnvironment {
            AppEnvironment(
                baseURL: URL(string: "https://example.invalid"),
                bundleID: "dev.healthlog.app.tests",
                appVersion: "0.0.0-test",
                buildNumber: "0"
            )
        }
    }

    /// Counter for the tail-of-cascade LOGOUT-NOTIF seam. A count (not a flag)
    /// so "the cascade ran exactly once" is expressible — an entry point that
    /// accidentally drove the teardown twice would otherwise read as success.
    /// File-scope rather than nested so the suite's own body does not grow.
    @MainActor
    final class CascadeCompletionSpy {
        var completions = 0
    }

#endif // !SWIFT_PACKAGE
