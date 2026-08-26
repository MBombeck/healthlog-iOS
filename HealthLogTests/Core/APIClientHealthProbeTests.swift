import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.7.1 QoL-3-H-3 — `APIClient.probeReachable()` + the
/// `isHealthEnvelope` discriminator that tells our `/api/health` JSON
/// apart from a captive-portal HTML login page.
///
/// Uses a real `APIClient` over a stubbed `URLProtocol` (per PROJECT_GUIDE.md —
/// no mock-server for network paths, so schema drift surfaces).
@Suite("APIClient — captive-portal health probe", .serialized)
struct APIClientHealthProbeTests {
    // swiftlint:disable force_unwrapping

    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.7.1",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
    }

    // MARK: - isHealthEnvelope discriminator (pure)

    @Test("Healthy `{status:ok}` body is recognised as our server")
    func okEnvelopeRecognised() {
        let data = Data(#"{"status":"ok"}"#.utf8)
        #expect(APIClient.isHealthEnvelope(data))
    }

    @Test("Degraded `{status:degraded}` body still proves API reachability")
    func degradedEnvelopeStillReachable() {
        let data = Data(#"{"status":"degraded"}"#.utf8)
        #expect(APIClient.isHealthEnvelope(data))
    }

    @Test("Captive-portal HTML body is rejected")
    func captivePortalHTMLRejected() {
        let html = Data("<html><body>Sign in to WiFi</body></html>".utf8)
        #expect(APIClient.isHealthEnvelope(html) == false)
    }

    @Test("Empty body is rejected")
    func emptyBodyRejected() {
        #expect(APIClient.isHealthEnvelope(Data()) == false)
    }

    @Test("Foreign JSON without `status` is rejected")
    func foreignJSONRejected() {
        let data = Data(#"{"login":"required"}"#.utf8)
        #expect(APIClient.isHealthEnvelope(data) == false)
    }

    // MARK: - probeReachable over a stubbed session

    @Test("Probe hits /api/health and returns true on a healthy response")
    func probeReturnsTrueOnHealthyResponse() async {
        let api = makeClient()
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            let body = Data(#"{"status":"ok"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        #expect(await api.probeReachable())
        #expect(capturedPath == "/api/health")
    }

    @Test("Probe returns true on a 503 health envelope (server up, deps degraded)")
    func probeReturnsTrueOn503HealthEnvelope() async {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"{"status":"degraded"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, body)
        }
        #expect(await api.probeReachable())
    }

    @Test("Probe returns false on a captive-portal HTML 200")
    func probeReturnsFalseOnCaptivePortalHTML() async {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data("<html>Login</html>".utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        #expect(await api.probeReachable() == false)
    }

    @Test("Probe returns false when the request errors (timeout / portal hang)")
    func probeReturnsFalseOnTransportError() async {
        let api = makeClient()
        MockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        #expect(await api.probeReachable() == false)
    }

    // swiftlint:enable force_unwrapping
}
