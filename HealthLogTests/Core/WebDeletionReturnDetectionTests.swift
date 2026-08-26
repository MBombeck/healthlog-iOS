// #37/#38 Privacy H3 (audit-v0162) — MFA web-deletion return detection.
//
// An MFA-enrolled user cannot delete in-app (the fresh-MFA step-up is
// cookie-only), so `DeleteAccountScreen` routes them to the web account page.
// Before this fix the local device kept ALL PHI (SWR cache, widget + watch
// snapshot, encrypted outbox, keychain tokens, BYO keys, Coach transcript)
// indefinitely — the wipe only ran on the in-app 2xx path. These tests drive
// the REAL `APIClient` against a stub `URLProtocol` (repo no-mock-server
// doctrine) and pin the return-detection cascade:
//   1. armed flag + `/api/auth/me` 401 → full `.accountDeleted` wipe + phase
//      transition + keychain token wipe + flag cleared.
//   2. armed flag + `/api/auth/me` 200 → NO wipe, flag stays armed (re-probe).
//   3. the `AuthService.probeAccountStatus()` classification itself.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @Suite("Web-deletion return detection (Privacy H3)", .serialized)
    struct WebDeletionReturnDetectionTests {
        /// Passkey stub — the probe / delete cascade never touches it.
        private final class NoopPasskey: PasskeyServiceProtocol, @unchecked Sendable {
            @MainActor func register(
                challenge _: String, rpId _: String, rpName _: String,
                userID _: String, userName _: String, displayName _: String,
                anchor _: ASPresentationAnchorProvider
            ) async throws -> PasskeyRegistration {
                throw HLError.unknown("noop")
            }

            @MainActor func assert(
                challenge _: String, rpId _: String, allowCredentialIDs _: [String],
                anchor _: ASPresentationAnchorProvider
            ) async throws -> PasskeyAssertion {
                throw HLError.unknown("noop")
            }
        }

        /// Thread-safe call counter for the local-cleanup spy.
        private final class CleanupSpy: @unchecked Sendable {
            private let lock = NSLock()
            private var _calls = 0
            var calls: Int {
                lock.withLock { _calls }
            }

            func record() {
                lock.withLock { _calls += 1 }
            }
        }

        /// Holds a mock `/api/auth/me` response in flight so a test can replace
        /// the authenticated account before the original owner's probe resumes.
        private final class SuspendedProbe: @unchecked Sendable {
            private let lock = NSLock()
            private let releaseSemaphore = DispatchSemaphore(value: 0)
            private var _started = false

            var started: Bool {
                lock.withLock { _started }
            }

            func waitForRelease() {
                lock.withLock { _started = true }
                releaseSemaphore.wait()
            }

            func release() {
                releaseSemaphore.signal()
            }
        }

        /// The wired-up store + its collaborators for one test.
        private struct Fixture {
            let store: AuthStore
            let keychain: InMemoryKeychain
            let spy: CleanupSpy
        }

        @MainActor
        private func makeStore(
            tokenPresent: Bool,
            genericUnauthorizedCleanup: CleanupSpy? = nil
        ) throws -> Fixture {
            let keychain = InMemoryKeychain()
            if tokenPresent {
                try keychain.setString("hlk_bearer_LIVE", forKey: KeychainKey.authToken)
                try keychain.setString("hlr_refresh_LIVE", forKey: KeychainKey.refreshToken)
                try keychain.setString("user-h3-1", forKey: KeychainKey.userID)
            }
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let unauthorizedRef = UnauthorizedHandlerRef()
            let api = APIClient(
                environment: env,
                keychain: keychain,
                sessionConfiguration: .mock(),
                onUnauthorized: { await unauthorizedRef.invoke() }
            )
            let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            let suite = "h3.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let store = AuthStore(auth: auth, keychain: keychain, defaults: defaults)
            let spy = CleanupSpy()
            store.localCleanupHook = { spy.record() }
            unauthorizedRef.set { [weak store] in
                let shouldRunGenericCleanup = await store?.handleUnauthorized() ?? false
                if shouldRunGenericCleanup {
                    genericUnauthorizedCleanup?.record()
                }
            }
            return Fixture(store: store, keychain: keychain, spy: spy)
        }

        private func waitUntilProbeStarts(_ probe: SuspendedProbe) async throws {
            for _ in 0 ..< 500 where !probe.started {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(probe.started, "the suspended account-status probe must start")
        }

        private func seedDeletedAccountBoundaryState(_ keychain: InMemoryKeychain) throws {
            try keychain.setString("device-a", forKey: KeychainKey.deviceID)
            try keychain.setString("granted", forKey: AIConsentStore.keyPrefix + AIProvider.anthropic.rawValue)
            try keychain.setString("declined", forKey: AIConsentStore.declinedKeyPrefix + AIProvider.openai.rawValue)
            try keychain.setString("granted", forKey: AIConsentStore.serverManagedScope)
            try keychain.setString("declined", forKey: AIConsentStore.serverManagedDeclinedKey)
            try keychain.setString("granted", forKey: AIConsentStore.byoKeyPrefix + BYOProviderID.gemini.rawValue)
            try keychain.setString("sentinel", forKey: BYOKeyStore.keyPrefix + BYOProviderID.gemini.rawValue)
            try keychain.setString("sentinel", forKey: BYOKeyStore.modelPrefix + BYOProviderID.gemini.rawValue)
            try keychain.setString("sentinel", forKey: BYOKeyStore.baseURLPrefix + BYOProviderID.gemini.rawValue)
        }

        // MARK: - reconcilePendingWebDeletion

        @Test("armed flag + /api/auth/me 401 → full local wipe + phase + flag cleared")
        @MainActor
        func goneRunsFullWipe() async throws {
            let f = try makeStore(tokenPresent: true)
            f.store.setPhaseForTesting(.authenticated(
                User(id: "user-h3-1", email: nil, username: nil, displayName: nil, createdAt: .now)
            ))
            try seedDeletedAccountBoundaryState(f.keychain)
            f.store.markPendingWebDeletion()
            #expect(f.store.hasPendingWebDeletion)

            MockURLProtocol.handler = { req in
                #expect(req.url?.path == "/api/auth/me")
                return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }

            await f.store.reconcilePendingWebDeletion()

            #expect(f.spy.calls == 1, "the full .accountDeleted local cascade MUST run when the account is gone")
            #expect(f.store.phase == .unauthenticated)
            #expect(f.keychain.getString(forKey: KeychainKey.authToken) == nil)
            #expect(f.keychain.getString(forKey: KeychainKey.refreshToken) == nil)
            #expect(f.keychain.getString(forKey: KeychainKey.userID) == nil)
            #expect(f.keychain.getString(forKey: KeychainKey.deviceID) == nil)
            #expect(f.keychain.getString(forKey: AIConsentStore.keyPrefix + AIProvider.anthropic.rawValue) == nil)
            #expect(f.keychain.getString(forKey: AIConsentStore.declinedKeyPrefix + AIProvider.openai.rawValue) == nil)
            #expect(f.keychain.getString(forKey: AIConsentStore.serverManagedScope) == nil)
            #expect(f.keychain.getString(forKey: AIConsentStore.serverManagedDeclinedKey) == nil)
            #expect(f.keychain.getString(forKey: AIConsentStore.byoKeyPrefix + BYOProviderID.gemini.rawValue) == nil)
            #expect(f.keychain.getString(forKey: BYOKeyStore.keyPrefix + BYOProviderID.gemini.rawValue) == nil)
            #expect(f.keychain.getString(forKey: BYOKeyStore.modelPrefix + BYOProviderID.gemini.rawValue) == nil)
            #expect(f.keychain.getString(forKey: BYOKeyStore.baseURLPrefix + BYOProviderID.gemini.rawValue) == nil)
            #expect(!f.store.hasPendingWebDeletion, "the pending-web-deletion flag MUST clear once the wipe ran")
        }

        @Test("A probe returning gone after B login cannot wipe B and clears only A's stale marker")
        @MainActor
        func staleGoneProbeCannotWipeReplacementAccount() async throws {
            let f = try makeStore(tokenPresent: true)
            let replacementOwner = User(
                id: "user-h3-2", email: nil, username: nil, displayName: nil, createdAt: .now
            )
            f.store.setPhaseForTesting(.authenticated(
                User(id: "user-h3-1", email: nil, username: nil, displayName: nil, createdAt: .now)
            ))
            f.store.markPendingWebDeletion()
            let probe = SuspendedProbe()
            MockURLProtocol.handler = { req in
                probe.waitForRelease()
                return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }

            let reconciliation = Task { @MainActor in
                await f.store.reconcilePendingWebDeletion()
            }
            try await waitUntilProbeStarts(probe)

            try f.keychain.setString("token-b", forKey: KeychainKey.authToken)
            try f.keychain.setString("refresh-b", forKey: KeychainKey.refreshToken)
            try f.keychain.setString("user-h3-2", forKey: KeychainKey.userID)
            try f.keychain.setString("device-b", forKey: KeychainKey.deviceID)
            try f.keychain.setString("granted", forKey: AIConsentStore.serverManagedScope)
            f.store.setPhaseForTesting(.authenticated(replacementOwner))
            probe.release()
            await reconciliation.value

            #expect(f.spy.calls == 0)
            #expect(f.store.phase == .authenticated(replacementOwner))
            #expect(f.keychain.getString(forKey: KeychainKey.authToken) == "token-b")
            #expect(f.keychain.getString(forKey: KeychainKey.refreshToken) == "refresh-b")
            #expect(f.keychain.getString(forKey: KeychainKey.userID) == "user-h3-2")
            #expect(f.keychain.getString(forKey: KeychainKey.deviceID) == "device-b")
            #expect(f.keychain.getString(forKey: AIConsentStore.serverManagedScope) == "granted")
            #expect(!f.store.hasPendingWebDeletion)
        }

        @Test("a new same-owner auth generation supersedes an in-flight deletion probe")
        @MainActor
        func staleProbeCannotWipeNewSameOwnerSession() async throws {
            let f = try makeStore(tokenPresent: true)
            let owner = User(id: "user-h3-1", email: nil, username: nil, displayName: nil, createdAt: .now)
            f.store.setPhaseForTesting(.authenticated(owner))
            f.store.markPendingWebDeletion()
            let probe = SuspendedProbe()
            MockURLProtocol.handler = { req in
                probe.waitForRelease()
                return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }

            let reconciliation = Task { @MainActor in
                await f.store.reconcilePendingWebDeletion()
            }
            try await waitUntilProbeStarts(probe)

            f.store.setPhaseForTesting(.unauthenticated)
            try f.keychain.setString("replacement-token", forKey: KeychainKey.authToken)
            try f.keychain.setString("replacement-refresh", forKey: KeychainKey.refreshToken)
            try f.keychain.setString(owner.id, forKey: KeychainKey.userID)
            try f.keychain.setString("replacement-device", forKey: KeychainKey.deviceID)
            f.store.setPhaseForTesting(.authenticated(owner))
            probe.release()
            await reconciliation.value

            #expect(f.spy.calls == 0)
            #expect(f.store.phase == .authenticated(owner))
            #expect(f.keychain.getString(forKey: KeychainKey.authToken) == "replacement-token")
            #expect(f.keychain.getString(forKey: KeychainKey.refreshToken) == "replacement-refresh")
            #expect(f.keychain.getString(forKey: KeychainKey.deviceID) == "replacement-device")
            #expect(!f.store.hasPendingWebDeletion)
        }

        @Test("armed flag + /api/auth/me 200 → NO wipe, flag stays armed for re-probe")
        @MainActor
        func existsKeepsEverything() async throws {
            let f = try makeStore(tokenPresent: true)
            f.store.setPhaseForTesting(.authenticated(
                User(id: "user-h3-1", email: nil, username: nil, displayName: nil, createdAt: .now)
            ))
            f.store.markPendingWebDeletion()

            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }

            await f.store.reconcilePendingWebDeletion()

            #expect(f.spy.calls == 0, "an account that still exists must NOT trigger a wipe")
            #expect(f.keychain.getString(forKey: KeychainKey.authToken) == "hlk_bearer_LIVE")
            #expect(f.store.hasPendingWebDeletion, "the flag stays armed so the next foreground re-probes")
        }

        @Test("armed flag + inconclusive probe → NO wipe, flag stays armed for a later foreground")
        @MainActor
        func inconclusiveKeepsEverything() async throws {
            let f = try makeStore(tokenPresent: true)
            f.store.setPhaseForTesting(.authenticated(
                User(id: "user-h3-1", email: nil, username: nil, displayName: nil, createdAt: .now)
            ))
            f.store.markPendingWebDeletion()

            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"Temporarily unavailable"}"#.utf8)
                )
            }

            await f.store.reconcilePendingWebDeletion()

            #expect(f.spy.calls == 0, "an inconclusive probe must never infer account deletion")
            #expect(f.keychain.getString(forKey: KeychainKey.authToken) == "hlk_bearer_LIVE")
            #expect(f.store.hasPendingWebDeletion, "the marker must survive so a later foreground can retry")
        }

        @Test("unarmed flag → probe never runs (no wipe)")
        @MainActor
        func unarmedIsNoOp() async throws {
            let f = try makeStore(tokenPresent: true)
            f.store.setPhaseForTesting(.authenticated(
                User(id: "user-h3-1", email: nil, username: nil, displayName: nil, createdAt: .now)
            ))
            // No markPendingWebDeletion().
            MockURLProtocol.handler = { req in
                Issue.record("probe must not fire when the flag is unarmed")
                return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, nil)
            }

            await f.store.reconcilePendingWebDeletion()

            #expect(f.spy.calls == 0)
        }

        @Test("armed marker from a different owner is discarded without probing or wiping")
        @MainActor
        func differentOwnerCannotInheritMarker() async throws {
            let f = try makeStore(tokenPresent: true)
            f.store.setPhaseForTesting(.authenticated(
                User(id: "user-h3-1", email: nil, username: nil, displayName: nil, createdAt: .now)
            ))
            f.store.markPendingWebDeletion()

            // Simulate a later account taking over the same install before the
            // old marker was reconciled. The marker must be owner-bound so it
            // can never delete the later account's local state.
            try f.keychain.setString("user-h3-2", forKey: KeychainKey.userID)
            MockURLProtocol.handler = { req in
                Issue.record("a marker owned by another account must not probe")
                return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, nil)
            }

            await f.store.reconcilePendingWebDeletion()

            #expect(f.spy.calls == 0)
            #expect(f.keychain.getString(forKey: KeychainKey.authToken) == "hlk_bearer_LIVE")
            #expect(!f.store.hasPendingWebDeletion)
        }

        @Test("armed flag + already token-less session → gone → wipe (incidental-401 gap)")
        @MainActor
        func tokenlessSessionIsGone() async throws {
            // An incidental 401 already fired the token-expiry bridge (tokens
            // wiped) but the outbox/PHI survived. The armed probe still runs the
            // full .accountDeleted wipe on the next foreground.
            let f = try makeStore(tokenPresent: false)
            f.store.setPhaseForTesting(.unauthenticated)
            f.store.markPendingWebDeletion()
            MockURLProtocol.handler = { req in
                Issue.record("probe must short-circuit without a network call when token-less")
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, nil)
            }

            await f.store.reconcilePendingWebDeletion()

            #expect(f.spy.calls == 1)
            #expect(!f.store.hasPendingWebDeletion)
        }

        // MARK: - AuthService.probeAccountStatus classification

        @Test("probeAccountStatus: 200 → .exists, 401 → .gone")
        func probeClassifies() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setString("hlk_bearer_LIVE", forKey: KeychainKey.authToken)
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local"),
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
            let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())

            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            #expect(await auth.probeAccountStatus() == .exists)

            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            #expect(await auth.probeAccountStatus() == .gone)
        }
    }

#endif // !SWIFT_PACKAGE
