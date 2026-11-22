import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog

    // swiftlint:disable force_unwrapping

    /// An unchanged APNs token is sent again once a day, so the server's
    /// `Device.lastSeen` (stamped only by `POST /api/devices`) stays fresh and
    /// the iPad does not take over reminders from an iPhone that simply was
    /// not cold-started for a week.
    @Suite("Device registration: refreshed once a day", .serialized, .mockURLSession)
    @MainActor
    struct DeviceRegistrationRefreshTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )
        private static let start = Date(timeIntervalSince1970: 1_792_000_000)
        private static let hour: TimeInterval = 3600

        private final class Clock {
            var now: Date
            init(_ now: Date) {
                self.now = now
            }
        }

        private static func makeDefaults() throws -> UserDefaults {
            try #require(UserDefaults(suiteName: "test.notif.refresh.\(UUID().uuidString)"))
        }

        private func makeService(
            clock: Clock,
            defaults: UserDefaults? = nil,
            user: String = "usr_phone"
        ) throws -> NotificationService {
            let keychain = InMemoryKeychain()
            try keychain.setString("token", forKey: KeychainKey.authToken)
            let api = APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
            let defaults = try defaults ?? Self.makeDefaults()
            let owner = InMemoryKeychain()
            try owner.setString(user, forKey: KeychainKey.userID)
            let service = NotificationService(
                api: api,
                environment: Self.env,
                keychain: owner,
                deepLinks: DeepLinkRouter(router: AppRouter(), isAuthenticated: { true }),
                defaults: defaults
            )
            service.registrationClock = { clock.now }
            return service
        }

        @Test("same token: no POST within a day, one POST after it, then quiet again")
        func dailyRefresh() async throws {
            nonisolated(unsafe) var posts = 0
            MockURLProtocol.install { req in
                if req.targets("/api/devices") { posts += 1 }
                let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data())
            }
            let clock = Clock(Self.start)
            let service = try makeService(clock: clock)
            let token = Data(repeating: 0xAB, count: 32)

            await service.didRegister(deviceToken: token)
            #expect(posts == 1)

            clock.now = Self.start.addingTimeInterval(23 * Self.hour)
            await service.didRegister(deviceToken: token)
            #expect(posts == 1, "a foreground within the day sends nothing")

            clock.now = Self.start.addingTimeInterval(24 * Self.hour)
            await service.didRegister(deviceToken: token)
            #expect(posts == 2, "a day later the same token is sent again")

            clock.now = Self.start.addingTimeInterval(30 * Self.hour)
            await service.didRegister(deviceToken: token)
            #expect(posts == 2)
        }

        @Test("a failed POST is not remembered, so the next foreground tries again")
        func failureIsRetried() async throws {
            nonisolated(unsafe) var posts = 0
            MockURLProtocol.install { req in
                if req.targets("/api/devices") { posts += 1 }
                let response = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data())
            }
            let clock = Clock(Self.start)
            let service = try makeService(clock: clock)
            let token = Data(repeating: 0xCD, count: 32)

            await service.didRegister(deviceToken: token)
            let afterFirst = posts
            #expect(afterFirst >= 1)
            #expect(NotificationService.loadSentRegistration(from: service.defaults) == nil)
            await service.didRegister(deviceToken: token)
            #expect(posts > afterFirst)
        }

        @Test("a relaunch within the day sends nothing, after the day it sends once")
        func lockSurvivesARelaunch() async throws {
            nonisolated(unsafe) var posts = 0
            MockURLProtocol.install { req in
                if req.targets("/api/devices") { posts += 1 }
                let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data())
            }
            let defaults = try Self.makeDefaults()
            let clock = Clock(Self.start)
            let token = Data(repeating: 0xAB, count: 32)
            let service1 = try makeService(clock: clock, defaults: defaults)
            await service1.didRegister(deviceToken: token)
            #expect(posts == 1)

            clock.now = Self.start.addingTimeInterval(2 * Self.hour)
            let service2 = try makeService(clock: clock, defaults: defaults)
            await service2.didRegister(deviceToken: token)
            #expect(posts == 1, "a cold start two hours later")

            clock.now = Self.start.addingTimeInterval(25 * Self.hour)
            let service3 = try makeService(clock: clock, defaults: defaults)
            await service3.didRegister(deviceToken: token)
            #expect(posts == 2)
        }

        @Test("another account on the same device registers at once")
        func otherAccountRegisters() async throws {
            nonisolated(unsafe) var posts = 0
            MockURLProtocol.install { req in
                if req.targets("/api/devices") { posts += 1 }
                let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (response, Data())
            }
            let defaults = try Self.makeDefaults()
            let clock = Clock(Self.start)
            let token = Data(repeating: 0xAB, count: 32)
            let service4 = try makeService(clock: clock, defaults: defaults, user: "usr_a")
            await service4.didRegister(deviceToken: token)
            let service5 = try makeService(clock: clock, defaults: defaults, user: "usr_b")
            await service5.didRegister(deviceToken: token)
            #expect(posts == 2)
        }

        @Test("the rule: another token or account counts as new, a clock that went back too")
        func rule() {
            let state = NotificationService.RegistrationState(tokenHex: "aa", env: .sandbox, liveActivityPushToken: nil)
            let other = NotificationService.RegistrationState(tokenHex: "bb", env: .sandbox, liveActivityPushToken: nil)
            let sent = NotificationService.SentRegistration(
                fingerprint: NotificationService.fingerprint(state, owner: "usr_a"),
                sentAt: Self.start
            )
            let later = Self.start.addingTimeInterval(Self.hour)
            #expect(NotificationService.registrationIsCurrent(state, owner: "usr_a", sent: sent, now: later))
            #expect(!NotificationService.registrationIsCurrent(other, owner: "usr_a", sent: sent, now: later))
            #expect(!NotificationService.registrationIsCurrent(state, owner: "usr_b", sent: sent, now: later))
            #expect(!NotificationService.registrationIsCurrent(state, owner: "usr_a", sent: nil, now: later))
            #expect(!NotificationService.registrationIsCurrent(state, owner: "usr_a", sent: sent, now: Self.start.addingTimeInterval(-60)))
            #expect(sent.fingerprint.count == 64, "a SHA-256 digest, never the token")
        }
    }

    // swiftlint:enable force_unwrapping
#endif
