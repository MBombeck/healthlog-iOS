import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// #110 — the wait a 429 names reaches the caller, in every form server
/// v1.39.0 (or a proxy in front of it) can send, and a long wait is handed to
/// the caller instead of being cut short by an early in-request retry.
@Suite("429 Retry-After reaches the caller (#110)", .serialized, .mockURLSession)
struct RateLimitRetryAfterTests {
    private static let url = URL(string: "https://test.healthlog.local/api/allergies")!
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func response(_ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    // MARK: - Parsing

    @Test("Retry-After in delta-seconds")
    func secondsForm() {
        #expect(RateLimitDelay.seconds(from: Self.response(["Retry-After": "30"]), body: nil, now: Self.now) == 30)
    }

    @Test("Retry-After as an HTTP date (IMF-fixdate, the RFC 9110 example)")
    func httpDateForm() {
        let example = Date(timeIntervalSince1970: 784_111_777) // Sun, 06 Nov 1994 08:49:37 GMT
        #expect(RateLimitDelay.httpDate("Sun, 06 Nov 1994 08:49:37 GMT") == example)
        let headers = ["Retry-After": "Sun, 06 Nov 1994 08:49:37 GMT"]
        let wait = RateLimitDelay.seconds(from: Self.response(headers), body: nil, now: example.addingTimeInterval(-90))
        #expect(wait == 90)
    }

    @Test("an HTTP date in the past reads as zero, not negative")
    func httpDateInThePast() {
        let headers = ["Retry-After": "Thu, 01 Jan 2026 00:00:00 GMT"]
        #expect(RateLimitDelay.seconds(from: Self.response(headers), body: nil, now: Self.now) == 0)
    }

    @Test("the relative Retry-After wins over the absolute X-RateLimit-Reset (clock skew)")
    func secondsBeatReset() {
        // A device clock 10 minutes behind would read the reset as 10 min away.
        let reset = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(600))
        let headers = ["Retry-After": "12", "X-RateLimit-Reset": reset]
        #expect(RateLimitDelay.seconds(from: Self.response(headers), body: nil, now: Self.now) == 12)
    }

    @Test("X-RateLimit-Reset alone still names the wait")
    func resetAlone() {
        let reset = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(45))
        let wait = RateLimitDelay.seconds(from: Self.response(["X-RateLimit-Reset": reset]), body: nil, now: Self.now)
        #expect(abs((wait ?? -1) - 45) < 0.001)
    }

    @Test("without headers, meta.retryAt (documents / OCR limiter) names the wait")
    func metaRetryAt() {
        let at = ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(42 * 60))
        let body = Data(
            #"{"data":null,"error":"Too many requests","meta":{"errorCode":"documents.inbound.rateLimited","retryAt":"\#(at)"}}"#
                .utf8
        )
        let wait = RateLimitDelay.seconds(from: Self.response([:]), body: body, now: Self.now)
        #expect(abs((wait ?? -1) - 42 * 60) < 0.001) // Date round-trips through the reference date
    }

    @Test("meta.retryAfter in seconds is read as well")
    func metaRetryAfter() {
        let body = Data(#"{"data":null,"error":"x","meta":{"retryAfter":7}}"#.utf8)
        #expect(RateLimitDelay.seconds(from: Self.response([:]), body: body, now: Self.now) == 7)
    }

    @Test("nothing readable is nil — the caller picks its own bounded back-off")
    func nothingReadable() {
        let body = Data(#"{"data":null,"error":"Too many writes, try again later","meta":{"errorCode":"record_write.rate_limited"}}"#.utf8)
        #expect(RateLimitDelay.seconds(from: Self.response(["Retry-After": "soon"]), body: body, now: Self.now) == nil)
        #expect(RateLimitDelay.seconds(from: Self.response([:]), body: nil, now: Self.now) == nil)
    }

    // MARK: - Through APIClient

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "281"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    /// Server v1.39.0 shape for the shared single-record bucket.
    private static let recordWriteBody = Data(#"""
    {"data":null,"error":"Too many writes, try again later","meta":{"errorCode":"record_write.rate_limited"}}
    """#.utf8)

    @Test(
        "a wait beyond the in-request ceiling is thrown at once with the server's value, never retried early",
        .timeLimit(.minutes(1))
    )
    func longWaitIsHandedToTheCaller() async throws {
        let requests = Mutex(0)
        MockURLProtocol.install { req in
            requests.withLock { $0 += 1 }
            let headers = [
                "Content-Type": "application/json",
                "Retry-After": "120",
                "X-RateLimit-Limit": "300",
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": ISO8601DateFormatter().string(from: Date().addingTimeInterval(120))
            ]
            return (
                HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: headers)!,
                Self.recordWriteBody
            )
        }
        let request: APIRequest<EmptyPayload> = APIRequest(method: .post, path: "/api/allergies", body: Data("{}".utf8))
        do {
            _ = try await makeAPI().send(request)
            Issue.record("expected a 429")
        } catch let HLError.rateLimited(retryAfter) {
            #expect(retryAfter == 120)
        }
        #expect(requests.withLock { $0 } == 1, "re-sending before the named instant only spends the bucket")
    }

    @Test("an HTTP-date Retry-After reaches the caller through APIClient", .timeLimit(.minutes(1)))
    func httpDateThroughClient() async throws {
        MockURLProtocol.install { req in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            let headers = ["Retry-After": formatter.string(from: Date().addingTimeInterval(300))]
            return (
                HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: headers)!,
                Self.recordWriteBody
            )
        }
        let request: APIRequest<EmptyPayload> = APIRequest(method: .post, path: "/api/allergies", body: Data("{}".utf8))
        do {
            _ = try await makeAPI().send(request)
            Issue.record("expected a 429")
        } catch let HLError.rateLimited(retryAfter) {
            let wait = try #require(retryAfter)
            #expect(wait > 290 && wait <= 300)
        }
    }
}

/// #110 — Siri / Shortcuts write straight to the per-record routes. A write
/// the repository queued after a 429 is saved; the dialog says so without
/// claiming the phone is offline.
@Suite("Intent dialog for a rate-limited write (#110)")
struct IntentQueuedCopyTests {
    @Test("a 429 gets its own saved-and-waiting dialog")
    func rateLimitedCopy() {
        #expect(IntentCopy.queuedResource(after: .rateLimited(retryAfter: 30)).key == "intents.queued.rateLimited")
        #expect(IntentCopy.queuedResource(after: .rateLimited(retryAfter: nil)).key == "intents.queued.rateLimited")
    }

    @Test("an offline write keeps the offline dialog")
    func offlineCopy() {
        let key = "Saved offline — it will sync the next time you open HealthLog."
        #expect(IntentCopy.queuedResource(after: .offline).key == key)
        #expect(IntentCopy.queuedResource(after: .unauthorized).key == key)
    }
}

// swiftlint:enable force_unwrapping
