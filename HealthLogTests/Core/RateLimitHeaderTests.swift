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
@Suite("Rate-limit header handling", .serialized, .mockURLSession)
struct RateLimitHeaderTests {
    /// T1 (1.4) — a whole second, so the ISO header carries it exactly.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeAPI(clock: RecordingRetryClock) -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock(),
            retryClock: clock.retryClock
        )
    }

    @Test("429 with X-RateLimit-Reset surfaces a non-nil retryAfter")
    func parsesRateLimitReset() async {
        // T1 (1.4) — the client reads the reset against the injected clock, so
        // the delay is exact. FLAKES (1.3.0) had to widen a wall-clock reset
        // to 20 s and accept anything in (0, 21].
        let clock = RecordingRetryClock(now: Self.now)
        let api = makeAPI(clock: clock)
        let resetIso = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(20))
        MockURLProtocol.install { req in
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
            #expect(retryAfter == 20)
            #expect(clock.sleeps.isEmpty, "maxRetries 0 must not wait at all")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Retry honours the X-RateLimit-Reset value within the maxRetries budget")
    func retryHonoursReset() async throws {
        // T1 (1.4) — the clock is injected: the reset is read against a fixed
        // instant and the retry delay is recorded instead of slept. The old
        // form measured "second attempt < 1.5 s after the first" on the wall
        // clock, which a loaded runner can break, and its 50 ms reset was
        // truncated by the whole-second header into the past most of the time,
        // so it mostly exercised the plain backoff instead of the reset.
        let clock = RecordingRetryClock(now: Self.now)
        let api = makeAPI(clock: clock)
        let resetIso = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(2))
        nonisolated(unsafe) var attempts = 0
        MockURLProtocol.install { req in
            attempts += 1
            switch attempts {
            case 1:
                let headers = ["X-RateLimit-Reset": resetIso]
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: headers)!,
                    Data(#"{"data":null,"error":"Too many requests"}"#.utf8)
                )
            default:
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null}"#.utf8)
                )
            }
        }
        let req = APIRequest<EmptyPayload>(method: .get, path: "/api/x", maxRetries: 1)
        _ = try await api.send(req)
        #expect(attempts == 2)
        // Exactly one wait, and it is the reset (2 s) plus jitter of at most
        // 0.5 s: no exponential backoff on top, and not the bare backoff.
        let sleeps = clock.sleeps
        #expect(sleeps.count == 1)
        let waited = Double(sleeps.first ?? 0) / 1_000_000_000
        #expect(waited >= 2)
        #expect(waited <= 2.5)
    }
}

/// T1 (1.4) — an ``APIRetryClock`` that stands still at `now` and records
/// every requested wait instead of spending it.
private final class RecordingRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UInt64] = []
    private let fixedNow: Date

    init(now: Date) {
        fixedNow = now
    }

    var sleeps: [UInt64] {
        lock.withLock { recorded }
    }

    var retryClock: APIRetryClock {
        APIRetryClock(
            now: { [fixedNow] in fixedNow },
            sleep: { [self] nanoseconds in lock.withLock { recorded.append(nanoseconds) } }
        )
    }
}
