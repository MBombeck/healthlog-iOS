import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Drives ``EnvironmentRepository`` over the **real** ``APIClient`` +
/// `MockURLProtocol` (per PROJECT_GUIDE.md — no mock server), covering the Build 7 Item
/// 7.7 read contract: `GET /api/environment` overview read, the tolerant decode
/// through the live envelope, and the `403 module.disabled` gate classification.
///
/// `.serialized` — the suite installs a process-global `MockURLProtocol.handler`.
@Suite("EnvironmentRepository — overview read + module gate", .serialized)
struct EnvironmentRepositoryTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("bearer-abc", forKey: KeychainKey.authToken)
        try? kc.setString("user-123", forKey: KeychainKey.userID)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private nonisolated static func ok(_ dataJSON: String, url: URL) -> (HTTPURLResponse, Data?) {
        let body = #"{"data":\#(dataJSON),"error":null}"#
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    /// A `403 module.disabled` envelope carrying `meta.module: "environment"` —
    /// the exact shape ``APIClient`` types into `HLError.moduleDisabled`.
    private nonisolated static func moduleDisabled(url: URL) -> (HTTPURLResponse, Data?) {
        let body = #"""
        {"data":null,"error":"Module \"environment\" is not enabled",
         "meta":{"errorCode":"module.disabled","module":"environment"}}
        """#
        return (HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    // MARK: - Read

    @Test("overview() GETs /api/environment and decodes the tolerant overview")
    func overviewRead() async throws {
        let api = makeClient()
        let repo = EnvironmentRepository(api: api)
        let recorder = PathRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let home = #"{"lat":51.48,"lon":7.22,"label":"Bochum","timezone":"Europe/Berlin","since":"2026-01-01T00:00:00Z"}"#
            let ctx = #"{"days":12,"latestDate":"2026-07-20","latestFetchedAt":"2026-07-21T03:00:00Z"}"#
            return Self.ok(
                #"{"home":\#(home),"travel":[],"context":\#(ctx),"attribution":"Weather data by Open-Meteo.com"}"#,
                url: req.url!
            )
        }

        let overview = try await repo.overview()

        #expect(recorder.lastPath == "/api/environment")
        #expect(recorder.lastMethod == "GET")
        #expect(overview.home?.label == "Bochum")
        #expect(overview.context.days == 12)
        #expect(overview.attribution == "Weather data by Open-Meteo.com")
    }

    @Test("overview() with an attribution-less body still yields the canonical credit")
    func overviewMissingAttributionFallsBack() async throws {
        let api = makeClient()
        let repo = EnvironmentRepository(api: api)
        MockURLProtocol.handler = { req in
            Self.ok(#"{"home":null,"travel":[],"context":{"days":0}}"#, url: req.url!)
        }

        let overview = try await repo.overview()
        #expect(overview.attribution == EnvironmentOverviewDTO.defaultAttribution)
        #expect(!overview.attribution.isEmpty)
    }

    // MARK: - Module gate

    @Test("A 403 module.disabled surfaces a typed error the gate helper recognises")
    func moduleDisabledIsClassified() async throws {
        let api = makeClient()
        let repo = EnvironmentRepository(api: api)
        MockURLProtocol.handler = { req in Self.moduleDisabled(url: req.url!) }

        var captured: Error?
        do {
            _ = try await repo.overview()
        } catch {
            captured = error
        }
        let error = try #require(captured, "a disabled module must throw")
        #expect(EnvironmentRepository.isEnvironmentDisabled(error))
    }

    @Test("An unrelated module-disabled key is NOT treated as the environment gate")
    func otherModuleDisabledNotEnvironment() {
        #expect(!EnvironmentRepository.isEnvironmentDisabled(HLError.moduleDisabled("nutrients")))
        #expect(EnvironmentRepository.isEnvironmentDisabled(HLError.moduleDisabled("environment")))
    }

    @Test("A plain 403 with no code is treated as the gate (its only documented cause)")
    func bare403IsGate() {
        #expect(EnvironmentRepository.isEnvironmentDisabled(HLError.server(status: 403, code: nil, message: "")))
        #expect(!EnvironmentRepository.isEnvironmentDisabled(HLError.server(status: 500, code: nil, message: "")))
    }
}

/// Records request path/method off the `@Sendable` handler (thread-safe).
private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ req: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(req)
    }

    var lastPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last?.url?.path
    }

    var lastMethod: String? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last?.httpMethod
    }
}
