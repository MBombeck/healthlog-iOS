import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// **A4 (iOS 1.4) — error codes everywhere (#146 point 3, server v1.43.7).**
///
/// Since v1.43.7 every error envelope carries `meta.errorCode`; a route
/// without its own code gets `http.*` from the status (`http.not_found`,
/// `http.forbidden`, …). New: `503 auth.session.unavailable` when the session
/// store cannot be reached ("Keep the credential and retry"). Body shape
/// `{ data: null, error, meta: { errorCode, requestId } }` (`ErrorEnvelope`
/// in `docs/api/openapi.yaml` at `v1.43.10`).
///
/// These pin that the codes reach the error id and the support info, that the
/// 503 leaves the sign-in alone, and that no "403 without a code means module
/// off" branch reads `http.forbidden` as a switched-off module.
@Suite("A4: meta.errorCode, http.* and auth.session.unavailable", .serialized, .mockURLSession)
struct A4ErrorCodeContractTests {
    static let requestID = "a4e0c0de-1111-4222-8333-944455556666"

    final class Calls: Sendable {
        let count = Mutex(0)
        let unauthorized = Mutex(0)
    }

    private func makeAPI(log: RecentFailureLog, keychain: InMemoryKeychain, calls: Calls) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.4.0",
            buildNumber: "1"
        )
        try? keychain.setString("bearer-a4", forKey: KeychainKey.authToken)
        try? keychain.setString("refresh-a4", forKey: KeychainKey.refreshToken)
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock(),
            onUnauthorized: { calls.unauthorized.withLock { $0 += 1 } },
            failureLog: log
        )
    }

    static func errorBody(_ code: String, _ message: String) -> Data {
        Data(#"{"data":null,"error":"\#(message)","meta":{"errorCode":"\#(code)","requestId":"\#(requestID)"}}"#.utf8)
    }

    static func reply(_ req: URLRequest, _ status: Int, _ body: Data) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, body)
    }

    @Test("an http.* code reaches the typed error, the failure log and the support info line")
    func httpCodeReachesTheLog() async throws {
        let log = RecentFailureLog()
        let api = makeAPI(log: log, keychain: InMemoryKeychain(), calls: Calls())
        MockURLProtocol.install { req in Self.reply(req, 404, Self.errorBody("http.not_found", "Not found")) }
        let request = APIRequest<EmptyPayload>(method: .get, path: "/api/medications/med_az09kqmzp1", maxRetries: 0)
        await #expect(throws: HLError.server(status: 404, code: "http.not_found", message: "Not found")) {
            try await api.send(request)
        }
        let failure = try #require(log.snapshot().first)
        #expect(failure.errorCode == "http.not_found")
        #expect(failure.requestId == Self.requestID)
        #expect(RecentFailureLines.line(failure).hasSuffix("GET /api/medications/:id 404 http.not_found id \(Self.requestID)"))
    }

    @Test("503 auth.session.unavailable: the request is retried and the sign-in stays")
    func sessionUnavailableIsRetried() async throws {
        let log = RecentFailureLog()
        let keychain = InMemoryKeychain()
        let calls = Calls()
        let api = makeAPI(log: log, keychain: keychain, calls: calls)
        MockURLProtocol.install { req in
            let attempt = calls.count.withLock { count in
                count += 1
                return count
            }
            if attempt == 1 { return Self.reply(req, 503, Self.errorBody("auth.session.unavailable", "Session store unavailable")) }
            return Self.reply(req, 200, Data(#"{"data":{},"error":null}"#.utf8))
        }
        let request = APIRequest<EmptyPayload>(method: .get, path: "/api/auth/me", maxRetries: 1)
        _ = try await api.send(request)
        #expect(calls.count.withLock { $0 } == 2)
        #expect(calls.unauthorized.withLock { $0 } == 0)
        #expect(keychain.getString(forKey: KeychainKey.authToken) == "bearer-a4")
        #expect(keychain.getString(forKey: KeychainKey.refreshToken) == "refresh-a4")
    }

    @Test("503 auth.session.unavailable that persists: a server error with an id, never a sign-out")
    func sessionUnavailablePersists() async throws {
        let log = RecentFailureLog()
        let keychain = InMemoryKeychain()
        let calls = Calls()
        let api = makeAPI(log: log, keychain: keychain, calls: calls)
        MockURLProtocol.install { req in Self.reply(req, 503, Self.errorBody("auth.session.unavailable", "Session store unavailable")) }
        let request = APIRequest<EmptyPayload>(method: .get, path: "/api/auth/me", maxRetries: 0)
        let expected = HLError.server(status: 503, code: "auth.session.unavailable", message: "Session store unavailable")
        await #expect(throws: expected) { try await api.send(request) }
        #expect(calls.unauthorized.withLock { $0 } == 0)
        #expect(keychain.getString(forKey: KeychainKey.authToken) == "bearer-a4")
        #expect(log.displayID(for: expected) == Self.requestID)
        #expect(log.snapshot().first?.errorCode == "auth.session.unavailable")
        // The same answer on the refresh leg is transient: the session survives.
        #expect(RefreshOutcome.classify(expected) == .transient)
        #expect(expected.isRetriable)
    }

    @Test("http.forbidden is not read as a switched-off module")
    func httpForbiddenIsNotModuleOff() {
        let forbidden = HLError.server(status: 403, code: "http.forbidden", message: "Forbidden")
        #expect(!IllnessRepository.isIllnessDisabled(forbidden))
        #expect(!NutrientReadRepository.isNutrientsDisabled(forbidden))
        #expect(!DocumentsRepository.isModuleDisabled(forbidden))
        #expect(!EnvironmentRepository.isEnvironmentDisabled(forbidden))
        // The gate's own codes still are.
        #expect(IllnessRepository.isIllnessDisabled(HLError.server(status: 403, code: "illness.disabled", message: "")))
        #expect(NutrientReadRepository.isNutrientsDisabled(HLError.server(status: 403, code: "module.disabled", message: "")))
    }
}
