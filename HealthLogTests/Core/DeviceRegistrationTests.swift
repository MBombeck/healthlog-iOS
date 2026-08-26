import Foundation
@testable import HealthLog
import Testing

/// \`DeviceRegistration\` muss roundtrip-safe encoded werden + die
/// \`apnsToken\`/\`apnsEnvironment\`-Symmetrie respektieren (entweder beide
/// oder keiner — spiegelt Server-Zod \`.refine()\`).
@Suite("DeviceRegistration encoding")
struct DeviceRegistrationTests {
    @Test("Mit APNs-Token roundtrips JSON-stable")
    func roundtripWithAPNs() throws {
        let model = DeviceRegistration(
            token: "device-uuid-123",
            bundleId: "dev.healthlog.app",
            locale: "de_DE",
            appVersion: "0.3.0",
            model: "iPhone15,3",
            apnsToken: "deadbeefcafe",
            apnsEnvironment: .sandbox
        )
        let data = try JSONEncoder.hlDefault.encode(model)
        let decoded = try JSONDecoder().decode(DeviceRegistration.self, from: data)
        #expect(decoded == model)
        #expect(decoded.apnsToken == "deadbeefcafe")
        #expect(decoded.apnsEnvironment == .sandbox)
    }

    @Test("Ohne APNs-Token (beides nil) roundtrips JSON-stable")
    func roundtripWithoutAPNs() throws {
        let model = DeviceRegistration(
            token: "device-uuid-123",
            bundleId: "dev.healthlog.app",
            locale: "de_DE",
            appVersion: "0.3.0",
            model: "iPhone15,3",
            apnsToken: nil,
            apnsEnvironment: nil
        )
        let data = try JSONEncoder.hlDefault.encode(model)
        let decoded = try JSONDecoder().decode(DeviceRegistration.self, from: data)
        #expect(decoded == model)
        #expect(decoded.apnsToken == nil)
        #expect(decoded.apnsEnvironment == nil)
    }

    @Test("JSON-Keys matchen Server-Schema (camelCase, kein snake)")
    func jsonKeyShape() throws {
        let model = DeviceRegistration(
            token: "u",
            bundleId: "dev.healthlog.app",
            locale: "de",
            appVersion: "0.3.0",
            model: "x",
            apnsToken: "abc123",
            apnsEnvironment: .production
        )
        let data = try JSONEncoder.hlDefault.encode(model)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["token"] as? String == "u")
        #expect(json["bundleId"] as? String == "dev.healthlog.app")
        #expect(json["apnsToken"] as? String == "abc123")
        #expect(json["apnsEnvironment"] as? String == "production")
    }

    @Test("APNsEnvironment kodiert als plain lowercase rawValue")
    func envEncoding() throws {
        let sandbox = try JSONEncoder().encode(APNsEnvironment.sandbox)
        let prod = try JSONEncoder().encode(APNsEnvironment.production)
        #expect(String(data: sandbox, encoding: .utf8) == "\"sandbox\"")
        #expect(String(data: prod, encoding: .utf8) == "\"production\"")
    }
}
