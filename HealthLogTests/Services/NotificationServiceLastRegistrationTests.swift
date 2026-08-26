import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    // swiftlint:disable force_unwrapping

    /// v0.6.0.8 — `NotificationService.LastRegistrationSnapshot` is the
    /// operator-facing audit blob persisted under
    /// `dev.healthlog.app.notif.lastRegistration.v1`. These tests pin
    /// the contract the diagnostics surface relies on:
    ///   - Token persistence keeps only first 8 + last 8 hex chars
    ///     (PII discipline — full token never lands in UserDefaults).
    ///   - Successful register persists `serverStatus = 200` + nil error.
    ///   - 409 path still persists the snapshot with status + sanitized msg.
    ///   - Dedup short-circuit refreshes `lastRegistrationAttemptAt` but
    ///     leaves the previous status alone.
    ///   - `forceRefreshRegistration()` bypasses the dedup.
    ///   - Decoding the persisted blob discards `fullTokenHex` so a
    ///     restarted app has no way to leak the credential.
    @Suite("NotificationService — lastRegistrationSnapshot audit", .serialized)
    @MainActor
    struct NotificationServiceLastRegistrationTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.6.0.8",
            buildNumber: "38"
        )

        private static let tokenHex = String(repeating: "ab", count: 32) +
            String(repeating: "cd", count: 32) // 128 hex chars, prefix "abab…", suffix "…cdcd"

        private func makeAPI() -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            return APIClient(
                environment: Self.env,
                keychain: keychain,
                sessionConfiguration: .mock()
            )
        }

        private func makeDefaults() -> UserDefaults {
            let suiteName = "test.notif.lastRegistration.\(UUID().uuidString)"
            return UserDefaults(suiteName: suiteName)!
        }

        private func makeService(api: APIClient, defaults: UserDefaults) -> NotificationService {
            let appRouter = AppRouter()
            let deepLinks = DeepLinkRouter(router: appRouter, isAuthenticated: { true })
            return NotificationService(
                api: api,
                environment: Self.env,
                keychain: InMemoryKeychain(),
                deepLinks: deepLinks,
                defaults: defaults
            )
        }

        nonisolated static func okResponse(_ req: URLRequest, status: Int = 200) -> HTTPURLResponse {
            HTTPURLResponse(
                url: req.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        }

        // MARK: - PII discipline

        @Test("setToken stores prefix + suffix at 8 hex chars each — never the full token")
        func setTokenTruncatesToPrefixSuffix() {
            var snap = NotificationService.LastRegistrationSnapshot()
            snap.setToken(hex: Self.tokenHex)
            #expect(snap.tokenPrefix?.count == 8)
            #expect(snap.tokenSuffix?.count == 8)
            #expect(snap.tokenPrefix == "abababab")
            #expect(snap.tokenSuffix == "cdcdcdcd")
            // fullTokenHex is held in memory but never persisted.
            #expect(snap.fullTokenHex == Self.tokenHex)
        }

        @Test("Codable roundtrip drops fullTokenHex — disk never sees the full token")
        func codableDropsFullToken() throws {
            var snap = NotificationService.LastRegistrationSnapshot()
            snap.setToken(hex: Self.tokenHex)
            snap.environment = "sandbox"
            snap.lastRegistrationServerStatus = 200
            let data = try JSONEncoder().encode(snap)
            let raw = String(data: data, encoding: .utf8) ?? ""
            #expect(!raw.contains(Self.tokenHex))
            #expect(raw.contains("abababab"))
            #expect(raw.contains("cdcdcdcd"))
            let decoded = try JSONDecoder().decode(NotificationService.LastRegistrationSnapshot.self, from: data)
            #expect(decoded.tokenPrefix == "abababab")
            #expect(decoded.tokenSuffix == "cdcdcdcd")
            #expect(decoded.fullTokenHex == nil)
        }

        // MARK: - UserDefaults persistence

        @Test("Snapshot persisted under the v1 key roundtrips through UserDefaults")
        func userDefaultsRoundtrip() {
            let defaults = makeDefaults()
            var snap = NotificationService.LastRegistrationSnapshot()
            snap.setToken(hex: Self.tokenHex)
            snap.environment = "sandbox"
            snap.lastRegistrationAttemptAt = Date(timeIntervalSince1970: 1_779_710_400)
            snap.lastRegistrationServerStatus = 200
            NotificationService.persist(snap, to: defaults)

            // Direct key lookup so a future key rename breaks loud.
            let data = defaults.data(forKey: NotificationService.lastRegistrationDefaultsKey)
            #expect(data != nil)

            let loaded = NotificationService.loadLastRegistration(from: defaults)
            #expect(loaded?.tokenPrefix == "abababab")
            #expect(loaded?.tokenSuffix == "cdcdcdcd")
            #expect(loaded?.environment == "sandbox")
            #expect(loaded?.lastRegistrationServerStatus == 200)
            // Disk roundtrip drops the in-memory shadow.
            #expect(loaded?.fullTokenHex == nil)
        }

        @Test("Service hydrates lastRegistrationSnapshot from UserDefaults on init")
        func initHydratesFromDefaults() {
            let defaults = makeDefaults()
            var snap = NotificationService.LastRegistrationSnapshot()
            snap.setToken(hex: Self.tokenHex)
            snap.environment = "production"
            snap.lastRegistrationServerStatus = 200
            NotificationService.persist(snap, to: defaults)

            let svc = makeService(api: makeAPI(), defaults: defaults)
            #expect(svc.lastRegistrationSnapshot?.tokenPrefix == "abababab")
            #expect(svc.lastRegistrationSnapshot?.environment == "production")
            #expect(svc.lastRegistrationSnapshot?.lastRegistrationServerStatus == 200)
        }

        // MARK: - register(...) snapshot capture

        @Test("didRegister captures snapshot with serverStatus=200 on success")
        func successCaptures200() async {
            let defaults = makeDefaults()
            let api = makeAPI()
            MockURLProtocol.handler = { req in
                (Self.okResponse(req, status: 200), Data())
            }
            let svc = makeService(api: api, defaults: defaults)

            // 64-byte sample — hexEncodedString will yield 128 chars.
            let token = Data(repeating: 0xAB, count: 64)
            await svc.didRegister(deviceToken: token)

            let snap = svc.lastRegistrationSnapshot
            #expect(snap?.lastRegistrationServerStatus == 200)
            #expect(snap?.lastRegistrationError == nil)
            #expect(snap?.tokenPrefix == "abababab")
            #expect(snap?.tokenSuffix == "abababab")
            #expect(snap?.environment != nil)
            #expect(snap?.lastRegistrationAttemptAt != nil)

            // Disk mirror reflects the captured fields.
            let onDisk = NotificationService.loadLastRegistration(from: defaults)
            #expect(onDisk?.lastRegistrationServerStatus == 200)
            #expect(onDisk?.fullTokenHex == nil)
        }

        @Test("409 server-error path persists status + sanitized message but keeps lastRegistration cached")
        func server409CapturesStatusAndSanitizedError() async {
            let defaults = makeDefaults()
            let api = makeAPI()
            MockURLProtocol.handler = { req in
                let body = #"{"error":{"message":"token already bound to user xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}}"#
                return (Self.okResponse(req, status: 409), Data(body.utf8))
            }
            let svc = makeService(api: api, defaults: defaults)

            let token = Data(repeating: 0xAB, count: 64)
            await svc.didRegister(deviceToken: token)

            let snap = svc.lastRegistrationSnapshot
            #expect(snap?.lastRegistrationServerStatus == 409)
            // UUIDs are scrubbed by LogSanitizer; the literal "redacted"
            // marker proves the sanitizer ran.
            if let err = snap?.lastRegistrationError {
                #expect(!err.contains("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"))
            } else {
                Issue.record("Expected sanitized error message after 409")
            }
        }

        // MARK: - Force-fresh

        @Test("forceRefreshRegistration returns nil when no token has been cached")
        func forceFreshWithoutTokenReturnsNil() async {
            let defaults = makeDefaults()
            let svc = makeService(api: makeAPI(), defaults: defaults)
            let result = await svc.forceRefreshRegistration()
            #expect(result == nil)
        }

        @Test("forceRefreshRegistration bypasses dedup and re-posts to /api/devices")
        func forceFreshBypassesDedup() async {
            let defaults = makeDefaults()
            let api = makeAPI()
            nonisolated(unsafe) var requestCount = 0
            MockURLProtocol.handler = { req in
                // CU-07: the handler is process-global — count only the
                // device-registration POST this test drives.
                if req.targets("/api/devices") { requestCount += 1 }
                return (Self.okResponse(req, status: 200), Data())
            }
            let svc = makeService(api: api, defaults: defaults)

            let token = Data(repeating: 0xAB, count: 64)
            await svc.didRegister(deviceToken: token)
            #expect(requestCount == 1)

            // Same token again — dedup short-circuits, no new POST.
            await svc.didRegister(deviceToken: token)
            #expect(requestCount == 1)

            // Force-fresh forces a second POST with the cached token.
            let result = await svc.forceRefreshRegistration()
            #expect(requestCount == 2)
            #expect(result?.lastRegistrationServerStatus == 200)
        }
    }

    // swiftlint:enable force_unwrapping
#endif
