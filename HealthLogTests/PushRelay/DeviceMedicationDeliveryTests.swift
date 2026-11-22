import CryptoKit
import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog

    // swiftlint:disable force_unwrapping

    /// #179: every device says on `POST /api/devices` who delivers its
    /// medication reminders, and the body of a device that has not decided (or
    /// runs 1.6) stays exactly as before.
    @Suite("Device registration: per-device medication delivery", .serialized, .mockURLSession)
    @MainActor
    struct DeviceMedicationDeliveryTests {
        private static let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.7.0",
            buildNumber: "1"
        )

        private func makeService() throws -> NotificationService {
            let keychain = InMemoryKeychain()
            try keychain.setString("token", forKey: KeychainKey.authToken)
            let api = APIClient(environment: Self.env, keychain: keychain, sessionConfiguration: .mock())
            let owner = InMemoryKeychain()
            try owner.setString("usr_a", forKey: KeychainKey.userID)
            return try NotificationService(
                api: api,
                environment: Self.env,
                keychain: owner,
                deepLinks: DeepLinkRouter(router: AppRouter(), isAuthenticated: { true }),
                defaults: #require(UserDefaults(suiteName: "test.delivery.\(UUID().uuidString)"))
            )
        }

        private nonisolated static func body(of request: URLRequest) -> [String: Any]? {
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = stream.read(&buffer, maxLength: buffer.count)
                stream.close()
                data = count > 0 ? Data(buffer.prefix(count)) : nil
            }
            return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        // MARK: Rule

        @Test("the rule: planning and delivering is client, planning without delivering is server, not planning is null")
        func rule() {
            #expect(DeviceMedicationDeliveryReport.decide(plansLocally: true, deliversLocally: true) == .delivery(.client))
            #expect(DeviceMedicationDeliveryReport.decide(plansLocally: true, deliversLocally: false) == .delivery(.server))
            #expect(DeviceMedicationDeliveryReport.decide(plansLocally: false, deliversLocally: false) == .none)
            #expect(DeviceMedicationDeliveryReport.decide(plansLocally: false, deliversLocally: true) == .none)
        }

        // MARK: Encoding

        private func encoded(_ fields: DeviceRegistrationPushFields) throws -> [String: Any] {
            var body = DeviceRegistration(
                token: "d",
                bundleId: "b",
                locale: "de-DE",
                appVersion: "1.7",
                model: "m",
                apnsToken: "aa",
                apnsEnvironment: .production
            )
            body.pushFields = fields
            return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        }

        @Test("update path: an undecided device (and 1.6) sends no medicationDelivery and no relay key")
        func undecidedBodyUnchanged() throws {
            let json = try encoded(DeviceRegistrationPushFields())
            #expect(Set(json.keys) == ["token", "bundleId", "locale", "appVersion", "model", "apnsToken", "apnsEnvironment"])
            let state = NotificationService.RegistrationState(tokenHex: "aa", env: .production, liveActivityPushToken: nil)
            let parts = ["usr_a", "aa", "production", ""].joined(separator: "|")
            let legacy = SHA256Hex.of(parts)
            #expect(NotificationService.fingerprint(state, owner: "usr_a") == legacy)
        }

        @Test("client and server are sent as strings, 'not me' as an explicit null")
        func encodings() throws {
            #expect(try encoded(.init(medicationDelivery: .delivery(.client)))["medicationDelivery"] as? String == "client")
            #expect(try encoded(.init(medicationDelivery: .delivery(.server)))["medicationDelivery"] as? String == "server")
            let none = try encoded(.init(medicationDelivery: DeviceMedicationDeliveryReport.none))
            #expect(none.keys.contains("medicationDelivery"))
            #expect(none["medicationDelivery"] is NSNull)
        }

        @Test("a change of the decision changes the fingerprint, so it is posted")
        func fingerprintFollowsDecision() {
            let client = DeviceRegistrationPushFields(medicationDelivery: .delivery(.client)).fingerprint
            let none = DeviceRegistrationPushFields(medicationDelivery: DeviceMedicationDeliveryReport.none).fingerprint
            #expect(client != none)
            #expect(DeviceRegistrationPushFields().fingerprint.isEmpty)
        }

        // MARK: Two devices

        @Test("two devices with different answers each post their own value")
        func twoDevices() async throws {
            nonisolated(unsafe) var bodies: [[String: Any]] = []
            MockURLProtocol.install { req in
                if req.targets("/api/devices"), let body = Self.body(of: req) { bodies.append(body) }
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            let phone = try makeService()
            let pad = try makeService()
            // The phone plans and delivers; the iPad next to it does not plan.
            phone.medicationDeliveryReport = .decide(plansLocally: true, deliversLocally: true)
            pad.medicationDeliveryReport = .decide(plansLocally: false, deliversLocally: false)
            await phone.didRegister(deviceToken: Data(repeating: 0x01, count: 32))
            await pad.didRegister(deviceToken: Data(repeating: 0x02, count: 32))
            #expect(bodies.count == 2)
            #expect(bodies.first?["medicationDelivery"] as? String == "client")
            #expect(bodies.last?["medicationDelivery"] is NSNull)
        }

        @Test("a decision that arrives later re-posts once; the same decision again posts nothing")
        func lateDecisionPostsOnce() async throws {
            nonisolated(unsafe) var bodies: [[String: Any]] = []
            MockURLProtocol.install { req in
                if req.targets("/api/devices"), let body = Self.body(of: req) { bodies.append(body) }
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
            }
            let service = try makeService()
            await service.didRegister(deviceToken: Data(repeating: 0x03, count: 32))
            #expect(bodies.count == 1)
            #expect(bodies[0]["medicationDelivery"] == nil)
            await service.noteMedicationDelivery(.delivery(.server))
            #expect(bodies.count == 2)
            #expect(bodies[1]["medicationDelivery"] as? String == "server")
            await service.noteMedicationDelivery(.delivery(.server))
            #expect(bodies.count == 2)
        }
    }

    enum SHA256Hex {
        static func of(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
#endif
