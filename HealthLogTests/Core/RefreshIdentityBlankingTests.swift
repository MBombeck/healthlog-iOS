// Phase 24 / plan 24-01 — the defect that cost four builds.
//
// `POST /api/auth/refresh` answers with token fields ONLY and no `user` block.
// That is documented server contract (`05-auth-flows.md`, W2a-A2 §3.1) and is
// byte-stable v1.37.24 → v1.37.28. iOS synthesises a stub `User(id: "")` for
// it (`AuthService+WireDTOs.swift:34`), the refresh path persists that session
// (`AuthService.swift:730`), and `persist` wrote `KeychainKey.userID`
// UNCONDITIONALLY (`AuthService.swift:776`) — eight lines above a
// `userDisplayName` write whose own comment names this exact scenario:
// "the refresh path hands us a stub user (empty id, nil fields), and we must
// not clobber a good hint with an empty one."
//
// `KeychainStore.setString("")` is a successful upsert, so `getString`
// afterwards returns `""`, not `nil`. Every store fenced by the Phase-06
// authenticated-session lease trims that owner id, sees empty, records
// `.leaseUnavailable` and returns WITHOUT ISSUING ANY REQUEST. Nothing is
// published and no error is published, so `DashboardMetricsSectionState`
// resolves to `.skeleton` — the permanent loading animation the operator sees.
//
// Access tokens live 24 h, which is why the app worked right after a login and
// died at the next refresh, and why four timing hypotheses each almost fitted.
//
// ## What these tests are, and what they refuse to be
//
// Three claims, and each is proven from the state that actually exists on a
// device rather than from a convenient one:
//
// 1. **The guard.** Driven through the REAL `AuthService.refresh()` over the
//    REAL `APIClient` and the REAL wire DTO — never a re-implementation of
//    `persist`. The precedent is `AuthServicePersistAtomicTests`.
// 2. **The repair.** The starting state is a POISONED PRE-EXISTING
//    INSTALLATION: a Keychain holding a valid Bearer, a refresh token and
//    `KeychainKey.userID == ""` — exactly what b266/b267/b268 leave behind
//    after their first refresh. The assertion is that a LEASE-FENCED STORE
//    ISSUES A REQUEST. A fresh-install test passes on the broken tree and
//    proves nothing; plan 13-05 already shipped a server-address wipe that
//    every test missed for precisely that reason, because every test
//    pre-seeded the sentinel whose ABSENCE was the trigger.
// 3. **The fence against its return.** An empty write to that slot from ANY
//    production path is a failure, asserted behaviourally through a trap
//    Keychain across every persist entry point, and structurally by
//    enumerating every production write site.
//
// Scope, deliberately: the Phase-06 lease fences are CORRECT. Refusing an
// authenticated request without an owner id is the right behaviour. Nothing
// here touches the fences, the refusal logging, the foreground pass or the
// stores.

// type_body_length exception (owner: 24-01): the three claims share one harness
// — the poisoned Keychain, the wire log and the transport — and splitting them
// into three suites would give three different arrangements of the same state,
// which is precisely the mistake (a convenient starting state) these tests
// exist to prevent.
// swiftlint:disable force_unwrapping file_length type_body_length

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing
    #if canImport(AuthenticationServices)
        import AuthenticationServices
    #endif

    @MainActor
    @Suite("Refresh must never blank the Keychain user id")
    struct RefreshIdentityBlankingTests {
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

        /// The id the operator's account actually has on the server. Recovering
        /// exactly this value is what un-poisons an installation.
        private nonisolated static let realUserID = "usr_operator_real"

        /// The shipped `POST /api/auth/refresh` body: token fields only, **no
        /// `user` block**. Copied from the server contract, not invented — this
        /// is the response that produces the stub user.
        private nonisolated static func refreshBody() -> Data {
            Data(#"""
            {
              "data": {
                "token": "hlk_bearer_REFRESHED",
                "tokenExpiresAt": "2027-06-01T12:00:00Z",
                "refreshToken": "hlr_refresh_REFRESHED",
                "refreshTokenExpiresAt": "2027-07-31T12:00:00Z"
              },
              "error": null
            }
            """#.utf8)
        }

        /// The shipped `GET /api/auth/me` row — the one read that knows the real
        /// id and is itself lease-fenced everywhere else in the app.
        private nonisolated static func meBody(id: String = realUserID) -> Data {
            Data("""
            {
              "data": {
                "id": "\(id)",
                "email": "operator@example.com",
                "username": "operator",
                "displayName": "Alex",
                "createdAt": "2026-01-01T00:00:00.000Z"
              },
              "error": null
            }
            """.utf8)
        }

        /// The shipped `POST /api/auth/login` body — WITH a `user` block, which
        /// is the documented difference from the refresh route.
        private nonisolated static func loginBody() -> Data {
            Data("""
            {
              "data": {
                "user": {
                  "id": "\(realUserID)",
                  "email": "operator@example.com",
                  "username": "operator",
                  "displayName": "Alex"
                },
                "token": "hlk_bearer_FRESH",
                "tokenExpiresAt": "2027-06-01T12:00:00Z",
                "refreshToken": "hlr_refresh_FRESH",
                "refreshTokenExpiresAt": "2027-07-31T12:00:00Z"
              },
              "error": null
            }
            """.utf8)
        }

        private nonisolated static func dashboardSummaryBody() -> Data {
            Data(#"""
            {
              "data": {
                "greeting": { "salutation": "Hi", "date": "2026-08-25T08:00:00.000Z" },
                "compliance": { "scheduledToday": 3, "takenToday": 1 },
                "highlightInsight": null,
                "metrics": [],
                "lastUpdated": "2026-08-25T08:00:00.000Z"
              },
              "error": null
            }
            """#.utf8)
        }

        private nonisolated static func ok(_ request: URLRequest, _ body: Data) -> (HTTPURLResponse, Data?) {
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body
            )
        }

        /// A Keychain in the state a device is in AFTER a pre-fix refresh:
        /// a valid Bearer, a valid refresh token, a good display-name hint that
        /// the `:784` guard preserved — and an **empty** user id.
        ///
        /// This is the whole point of the suite. The poison is written here, by
        /// the test, because a fresh install has no poison and would pass on the
        /// broken tree.
        private static func poisonedInstallKeychain() throws -> InMemoryKeychain {
            let keychain = InMemoryKeychain()
            try keychain.setString("hlk_bearer_LIVE", forKey: KeychainKey.authToken)
            try keychain.setString("hlr_refresh_LIVE", forKey: KeychainKey.refreshToken)
            try keychain.setString("2027-06-01T12:00:00Z", forKey: KeychainKey.accessTokenExpiresAt)
            try keychain.setString("2027-07-31T12:00:00Z", forKey: KeychainKey.refreshTokenExpiresAt)
            // The poison, byte for byte: a successful upsert of the empty string.
            try keychain.setString("", forKey: KeychainKey.userID)
            // The name hint SURVIVED, because its write is already guarded. This
            // is also the field-observed b267 symptom R1: the avatar still
            // painted "M" while the profile store refused.
            try keychain.setString("Alex", forKey: KeychainKey.userDisplayName)
            return keychain
        }

        private func makeAPI(session: MockURLProtocolSession, keychain: KeychainStoring) -> APIClient {
            let environment = AppEnvironment(
                baseURL: session.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "0.1.0",
                buildNumber: "1"
            )
            return APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: session.configuration
            )
        }

        private func isolatedDefaults() throws -> (UserDefaults, String) {
            let suite = "refresh-identity-blanking.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            return (defaults, suite)
        }

        // MARK: - Half one: the guard

        /// Behavioural RED 24-01-A — on the pre-fix tree this observes `""`.
        ///
        /// A refresh is the ONLY thing that happens here. The Keychain starts as
        /// a healthy signed-in install and must end as one: the server sent no
        /// `user` block, so there was never anything to write.
        @Test("a refresh that carries no user block leaves a good user id intact")
        func refreshDoesNotBlankAGoodUserID() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setString("hlk_bearer_OLD", forKey: KeychainKey.authToken)
            try keychain.setString("hlr_refresh_OLD", forKey: KeychainKey.refreshToken)
            try keychain.setString(Self.realUserID, forKey: KeychainKey.userID)
            try keychain.setString("Alex", forKey: KeychainKey.userDisplayName)

            let transport = MockURLProtocolSession()
            defer { transport.invalidate() }
            transport.install { request in
                Self.ok(request, Self.refreshBody())
            }

            let service = AuthService(
                api: makeAPI(session: transport, keychain: keychain),
                keychain: keychain,
                passkey: NoopPasskey()
            )

            let outcome = await service.refresh()
            #expect(outcome == .refreshed, "the documented no-user refresh body is a SUCCESSFUL refresh")

            // The tokens rotated — the refresh did its job.
            #expect(keychain.getString(forKey: KeychainKey.authToken) == "hlk_bearer_REFRESHED")
            #expect(keychain.getString(forKey: KeychainKey.refreshToken) == "hlr_refresh_REFRESHED")

            // And the identity slot is untouched. On the pre-fix tree this reads
            // `""` — a successful Keychain upsert of the stub user's empty id —
            // and every lease-fenced store goes silent from here on.
            #expect(
                keychain.getString(forKey: KeychainKey.userID) == Self.realUserID,
                """
                EXPECTED_RED: 24-01-A the refresh path wrote an empty KeychainKey.userID over a good one
                Every lease-fenced store refuses from here on, and the dashboard skeleton is permanent.
                """
            )

            // The already-guarded neighbour is the control: it behaved correctly
            // all along, which is what made the missing guard visible.
            #expect(keychain.getString(forKey: KeychainKey.userDisplayName) == "Alex")
        }

        // MARK: - Half two: the repair, from a poisoned pre-existing install

        /// Behavioural RED 24-01-B — on the pre-fix tree no request is issued.
        ///
        /// The starting state is the operator's device: token valid, user id
        /// blanked, name hint intact. The assertion is not about a phase or a
        /// flag — it is that a **lease-fenced store puts a request on the wire**,
        /// which is the thing that has not happened on his device for four
        /// builds.
        @Test("a poisoned pre-existing install heals on bootstrap and a fenced store issues its request")
        func poisonedInstallHealsAndAFencedStoreIssuesItsRequest() async throws {
            let keychain = try Self.poisonedInstallKeychain()
            // Precondition, asserted rather than assumed: we are starting from
            // the broken state, not from a fresh install.
            #expect(keychain.getString(forKey: KeychainKey.userID)?.isEmpty == true)
            #expect(keychain.getString(forKey: KeychainKey.authToken) != nil)

            let transport = MockURLProtocolSession()
            defer { transport.invalidate() }
            let wire = WireLog()
            transport.install { request in
                wire.record(request)
                let path = request.url?.path ?? ""
                if path == "/api/dashboard/summary" {
                    return Self.ok(request, Self.dashboardSummaryBody())
                }
                if path == "/api/auth/me" {
                    return Self.ok(request, Self.meBody())
                }
                return Self.ok(request, Self.refreshBody())
            }

            let api = makeAPI(session: transport, keychain: keychain)
            let service = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            let registry = AuthenticatedSessionLeaseRegistry()
            let (defaults, suite) = try isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }

            let authStore = AuthStore(
                auth: service,
                keychain: keychain,
                syncMode: nil,
                defaults: defaults,
                sessionRegistry: registry
            )
            // Built exactly the way `AppContainer.swift:468` builds it: the
            // shared registry, and a `userIDProvider` that reads the Keychain
            // slot the refresh poisoned.
            let dashboard = DashboardStore(
                repo: DashboardRepository(api: api),
                swr: nil,
                authenticatedSessionRegistry: registry,
                userIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
            )

            await authStore.bootstrap()
            await dashboard.load()

            // THE assertion: the fenced store spoke. On the pre-fix tree the
            // owner id trims to empty, `captureAuthenticatedSessionLease()`
            // returns nil, `recordRefusal(.leaseUnavailable)` fires and this
            // count stays at zero — nothing was ever sent.
            let summaryRequests = wire.count(of: "/api/dashboard/summary")
            #expect(
                summaryRequests == 1,
                """
                EXPECTED_RED: 24-01-B a lease-fenced store issued no request from a poisoned install
                The empty Keychain user id survives restarts and app updates, so this state is permanent \
                until the identity is recovered — a guarded build alone never repairs it.
                """
            )
            // The consequences below are only meaningful once a request was
            // issued; reporting them as separate failures would multiply one
            // defect into five and obscure which observation is load-bearing.
            guard summaryRequests == 1 else { return }

            // The consequence the operator actually looks at: content, not the
            // skeleton that "no summary, no error, not loading" produces.
            #expect(dashboard.summary != nil)
            #expect(
                DashboardMetricsSectionState.resolve(
                    hasSummary: dashboard.summary != nil,
                    hasError: dashboard.error != nil,
                    isLoading: dashboard.isLoading
                ) == .content,
                "a refused load publishes no error, so the metrics section resolves to a permanent .skeleton"
            )

            // The slot is repaired on disk, so the NEXT launch needs no recovery
            // at all — the healing is durable, not per-session.
            #expect(keychain.getString(forKey: KeychainKey.userID) == Self.realUserID)
            #expect(wire.count(of: "/api/auth/me") == 1, "exactly one recovery read, never a loop")
        }

        /// The recovery must be invisible to a healthy install: no extra network
        /// call, no behaviour change. This is what keeps the repair from
        /// becoming a cold-launch tax on every user who was never poisoned.
        @Test("a healthy install bootstraps without any recovery read")
        func healthyInstallIssuesNoRecoveryRead() async throws {
            let keychain = InMemoryKeychain()
            try keychain.setString("hlk_bearer_LIVE", forKey: KeychainKey.authToken)
            try keychain.setString(Self.realUserID, forKey: KeychainKey.userID)

            let transport = MockURLProtocolSession()
            defer { transport.invalidate() }
            let wire = WireLog()
            transport.install { request in
                wire.record(request)
                return Self.ok(request, Self.meBody(id: "usr_SHOULD_NEVER_BE_READ"))
            }

            let service = AuthService(
                api: makeAPI(session: transport, keychain: keychain),
                keychain: keychain,
                passkey: NoopPasskey()
            )
            let (defaults, suite) = try isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let authStore = AuthStore(
                auth: service,
                keychain: keychain,
                syncMode: nil,
                defaults: defaults,
                sessionRegistry: AuthenticatedSessionLeaseRegistry()
            )

            await authStore.bootstrap()

            #expect(wire.count(of: "/api/auth/me") == 0, "a healthy install must not pay for the repair")
            #expect(keychain.getString(forKey: KeychainKey.userID) == Self.realUserID)
            let authenticated: Bool = if case let .authenticated(user) = authStore.phase {
                user.id == Self.realUserID
            } else {
                false
            }
            #expect(authenticated)
        }

        /// The repair cannot wedge the app and cannot loop. An offline launch on
        /// a poisoned device must return promptly, leave the shipped bootstrap
        /// behaviour exactly as it was, and try again NEXT launch — never within
        /// this one.
        @Test("a failing recovery neither wedges the launch nor loops")
        func failingRecoveryIsBoundedAndDoesNotLoop() async throws {
            let keychain = try Self.poisonedInstallKeychain()

            let transport = MockURLProtocolSession()
            defer { transport.invalidate() }
            let wire = WireLog()
            transport.install { request in
                wire.record(request)
                throw URLError(.notConnectedToInternet)
            }

            let service = AuthService(
                api: makeAPI(session: transport, keychain: keychain),
                keychain: keychain,
                passkey: NoopPasskey()
            )
            let (defaults, suite) = try isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let authStore = AuthStore(
                auth: service,
                keychain: keychain,
                syncMode: nil,
                defaults: defaults,
                sessionRegistry: AuthenticatedSessionLeaseRegistry()
            )

            // Three bootstraps in one process. The launch completes every time
            // (no wedge), and the recovery is attempted at most once (no loop).
            await authStore.bootstrap()
            await authStore.bootstrap()
            await authStore.bootstrap()

            #expect(
                wire.count(of: "/api/auth/me") <= 1,
                "the recovery must be latched per process — an offline poisoned device must not retry in a loop"
            )
            // Shipped behaviour is preserved on failure: the shell still resolves
            // rather than hanging on `.unknown`.
            let resolved = switch authStore.phase {
            case .unknown: false
            default: true
            }
            #expect(resolved, "a failed recovery must leave the launch resolved, never parked on .unknown")
        }

        // MARK: - The locked-out install

        /// The operator was advised to log out and back in as a stopgap, and
        /// then could not sign in at all. This settles whether the blanked
        /// identity is what blocks re-authentication — asked from the LOCKED-OUT
        /// starting state rather than from a convenient one: a Keychain that
        /// holds a blank user id and **no valid session**.
        ///
        /// It is also the regression this plan's own guard could plausibly have
        /// introduced. `persist` no longer writes an empty id — so a real login,
        /// which DOES carry a `user` block, must still write its real one, and
        /// the account must still reach the authenticated shell with a working
        /// lease. A guard that silently stopped the login write would lock every
        /// user out permanently on the next build, which is a far worse defect
        /// than the one being fixed.
        @Test("a locked-out install with a blank user id can sign in and reach a working session")
        func lockedOutInstallWithABlankUserIDCanSignInAgain() async throws {
            let keychain = InMemoryKeychain()
            // Locked out: the identity slot is blank and there is NO session.
            try keychain.setString("", forKey: KeychainKey.userID)
            #expect(keychain.getString(forKey: KeychainKey.authToken) == nil)

            let transport = MockURLProtocolSession()
            defer { transport.invalidate() }
            let wire = WireLog()
            transport.install { request in
                wire.record(request)
                let path = request.url?.path ?? ""
                if path == "/api/dashboard/summary" {
                    return Self.ok(request, Self.dashboardSummaryBody())
                }
                return Self.ok(request, Self.loginBody())
            }

            let api = makeAPI(session: transport, keychain: keychain)
            let service = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())
            let registry = AuthenticatedSessionLeaseRegistry()
            let (defaults, suite) = try isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let authStore = AuthStore(
                auth: service,
                keychain: keychain,
                syncMode: nil,
                defaults: defaults,
                sessionRegistry: registry
            )
            let dashboard = DashboardStore(
                repo: DashboardRepository(api: api),
                swr: nil,
                authenticatedSessionRegistry: registry,
                userIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
            )

            await authStore.login(email: "operator@example.com", password: "pw")

            // The login wrote a REAL id over the blank one. The guard suppresses
            // empty writes, never real ones.
            #expect(keychain.getString(forKey: KeychainKey.userID) == Self.realUserID)
            #expect(keychain.getString(forKey: KeychainKey.authToken) == "hlk_bearer_FRESH")
            #expect(authStore.phase == .authenticating(User(
                id: Self.realUserID,
                email: "operator@example.com",
                username: "operator",
                displayName: "Alex",
                createdAt: nil
            )))

            // The server branch parks in `.authenticating` until onboarding's
            // permission steps finish; `completeOnboarding()` is the promotion.
            authStore.completeOnboarding()
            let authenticated: Bool = if case let .authenticated(user) = authStore.phase {
                user.id == Self.realUserID
            } else {
                false
            }
            #expect(authenticated)

            // And the session actually works: a lease-fenced store speaks.
            await dashboard.load()
            #expect(wire.count(of: "/api/dashboard/summary") == 1)
            #expect(dashboard.summary != nil)
        }

        /// The escape hatch, proven rather than suggested.
        ///
        /// A successful login PERSISTS the session before any routing happens
        /// (`AuthService.login` → `persist`), and `AuthStore.phase` is in-memory
        /// only. So an install whose login succeeded but whose on-screen routing
        /// was lost still holds a complete, valid credential set on disk, and a
        /// COLD RELAUNCH — a new `AuthStore` over the same Keychain — resolves
        /// straight to `.authenticated` with a working lease.
        ///
        /// This is the difference between backgrounding the app and force-quitting
        /// it: only process death re-runs `bootstrap()`.
        @Test("a cold relaunch after a successful login reaches the authenticated shell")
        func coldRelaunchAfterASuccessfulLoginReachesTheShell() async throws {
            let keychain = InMemoryKeychain()
            let transport = MockURLProtocolSession()
            defer { transport.invalidate() }
            let wire = WireLog()
            transport.install { request in
                wire.record(request)
                let path = request.url?.path ?? ""
                if path == "/api/dashboard/summary" {
                    return Self.ok(request, Self.dashboardSummaryBody())
                }
                return Self.ok(request, Self.loginBody())
            }
            let api = makeAPI(session: transport, keychain: keychain)
            let service = AuthService(api: api, keychain: keychain, passkey: NoopPasskey())

            // Launch one: the login succeeds and persists, but this process
            // never promotes past `.authenticating` — the routing was lost.
            let (firstDefaults, firstSuite) = try isolatedDefaults()
            defer { firstDefaults.removePersistentDomain(forName: firstSuite) }
            let firstLaunch = AuthStore(
                auth: service,
                keychain: keychain,
                syncMode: nil,
                defaults: firstDefaults,
                sessionRegistry: AuthenticatedSessionLeaseRegistry()
            )
            await firstLaunch.login(email: "operator@example.com", password: "pw")
            let parked = if case .authenticating = firstLaunch.phase { true } else { false }
            #expect(parked, "the server branch parks in .authenticating until onboarding completes")

            // Launch two: a NEW store over the SAME Keychain — process death,
            // nothing carried over but what is on disk.
            let registry = AuthenticatedSessionLeaseRegistry()
            let (secondDefaults, secondSuite) = try isolatedDefaults()
            defer { secondDefaults.removePersistentDomain(forName: secondSuite) }
            let coldRelaunch = AuthStore(
                auth: service,
                keychain: keychain,
                syncMode: nil,
                defaults: secondDefaults,
                sessionRegistry: registry
            )
            let dashboard = DashboardStore(
                repo: DashboardRepository(api: api),
                swr: nil,
                authenticatedSessionRegistry: registry,
                userIDProvider: { [keychain] in keychain.getString(forKey: KeychainKey.userID) }
            )

            await coldRelaunch.bootstrap()

            let authenticated: Bool = if case let .authenticated(user) = coldRelaunch.phase {
                user.id == Self.realUserID
            } else {
                false
            }
            #expect(authenticated, "a persisted session must resolve to .authenticated on the next launch")
            #expect(wire.count(of: "/api/auth/me") == 0, "a real id was persisted, so no recovery read is needed")

            await dashboard.load()
            #expect(wire.count(of: "/api/dashboard/summary") == 1)
            #expect(dashboard.summary != nil)
        }

        // MARK: - Half three: the fence against its return

        /// Behavioural RED 24-01-C — on the pre-fix tree the refresh leg trips this.
        ///
        /// Not "the call site we fixed" — EVERY production persist entry point,
        /// each driven for real against a server that answers WITHOUT a `user`
        /// block. That answer is legal on the refresh route and is exactly what
        /// synthesises the stub; any path that persists it must refuse to write
        /// the stub's empty id.
        @Test("no production persist path ever writes an empty KeychainKey.userID")
        func noPersistPathWritesAnEmptyUserID() async throws {
            let keychain = UserIDWriteTrap()
            try keychain.setString("hlk_bearer_OLD", forKey: KeychainKey.authToken)
            try keychain.setString("hlr_refresh_OLD", forKey: KeychainKey.refreshToken)
            try keychain.setString(Self.realUserID, forKey: KeychainKey.userID)

            let transport = MockURLProtocolSession()
            defer { transport.invalidate() }
            // Every auth route answers with the user-less token bundle — the
            // shape that produces `User(id: "")`.
            transport.install { request in
                Self.ok(request, Self.refreshBody())
            }

            let service = AuthService(
                api: makeAPI(session: transport, keychain: keychain),
                keychain: keychain,
                passkey: NoopPasskey()
            )

            _ = await service.refresh()
            _ = try? await service.login(email: "operator@example.com", password: "pw")
            _ = try? await service.verifyMFA(ticket: "t", method: .totp, code: "000000")
            _ = try? await service.oidcNativeTokenExchange(code: "c", codeVerifier: "v")
            _ = try? await service.webLoginTokenExchange(code: "c", codeVerifier: "v")
            _ = try? await service.register(email: "operator@example.com", username: "operator", password: "pw")

            let violations = keychain.emptyUserIDWrites
            #expect(
                violations == 0,
                """
                EXPECTED_RED: 24-01-C a production persist path wrote an empty KeychainKey.userID
                Observed \(violations) empty write(s): \(keychain.emptyUserIDWriteSites.joined(separator: ", ")). \
                An empty upsert is indistinguishable from a real id to every lease-fenced store.
                """
            )
            guard violations == 0 else { return }
            #expect(keychain.getString(forKey: KeychainKey.userID) == Self.realUserID)
        }

        /// The structural half. The behavioural trap above can only see the
        /// paths a unit test can drive; this one enumerates every production
        /// write of the slot and requires each to be either guarded or a named,
        /// non-empty constant. A NEW unguarded write site turns this red the
        /// moment it is added, which is the property that keeps the defect from
        /// returning by another route.
        ///
        /// Precedent: `MeasurementBatchCompositionContractTests` reads shipped
        /// source the same way.
        @Test("every production write site of KeychainKey.userID is guarded against an empty value")
        func everyProductionWriteSiteIsGuarded() throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appRoot = root.appendingPathComponent("HealthLog")

            var writeSites: [String] = []
            let enumerator = try #require(FileManager.default.enumerator(
                at: appRoot,
                includingPropertiesForKeys: nil
            ))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                guard source.contains("KeychainKey.userID") else { continue }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                    guard line.contains("KeychainKey.userID") else { continue }
                    // A write is either a direct `setString(_:forKey:)` or an
                    // append into `persist`'s pending-write list.
                    let isDirectWrite = line.contains("setString(") && line.contains("forKey: KeychainKey.userID")
                    let isPendingWrite = line.contains("pendingWrites.append((KeychainKey.userID")
                    guard isDirectWrite || isPendingWrite else { continue }
                    writeSites.append("\(relative):\(index + 1)")
                }
            }

            // The complete, reviewed inventory. Adding a site without adding it
            // here — and without guarding it — fails this test by name.
            let expected = [
                // The persist path. Guarded since 24-01: written only when the
                // session carries a non-empty id, mirroring the `userDisplayName`
                // write eight lines below it.
                "HealthLog/Services/AuthService.swift",
                // The 24-01 repair. Writes only what `trimmedNonEmptyHint`
                // resolved, so it can persist an id but never a blank.
                "HealthLog/Services/AuthService+IdentityRecovery.swift",
                // UI-test seeding only, behind `isAuthenticatedBoot`, and the
                // value is a non-empty compile-time constant.
                "HealthLog/App/HermeticUITestSupport.swift"
            ]
            let foundFiles = Set(writeSites.map { $0.components(separatedBy: ":")[0] })
            #expect(
                foundFiles == Set(expected),
                "unreviewed production write site(s) for KeychainKey.userID: \(writeSites.sorted())"
            )

            // And the persist write is guarded, not merely present. Both halves
            // in ONE assertion: a guard that is added while the unconditional
            // write survives beside it repairs nothing, so the two conditions
            // are one fact and must fail as one.
            let authService = try String(
                contentsOf: appRoot.appendingPathComponent("Services/AuthService.swift"),
                encoding: .utf8
            )
            let guardPresent = authService.contains("if let resolvedUserID = session.user.id.trimmedNonEmptyHint {")
            let unconditionalWriteGone = !authService
                .contains("pendingWrites.append((KeychainKey.userID, session.user.id))")
            #expect(
                guardPresent && unconditionalWriteGone,
                """
                EXPECTED_RED: 24-01-D the KeychainKey.userID write is not guarded on a non-empty id
                guardPresent=\(guardPresent) unconditionalWriteGone=\(unconditionalWriteGone). \
                The userDisplayName write eight lines below already carries this guard.
                """
            )

            // The repair's own write is fed by `trimmedNonEmptyHint`, so the
            // thing that heals the slot cannot itself become a way to blank it.
            let recovery = try String(
                contentsOf: appRoot.appendingPathComponent("Services/AuthService+IdentityRecovery.swift"),
                encoding: .utf8
            )
            #expect(recovery.contains("let recovered = user.id.trimmedNonEmptyHint"))
            #expect(recovery.contains("try keychain.setString(recovered, forKey: KeychainKey.userID)"))

            // The seeded UI-test id is a non-empty constant, so the third site
            // cannot poison anything either.
            let hermetic = try String(
                contentsOf: appRoot.appendingPathComponent("App/HermeticUITestSupport.swift"),
                encoding: .utf8
            )
            #expect(hermetic.contains("static let seededUserID"))
            #expect(!hermetic.contains("seededUserID = \"\""))
        }
    }

    // MARK: - Test doubles

    /// Records what actually reached the transport. The assertion this suite
    /// exists for is "a request was ISSUED", so it is counted at the wire, not
    /// inferred from a store's published state.
    ///
    /// Safe to count unguarded because `MockURLProtocolSession` owns its own
    /// handler: only this test's requests can ever reach it (CU-07's caveat
    /// applies to the process-global slot, which this suite does not use).
    private final class WireLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            paths.append(request.url?.path ?? "")
        }

        func count(of path: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return paths.filter { $0 == path }.count
        }
    }

    /// An in-memory Keychain that treats an empty or whitespace-only write to
    /// `KeychainKey.userID` as a recorded violation.
    ///
    /// It still PERFORMS the write — the trap observes, it does not fix — so the
    /// pre-fix tree behaves exactly as it does in the field and the test fails
    /// on the observation rather than on a divergence introduced by the double.
    private final class UserIDWriteTrap: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: Data] = [:]
        private var violations: [String] = []

        var emptyUserIDWrites: Int {
            lock.lock()
            defer { lock.unlock() }
            return violations.count
        }

        var emptyUserIDWriteSites: [String] {
            lock.lock()
            defer { lock.unlock() }
            return violations
        }

        func setString(_ value: String, forKey key: String) throws {
            if key == KeychainKey.userID, value.trimmedNonEmptyHint == nil {
                lock.lock()
                violations.append("empty write of \(value.debugDescription)")
                lock.unlock()
            }
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.encoding
            }
            try setData(data, forKey: key)
        }

        func getString(forKey key: String) -> String? {
            getData(forKey: key).flatMap { String(data: $0, encoding: .utf8) }
        }

        func setData(_ data: Data, forKey key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            store[key] = data
        }

        func getData(forKey key: String) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return store[key]
        }

        func remove(forKey key: String) throws {
            lock.lock()
            defer { lock.unlock() }
            store.removeValue(forKey: key)
        }

        func removeAll() throws {
            lock.lock()
            defer { lock.unlock() }
            store.removeAll()
        }
    }

#endif
