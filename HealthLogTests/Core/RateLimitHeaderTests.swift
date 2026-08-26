import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks: APIClient liest `X-RateLimit-Reset` (ISO-8601), schickt den Wert
/// als `HLError.rateLimited(retryAfter:)` weiter und nutzt ihn als Sleep-
/// Delay im retry-Loop — KEIN extra Exponential-Backoff (W2a-A2 Audit §6).
@Suite("Rate-limit header handling", .serialized)
struct RateLimitHeaderTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @Test("429 with X-RateLimit-Reset surfaces a non-nil retryAfter")
    func parsesRateLimitReset() async {
        let api = makeAPI()
        let resetIso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2))
        MockURLProtocol.handler = { req in
            let headers: [String: String] = [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": resetIso
            ]
            return (
                HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: headers)!,
                Data(#"{"data":null,"error":"Too many requests"}"#.utf8)
            )
        }
        do {
            let req = APIRequest<EmptyPayload>(method: .get, path: "/api/x", maxRetries: 0)
            _ = try await api.send(req)
            Issue.record("expected throw")
        } catch let err as HLError {
            guard case let .rateLimited(retryAfter) = err else {
                Issue.record("expected rateLimited, got \(err)")
                return
            }
            #expect(retryAfter != nil)
            #expect((retryAfter ?? 0) > 0)
            #expect((retryAfter ?? 0) <= 3)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Retry honours the X-RateLimit-Reset value within the maxRetries budget")
    func retryHonoursReset() async throws {
        let api = makeAPI()
        // Use a tiny reset window so the test stays fast (50 ms).
        let resetIso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(0.05))
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var firstAttemptAt: Date?
        nonisolated(unsafe) var secondAttemptAt: Date?
        MockURLProtocol.handler = { req in
            attempts += 1
            switch attempts {
            case 1:
                firstAttemptAt = Date()
                let headers = ["X-RateLimit-Reset": resetIso]
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: headers)!,
                    Data(#"{"data":null,"error":"Too many requests"}"#.utf8)
                )
            default:
                secondAttemptAt = Date()
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null}"#.utf8)
                )
            }
        }
        let req = APIRequest<EmptyPayload>(method: .get, path: "/api/x", maxRetries: 1)
        _ = try await api.send(req)
        #expect(attempts == 2)
        // Sanity: retry delay is at most ~600 ms (reset 50 ms + jitter ≤ 0.5 s).
        if let first = firstAttemptAt, let second = secondAttemptAt {
            #expect(second.timeIntervalSince(first) < 1.5)
        }
    }
}
