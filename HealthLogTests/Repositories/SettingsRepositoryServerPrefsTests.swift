import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Build 9 (Server-Prefs) / C1** — repository contract for the `/api/auth/me`
/// server-pref projection + the `/api/auth/me/unit-preference` wire seam.
///
/// Exercises the **real** `APIClient` over a stubbed `URLSession`
/// (`MockURLProtocol`) — never a mock server (PROJECT_GUIDE.md). Pins:
///   - `authMeServerPrefs()` decodes the full `/me` projection (envelope `data`).
///   - Tolerant decode: an old-server `/me` payload without the new fields → all
///     nil, no throw.
///   - `unitPreference()` GET decode + `setUnitPreference(_:)` PATCH path,
///     method, and exact body `{"unitPreference":"imperial"}` (echo-decoded).
@Suite("SettingsRepository server-prefs (Build 9)", .serialized)
struct SettingsRepositoryServerPrefsTests {
    private func makeRepo() -> SettingsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return SettingsRepository(
            api: APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        )
    }

    /// `URLProtocol` swaps `httpBody` for `httpBodyStream` — re-materialize.
    nonisolated static func consumeStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var buf = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&raw, maxLength: 4096)
            guard read > 0 else { break }
            buf.append(raw, count: read)
        }
        return buf.isEmpty ? nil : buf
    }

    // MARK: - authMeServerPrefs

    @Test("authMeServerPrefs decodes the full /me projection from the envelope")
    func decodesFullProjection() async throws {
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            let json = #"""
            {"data":{"id":"u1","username":"anna","avatarUrl":"/api/user/avatar/u1?v=1",
            "unitPreference":"imperial","glucoseUnit":"mmol/L","disableCoach":true,
            "cycleTrackingEnabled":true},"error":null}
            """#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let prefs = try await makeRepo().authMeServerPrefs()
        #expect(capturedPath == "/api/auth/me")
        #expect(prefs.avatarUrl == "/api/user/avatar/u1?v=1")
        #expect(prefs.unitPreference == "imperial")
        #expect(prefs.glucoseUnit == "mmol/L")
        #expect(prefs.disableCoach == true)
        #expect(prefs.cycleTrackingEnabled == true)
    }

    @Test("authMeServerPrefs tolerates an old-server payload without the new fields → all nil")
    func toleratesMissingFields() async throws {
        MockURLProtocol.handler = { req in
            // b239-style `/me` — none of the Build 9 pref fields present.
            let json = #"{"data":{"id":"u1","username":"anna","avatarUrl":null},"error":null}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let prefs = try await makeRepo().authMeServerPrefs()
        #expect(prefs.avatarUrl == nil)
        #expect(prefs.unitPreference == nil)
        #expect(prefs.glucoseUnit == nil)
        #expect(prefs.disableCoach == nil)
        #expect(prefs.cycleTrackingEnabled == nil)
    }

    @Test("authMeAvatarURL still returns just the avatar (delegates onto the projection)")
    func avatarDelegates() async throws {
        MockURLProtocol.handler = { req in
            let json = #"{"data":{"id":"u1","avatarUrl":"/api/user/avatar/u1?v=42","unitPreference":"metric"},"error":null}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let url = try await makeRepo().authMeAvatarURL()
        #expect(url == "/api/user/avatar/u1?v=42")
    }

    // MARK: - unit-preference

    @Test("unitPreference GET decodes the resolved binary")
    func unitPreferenceGet() async throws {
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"unitPreference":"imperial"},"error":null}"#.utf8)
            )
        }
        let value = try await makeRepo().unitPreference()
        #expect(capturedPath == "/api/auth/me/unit-preference")
        #expect(value == "imperial")
    }

    @Test("setUnitPreference PATCHes the exact body and echo-decodes the persisted value")
    func setUnitPreferencePatch() async throws {
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"unitPreference":"imperial"},"error":null}"#.utf8)
            )
        }
        let echoed = try await makeRepo().setUnitPreference("imperial")
        #expect(capturedPath == "/api/auth/me/unit-preference")
        #expect(capturedMethod == "PATCH")
        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["unitPreference"] as? String == "imperial")
        #expect(json.count == 1)
        #expect(echoed == "imperial")
    }
}

// swiftlint:enable force_unwrapping
