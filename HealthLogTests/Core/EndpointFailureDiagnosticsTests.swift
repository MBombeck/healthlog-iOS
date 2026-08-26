import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// MARK: - Route templating (pure — no network, no APIClient)

@Suite("EndpointRouteTemplate")
struct EndpointRouteTemplateTests {
    @Test("Canonical UUID segments collapse to :id")
    func uuidSegment() {
        #expect(
            EndpointRouteTemplate.template("/api/medications/018f3c2a-9b4d-7c11-8a2e-1f5b6c7d8e90/dose-history")
                == "/api/medications/:id/dose-history"
        )
        #expect(EndpointRouteTemplate.template("/api/measurements/6BA7B810-9DAD-11D1-80B4-00C04FD430C8") == "/api/measurements/:id")
    }

    @Test("Numeric ids collapse to :id")
    func numericSegment() {
        #expect(EndpointRouteTemplate.template("/api/labs/42") == "/api/labs/:id")
        #expect(EndpointRouteTemplate.template("/api/import/1717171717171/status") == "/api/import/:id/status")
    }

    @Test(
        "Opaque server token shapes collapse to :id",
        arguments: [
            "hls_9x2mkq7ptv4wz",
            "hlh_8f2b1c9d0a7e6f5b",
            "hle_4b7c1d9e0a2f3b6c8d5e7a1f",
            "med_clre8m2x0000qwerty12345",
            "meas_az09kqmzp1x7",
            "pr_clx9abcdef01"
        ]
    )
    func prefixedTokenSegment(token: String) {
        #expect(EndpointRouteTemplate.template("/api/share-links/\(token)") == "/api/share-links/:id")
    }

    @Test("Bare cuid2 / long opaque bodies collapse to :id")
    func bareOpaqueSegment() {
        #expect(EndpointRouteTemplate.template("/api/tokens/clre8m2x0000qwertyuiop12") == "/api/tokens/:id")
        // 32-hex, no dashes — below no rule but the digit-count / length floors.
        #expect(EndpointRouteTemplate.template("/api/tokens/9f86d081884c7d659a2feaa0c55ad015") == "/api/tokens/:id")
    }

    @Test("Percent-encoded opaque keys collapse to :id")
    func percentEncodedSegment() {
        #expect(EndpointRouteTemplate.template("/api/mood/tags/custom/tag%3Amine") == "/api/mood/tags/custom/:id")
    }

    @Test("Day keys and timestamps collapse to :id")
    func dateSegment() {
        #expect(EndpointRouteTemplate.template("/api/cycle/day-logs/2026-07-30") == "/api/cycle/day-logs/:id")
    }

    @Test("Route literals survive verbatim")
    func literalsPreserved() {
        #expect(EndpointRouteTemplate.template("/api/medications") == "/api/medications")
        #expect(EndpointRouteTemplate.template("/api/measurement-categories") == "/api/measurement-categories")
        #expect(EndpointRouteTemplate.template("/api/documents/inbound") == "/api/documents/inbound")
        #expect(EndpointRouteTemplate.template("/api/import/apple-health-export") == "/api/import/apple-health-export")
        // A one-digit literal must NOT be mistaken for an id.
        #expect(EndpointRouteTemplate.template("/api/medications/glp1") == "/api/medications/glp1")
        #expect(EndpointRouteTemplate.template("/api/mood/tags/groups/feelings") == "/api/mood/tags/groups/feelings")
    }

    @Test("Query and fragment are dropped entirely")
    func queryDropped() {
        #expect(EndpointRouteTemplate.template("/api/measurements?type=weight&from=2026-07-01") == "/api/measurements")
        #expect(EndpointRouteTemplate.template("/api/measurements#anchor") == "/api/measurements")
    }

    @Test("Degenerate paths do not crash")
    func degeneratePaths() {
        #expect(EndpointRouteTemplate.template("") == "/")
        #expect(EndpointRouteTemplate.template("/") == "/")
        #expect(EndpointRouteTemplate.template("?q=1") == "/")
    }
}

// MARK: - Classification + line format (pure)

@Suite("EndpointFailureDiagnostics — classification")
struct EndpointFailureDiagnosticsClassificationTests {
    @Test("Every HLError maps onto its documented failure class")
    func classes() {
        #expect(EndpointFailureDiagnostics.classify(HLError.network(.timeout)) == .timeout)
        #expect(EndpointFailureDiagnostics.classify(HLError.network(.dnsFailure)) == .transport)
        #expect(EndpointFailureDiagnostics.classify(HLError.network(.sslPinning)) == .transport)
        #expect(EndpointFailureDiagnostics.classify(HLError.offline) == .offline)
        #expect(EndpointFailureDiagnostics.classify(HLError.decoding("keyNotFound")) == .decoding)
        #expect(EndpointFailureDiagnostics.classify(HLError.server(status: 503, code: nil, message: "x")) == .status)
        #expect(EndpointFailureDiagnostics.classify(HLError.unauthorized) == .status)
        #expect(EndpointFailureDiagnostics.classify(HLError.rateLimited(retryAfter: 3)) == .status)
        #expect(EndpointFailureDiagnostics.classify(HLError.moduleDisabled("illness")) == .status)
        #expect(EndpointFailureDiagnostics.classify(HLError.unknown("no url")) == .transport)
    }

    @Test("Cancellation never produces a line")
    func cancellationIsSilent() {
        #expect(EndpointFailureDiagnostics.classify(HLError.canceled) == nil)
        #expect(EndpointFailureDiagnostics.classify(CancellationError()) == nil)
        #expect(EndpointFailureDiagnostics.classify(URLError(.cancelled)) == nil)
    }

    @Test("Status is taken from the error, 0 when there was no response")
    func statuses() {
        #expect(EndpointFailureDiagnostics.status(for: HLError.server(status: 422, code: "x", message: "y")) == 422)
        #expect(EndpointFailureDiagnostics.status(for: HLError.unauthorized) == 401)
        #expect(EndpointFailureDiagnostics.status(for: HLError.rateLimited(retryAfter: nil)) == 429)
        #expect(EndpointFailureDiagnostics.status(for: HLError.moduleDisabled("illness")) == 403)
        #expect(EndpointFailureDiagnostics.status(for: HLError.network(.timeout)) == 0)
        #expect(EndpointFailureDiagnostics.status(for: HLError.decoding("x")) == 0)
    }

    @Test("The line has exactly the agreed shape")
    func lineShape() {
        let line = EndpointFailureDiagnostics.formatLine(
            method: .get,
            path: "/api/medications/018f3c2a-9b4d-7c11-8a2e-1f5b6c7d8e90/dose-history?window=90",
            status: 503,
            failureClass: .status,
            elapsedMs: 812
        )
        #expect(
            line == "endpoint-failure method=GET route=/api/medications/:id/dose-history status=503 class=status elapsedMs=812"
        )
    }

    @Test("The line survives LogSanitizer untouched — nothing in it is redactable")
    func lineIsSanitizerStable() {
        let line = EndpointFailureDiagnostics.formatLine(
            method: .post,
            path: "/api/medications/018f3c2a-9b4d-7c11-8a2e-1f5b6c7d8e90/intake",
            status: 0,
            failureClass: .offline,
            elapsedMs: 17
        )
        #expect(LogSanitizer.redact(line) == line)
    }
}

// MARK: - Integration: real APIClient over MockURLProtocol

/// `.serialized` because the diagnostics sink is a process-global observer, the
/// same reason `MockURLProtocol.handler` needs it. The probe route
/// (`/api/diagnostics-probe/...`) exists nowhere else in the app or the suite, so
/// a line emitted by a concurrently running suite can never be mistaken for ours.
@Suite("EndpointFailureDiagnostics — APIClient integration", .serialized)
struct EndpointFailureDiagnosticsIntegrationTests {
    private struct Probe: Decodable {
        let value: Int
    }

    /// A real medication-shaped id, so the templating is exercised end to end.
    private static let opaqueID = "018f3c2a-9b4d-7c11-8a2e-1f5b6c7d8e90"
    private static let probePath = "/api/diagnostics-probe/\(opaqueID)/dose-history"
    private static let templatedRoute = "/api/diagnostics-probe/:id/dose-history"

    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        // A bearer in the keychain means the failing request really does carry an
        // `Authorization` header — so "no token in the line" is a live assertion,
        // not a vacuous one.
        try? keychain.setString("hlk_secret_bearer_value_for_the_probe", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    /// Lock-guarded line collector. `@unchecked Sendable` is the established
    /// test-support pattern here (same contract as `MockURLProtocol` /
    /// `InMemoryKeychain`): the lock, not the compiler, enforces exclusive
    /// access. Both members are *synchronous* on purpose — `NSLock.lock()` is
    /// `noasync`, so the locking has to stay behind a sync boundary.
    private final class LineRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    /// Provokes exactly one failure through the real `APIClient` and returns the
    /// diagnostics lines the sink observed for the probe route.
    private func provoke(_ handler: @escaping MockURLProtocol.Handler) async -> [String] {
        let recorder = LineRecorder()
        EndpointFailureDiagnostics.sink = { recorder.append($0) }
        defer { EndpointFailureDiagnostics.sink = nil }

        MockURLProtocol.handler = handler
        let api = makeClient()
        // `maxRetries: 0` — the retry loop is not under test here, and it keeps
        // the "exactly one line" assertion honest without sleeping through backoff.
        let request = APIRequest<Probe>(method: .get, path: Self.probePath, maxRetries: 0)
        _ = try? await api.send(request)

        return recorder.snapshot().filter { $0.contains("route=\(Self.templatedRoute) ") }
    }

    @Test("transport — one line, templated route, status 0")
    func transportFailure() async {
        let lines = await provoke { _ -> (HTTPURLResponse, Data?) in throw URLError(.cannotFindHost) }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("class=transport") == true)
        #expect(lines.first?.contains("status=0") == true)
        #expect(lines.first?.hasPrefix("endpoint-failure method=GET route=\(Self.templatedRoute) ") == true)
    }

    @Test("timeout — one line")
    func timeoutFailure() async {
        let lines = await provoke { _ -> (HTTPURLResponse, Data?) in throw URLError(.timedOut) }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("class=timeout") == true)
    }

    @Test("offline — one line")
    func offlineFailure() async {
        let lines = await provoke { _ -> (HTTPURLResponse, Data?) in throw URLError(.notConnectedToInternet) }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("class=offline") == true)
    }

    @Test("status — one line carrying the server status")
    func statusFailure() async {
        let lines = await provoke { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"Service Unavailable"}"#.utf8))
        }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("class=status") == true)
        #expect(lines.first?.contains("status=503") == true)
    }

    @Test("decoding — one line, 200 but unreadable body")
    func decodingFailure() async {
        let lines = await provoke { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"totally":"unexpected"}"#.utf8))
        }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("class=decoding") == true)
        #expect(lines.first?.contains("status=0") == true)
    }

    @Test("no PII in the emitted line")
    func noPIIInLine() async {
        let lines = await provoke { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"error":"boom"}"#.utf8))
        }
        #expect(lines.count == 1)
        let emitted = lines.first ?? ""
        #expect(!emitted.contains(Self.opaqueID))
        #expect(!emitted.lowercased().contains("bearer"))
        #expect(!emitted.contains("hlk_"))
        #expect(!emitted.contains("test.healthlog.local"))
        #expect(!emitted.contains("https"))
        #expect(!emitted.contains("Idempotency"))
        #expect(!emitted.contains("@"))
        // Defence in depth: the sanitizer finds nothing left to redact.
        #expect(LogSanitizer.redact(emitted) == emitted)
    }

    @Test("elapsedMs is a plausible non-negative number")
    func elapsedIsReported() async {
        let lines = await provoke { _ -> (HTTPURLResponse, Data?) in throw URLError(.cannotFindHost) }
        let suffix = lines.first?.components(separatedBy: "elapsedMs=").last ?? ""
        let elapsed = Int(suffix)
        #expect(elapsed != nil)
        #expect((elapsed ?? -1) >= 0)
    }

    @Test("a successful request emits nothing")
    func successIsSilent() async {
        let lines = await provoke { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":{"value":1}}"#.utf8))
        }
        #expect(lines.isEmpty)
    }
}

// swiftlint:enable force_unwrapping
