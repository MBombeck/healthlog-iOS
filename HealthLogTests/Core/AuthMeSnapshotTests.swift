// The launch gates (`PushRelay`, onboarding tour) are app-target symbols.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Synchronization
    import Testing

    // swiftlint:disable force_unwrapping

    /// Counts the requests each path received, behind a `Mutex`.
    private final class PathCounter: Sendable {
        private let counts = Mutex([String: Int]())

        func bump(_ key: String) {
            counts.withLock { $0[key, default: 0] += 1 }
        }

        func count(_ key: String) -> Int {
            counts.withLock { $0[key] ?? 0 }
        }
    }

    /// A clock the test moves by hand.
    private final class ManualClock: Sendable {
        private let offset = Mutex(Duration.zero)
        private let origin = ContinuousClock.now

        func advance(_ by: Duration) {
            offset.withLock { $0 += by }
        }

        var now: ContinuousClock.Instant {
            origin + offset.withLock { $0 }
        }
    }

    /// **D5 #2 — `GET /api/auth/me` at start-up.**
    ///
    /// The cold start fans out to every repository that reads its own slice of
    /// the route. The first test replays that fan-out as the launch issued it
    /// before the fix (three profile loads, two hydrations each, the module
    /// gate twice, relay, disclaimer, second factor and tour, one after the
    /// other) against a client without the snapshot, and counts. The second
    /// replays the launch as it runs now (one profile load, the gates side by
    /// side) against the real client.
    @Suite("AuthMeSnapshot: one /api/auth/me per launch (D5 #2)", .serialized, .mockURLSession)
    struct AuthMeSnapshotTests {
        static let meJSON = """
        {"data":{
          "id":"u-1","email":"a@example.invalid","username":"a",
          "disclaimerAcknowledgedAt":"2026-01-01T00:00:00.000Z",
          "onboardingTourCompleted":true,
          "unitPreference":"metric",
          "modules":{"cycle":false},
          "moduleAccess":{}
        },"error":null}
        """

        private static func ok(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        private func makeClient(counter: PathCounter, keychain: InMemoryKeychain = InMemoryKeychain()) -> APIClient {
            try? keychain.setString("token-a", forKey: KeychainKey.authToken)
            MockURLProtocol.install { request in
                let path = request.url!.path
                counter.bump("\(request.httpMethod ?? "?") \(path)")
                if path == "/api/auth/me" { return Self.ok(request, Self.meJSON) }
                return Self.ok(request, #"{"data":{"acknowledgedVersion":"1"},"error":null}"#)
            }
            return APIClient(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://test.healthlog.local")!,
                    bundleID: "dev.healthlog.app",
                    appVersion: "1.7.0",
                    buildNumber: "1"
                ),
                keychain: keychain,
                sessionConfiguration: .mock()
            )
        }

        /// The `/api/auth/me` readers of a cold start, through the real
        /// repositories. `profileLoads` is how many times the settings store
        /// loaded (each load hydrates on `.cached` and again on `.fresh`);
        /// `parallelGates` runs the four launch gates side by side.
        private func coldStartReads(api: APIClient, profileLoads: Int, parallelGates: Bool) async throws {
            let settings = SettingsRepository(api: api)
            let modules = ModuleGateRepository(api: api)
            let disclaimer = DisclaimerAckRepository(api: api)
            let mfa = MfaEnrollmentRepository(api: api, baseURL: URL(string: "https://test.healthlog.local"))
            let tour = OnboardingTourRepository(api: api)

            // RootView.loadProfileOnAuthenticationIfNeeded + preWarm's loads.
            for _ in 0 ..< profileLoads {
                _ = try await settings.authMeServerPrefs()
                _ = try await settings.authMeServerPrefs()
            }
            _ = try await modules.fetchModuleGateState()

            // push relay, disclaimer, second factor, setup tour.
            if parallelGates {
                async let relay: AuthMeRelay = api.send(.get("/api/auth/me"))
                async let ack = disclaimer.fetchAcknowledgedAt()
                async let enrol = mfa.fetchEnrollmentRequired()
                async let setup = tour.fetchSetupState()
                let (_, acknowledged, _, state) = try await (relay, ack, enrol, setup)
                #expect(acknowledged != nil, "the shared bytes decode into every projection")
                #expect(state.onboardingTourCompleted == true)
            } else {
                let _: AuthMeRelay = try await api.send(.get("/api/auth/me"))
                _ = try await disclaimer.fetchAcknowledgedAt()
                _ = try await mfa.fetchEnrollmentRequired()
                _ = try await tour.fetchSetupState()
            }

            // The foreground pass's module refresh on the first `.active`.
            _ = try await modules.fetchModuleGateState()
        }

        @Test("before: the launch fan-out sent /api/auth/me twelve times")
        func launchCountWithoutTheSnapshot() async throws {
            let counter = PathCounter()
            let api = makeClient(counter: counter)
            await api.configureAuthMeSnapshot(ttl: .zero)
            try await coldStartReads(api: api, profileLoads: 3, parallelGates: false)
            #expect(counter.count("GET /api/auth/me") == 12)
        }

        @Test("after: the launch sends /api/auth/me once")
        func launchCountWithTheSnapshot() async throws {
            let counter = PathCounter()
            let api = makeClient(counter: counter)
            try await coldStartReads(api: api, profileLoads: 1, parallelGates: true)
            #expect(counter.count("GET /api/auth/me") == 1)
        }

        @Test("readers arriving together share one request")
        func concurrentReadersShareOneFlight() async throws {
            let counter = PathCounter()
            let api = makeClient(counter: counter)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0 ..< 8 {
                    group.addTask { _ = try await ModuleGateRepository(api: api).fetchModuleGateState() }
                }
                try await group.waitForAll()
            }
            #expect(counter.count("GET /api/auth/me") == 1)
        }

        @Test("a write ends the snapshot: the next read sees the server's new state")
        func aWriteInvalidates() async throws {
            let counter = PathCounter()
            let api = makeClient(counter: counter)
            let disclaimer = DisclaimerAckRepository(api: api)
            _ = try await disclaimer.fetchAcknowledgedAt()
            _ = try await disclaimer.acknowledge(version: "1")
            _ = try await disclaimer.fetchAcknowledgedAt()
            #expect(counter.count("GET /api/auth/me") == 2)
        }

        @Test("the snapshot expires after its lifetime")
        func theSnapshotExpires() async throws {
            let counter = PathCounter()
            let clock = ManualClock()
            let api = makeClient(counter: counter)
            await api.configureAuthMeSnapshot(ttl: AuthMeSnapshot.defaultTTL, now: { clock.now })
            let modules = ModuleGateRepository(api: api)
            _ = try await modules.fetchModuleGateState()
            clock.advance(.seconds(9))
            _ = try await modules.fetchModuleGateState()
            #expect(counter.count("GET /api/auth/me") == 1)
            clock.advance(.seconds(2))
            _ = try await modules.fetchModuleGateState()
            #expect(counter.count("GET /api/auth/me") == 2)
        }

        @Test("another bearer never reads the previous session's answer")
        func anotherBearerIsAnotherKey() async throws {
            let counter = PathCounter()
            let keychain = InMemoryKeychain()
            let api = makeClient(counter: counter, keychain: keychain)
            let modules = ModuleGateRepository(api: api)
            _ = try await modules.fetchModuleGateState()
            try keychain.setString("token-b", forKey: KeychainKey.authToken)
            _ = try await modules.fetchModuleGateState()
            #expect(counter.count("GET /api/auth/me") == 2)
        }

        @Test("a failed answer is not kept")
        func aFailureIsNotKept() async throws {
            let counter = PathCounter()
            let api = makeClient(counter: counter)
            MockURLProtocol.install { request in
                counter.bump("GET \(request.url!.path)")
                // The first read fails, every later one answers.
                if counter.count("GET /api/auth/me") == 1 { return Self.ok(request, #"{"data":null,"error":"gone"}"#, status: 404) }
                return Self.ok(request, Self.meJSON)
            }
            let modules = ModuleGateRepository(api: api)
            await #expect(throws: (any Error).self) { _ = try await modules.fetchModuleGateState() }
            _ = try await modules.fetchModuleGateState()
            #expect(counter.count("GET /api/auth/me") == 2)
        }

        @Test("a read with a query or its own headers goes to the server on its own")
        func onlyPlainReadsShare() {
            let plain: APIRequest<AuthMeRelay> = .get("/api/auth/me")
            let queried: APIRequest<AuthMeRelay> = .get("/api/auth/me", query: [("x", "1")])
            let sub: APIRequest<AuthMeRelay> = .get("/api/auth/me/mfa")
            #expect(APIClient.sharesAuthMeSnapshot(plain))
            #expect(!APIClient.sharesAuthMeSnapshot(queried))
            #expect(!APIClient.sharesAuthMeSnapshot(sub))
        }
    }

    // swiftlint:enable force_unwrapping

#endif
