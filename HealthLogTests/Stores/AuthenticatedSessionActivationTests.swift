// Phase 07 / plan 07-09 — the admission half of the Phase-06 session boundary.
//
// Phase 06 built one awaited teardown orchestrator and four terminal paths that
// invalidate the shared `AuthenticatedSessionLeaseRegistry`. Nothing ever
// activated it. `AuthStore.activateAuthenticatedSession(ownerID:)` and
// `AppContainer.authenticatedSessionBoundaryHooks.activate` existed and were
// called only from tests, so on a real device `capture(ownerID:)` returned nil,
// `HealthSyncAuthenticatedLease.admit` threw `unavailableAuthentication`, and
// every admission-gated Phase-07 sweep refused while every toggle read "on".
//
// The unit suite could not see it because every other test activates the
// registry by hand. These tests deliberately never do: they drive the REAL
// `AuthStore` over the REAL `AuthService`/`APIClient` against a stub
// `URLProtocol` (the repo's no-mock-server doctrine) and then ask the registry —
// and the production `HealthSyncImporterAdmission.keychainBound` that every
// gated importer actually uses — whether an account is admitted.
//
// The teardown half is asserted in the same file on purpose: activation is only
// correct if it is the exact mirror image of the invalidation, and a test that
// proves one without the other would let a registry survive its account.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("Authenticated session activation", .serialized)
    struct AuthenticatedSessionActivationTests {
        // MARK: - Harness

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

        private struct Fixture {
            let store: AuthStore
            let keychain: InMemoryKeychain
            let registry: AuthenticatedSessionLeaseRegistry
            let admission: HealthSyncImporterAdmission
        }

        private func makeFixture() throws -> Fixture {
            let keychain = InMemoryKeychain()
            let environment = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: environment, keychain: keychain, sessionConfiguration: .mock())
            let auth = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            let registry = AuthenticatedSessionLeaseRegistry()
            let suite = "session-activation.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let store = AuthStore(
                auth: auth,
                keychain: keychain,
                syncMode: nil,
                defaults: defaults,
                sessionRegistry: registry
            )
            return Fixture(
                store: store,
                keychain: keychain,
                registry: registry,
                admission: .keychainBound(keychain: keychain, registry: registry)
            )
        }

        /// The exact bundle shape `AuthService.login` persists.
        private nonisolated static func sessionBody(id: String = "usr_activation_1") -> Data {
            Data("""
            {
              "data": {
                "user": { "id": "\(id)", "username": "activation" },
                "token": "hlk_bearer_ACT",
                "tokenExpiresAt": "2027-07-01T12:00:00Z",
                "refreshToken": "hlr_refresh_ACT",
                "refreshTokenExpiresAt": "2027-09-01T12:00:00Z"
              },
              "error": null
            }
            """.utf8)
        }

        private static func serveSession(id: String = "usr_activation_1") {
            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    sessionBody(id: id)
                )
            }
        }

        /// Whether the production admission every gated importer uses can admit
        /// the signed-in account right now. This is the exact call
        /// `AppOwnedHealthCollectionCoordinator.run`, the cycle importer, the
        /// heart-event importer, the medication ledger and the mood importer
        /// make before they touch HealthKit.
        private func isAdmitted(_ fixture: Fixture) -> Bool {
            fixture.admission.refusal(for: .speziSamples) == nil
        }

        // MARK: - A real login path admits

        /// The release-critical assertion: a password login through the real
        /// `AuthStore.login(email:password:)` leaves the shared registry
        /// admitting the account, so the sweeps that Waves 1-4 made durable can
        /// actually run.
        @Test("a real password login activates the shared session registry")
        func passwordLoginActivatesRegistry() async throws {
            let fixture = try makeFixture()

            // Before the login there is nothing to admit, and the admission
            // says so rather than throwing something unnameable.
            #expect(fixture.registry.capture(ownerID: "usr_activation_1") == nil)
            #expect(fixture.admission.refusal(for: .speziSamples) == .notAdmitted)

            Self.serveSession()
            await fixture.store.login(email: "u@e.co", password: "pw")

            // The server branch parks in `.authenticating` until onboarding's
            // permission steps finish — and that is already an admitted owner:
            // `HealthKitPermissionStep` activates HealthKit from there.
            #expect(fixture.store.phase == .authenticating(User(
                id: "usr_activation_1",
                email: nil,
                username: "activation",
                displayName: nil,
                createdAt: nil
            )))
            let lease = try #require(fixture.registry.capture(ownerID: "usr_activation_1"))
            #expect(lease.isCurrent)
            #expect(lease.ownerID == "usr_activation_1")
            #expect(isAdmitted(fixture))
        }

        /// `completeOnboarding()` is the same session, not a new one: the lease
        /// captured during `.authenticating` must survive the promotion, or the
        /// post-authentication sweep would run under a lease its own transition
        /// had just staled.
        @Test("completing onboarding keeps the admitted session, it does not re-mint one")
        func completeOnboardingPreservesTheSession() async throws {
            let fixture = try makeFixture()
            Self.serveSession()
            await fixture.store.login(email: "u@e.co", password: "pw")
            let lease = try #require(fixture.registry.capture(ownerID: "usr_activation_1"))

            fixture.store.completeOnboarding()

            #expect(lease.isCurrent, "the .authenticating → .authenticated promotion is one session")
            #expect(isAdmitted(fixture))
        }

        /// Cold launch with a persisted token: `bootstrap()` publishes
        /// `.authenticated` without any login round-trip, and it is the launch
        /// path `RootView.activateHealthKitBackgroundIfReady` runs behind.
        @Test("cold-launch bootstrap over a persisted token admits the account")
        func bootstrapActivatesRegistry() async throws {
            let fixture = try makeFixture()
            try fixture.keychain.setString("hlk_bearer_boot", forKey: KeychainKey.authToken)
            try fixture.keychain.setString("usr_boot_1", forKey: KeychainKey.userID)

            await fixture.store.bootstrap()

            let bootstrapped: Bool = if case let .authenticated(user) = fixture.store.phase {
                user.id == "usr_boot_1"
            } else {
                false
            }
            #expect(bootstrapped)
            let lease = try #require(fixture.registry.capture(ownerID: "usr_boot_1"))
            #expect(lease.isCurrent)
            #expect(isAdmitted(fixture))
        }

        // MARK: - The teardown mirror

        /// User-initiated sign-out is one of Phase 06's four terminal paths. The
        /// registry must be inert afterwards, and the lease the account held must
        /// be stale — otherwise a suspended sweep could publish into the closing
        /// session, which is the invariant 06-05 exists for.
        @Test("user logout leaves the registry inert and the old lease stale")
        func logoutInvalidatesRegistry() async throws {
            let fixture = try makeFixture()
            Self.serveSession()
            await fixture.store.login(email: "u@e.co", password: "pw")
            fixture.store.completeOnboarding()
            let lease = try #require(fixture.registry.capture(ownerID: "usr_activation_1"))
            #expect(lease.isCurrent)

            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":{"ok":true},"error":null}"#.utf8)
                )
            }
            await fixture.store.logout()

            #expect(!lease.isCurrent)
            #expect(fixture.registry.capture(ownerID: "usr_activation_1") == nil)
            #expect(fixture.admission.refusal(for: .speziSamples) == .notAdmitted)
        }

        /// A terminal 401 tears the session down through `handleUnauthorized()`,
        /// which invalidates at its own commitment point *before* the credential
        /// wipe. The phase transition that follows must not resurrect anything.
        @Test("a terminal 401 leaves the registry inert")
        func unauthorizedInvalidatesRegistry() async throws {
            let fixture = try makeFixture()
            Self.serveSession()
            await fixture.store.login(email: "u@e.co", password: "pw")
            fixture.store.completeOnboarding()
            let lease = try #require(fixture.registry.capture(ownerID: "usr_activation_1"))

            _ = await fixture.store.handleUnauthorized()

            #expect(!lease.isCurrent)
            #expect(fixture.registry.capture(ownerID: "usr_activation_1") == nil)
        }

        /// The two transitions that lose an owner without going through the
        /// terminal cascade. Before this plan they left a live registry behind an
        /// unauthenticated shell — an account with no session that could still be
        /// admitted.
        @Test("standalone and server-pairing transitions also stop admitting")
        func ownerLosingTransitionsInvalidate() async throws {
            let standalone = try makeFixture()
            Self.serveSession()
            await standalone.store.login(email: "u@e.co", password: "pw")
            standalone.store.completeOnboarding()
            let standaloneLease = try #require(standalone.registry.capture(ownerID: "usr_activation_1"))
            standalone.store.enterStandaloneMode()
            #expect(!standaloneLease.isCurrent)
            #expect(standalone.registry.capture(ownerID: "usr_activation_1") == nil)

            let pairing = try makeFixture()
            Self.serveSession()
            await pairing.store.login(email: "u@e.co", password: "pw")
            pairing.store.completeOnboarding()
            let pairingLease = try #require(pairing.registry.capture(ownerID: "usr_activation_1"))
            pairing.store.beginServerPairing()
            #expect(!pairingLease.isCurrent)
            #expect(pairing.registry.capture(ownerID: "usr_activation_1") == nil)
        }

        /// An account switch on one device must never let account A's captured
        /// lease survive into account B's session — the `lateAccountACannotMutateB`
        /// shape, asserted here at the admission seam rather than at an importer.
        @Test("a replacement account stales the previous account's lease")
        func replacementAccountStalesThePrevious() async throws {
            let fixture = try makeFixture()
            Self.serveSession(id: "usr_A")
            await fixture.store.login(email: "a@e.co", password: "pw")
            fixture.store.completeOnboarding()
            let leaseA = try #require(fixture.registry.capture(ownerID: "usr_A"))

            MockURLProtocol.handler = { req in
                (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":{"ok":true},"error":null}"#.utf8)
                )
            }
            await fixture.store.logout()
            Self.serveSession(id: "usr_B")
            await fixture.store.login(email: "b@e.co", password: "pw")
            fixture.store.completeOnboarding()

            #expect(!leaseA.isCurrent)
            #expect(fixture.registry.capture(ownerID: "usr_A") == nil)
            let leaseB = try #require(fixture.registry.capture(ownerID: "usr_B"))
            #expect(leaseB.isCurrent)
            #expect(leaseB.generation > leaseA.generation)
        }
    }

#endif // !SWIFT_PACKAGE

// swiftlint:enable force_unwrapping
