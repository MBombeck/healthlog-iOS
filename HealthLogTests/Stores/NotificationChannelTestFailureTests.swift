import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **#112 — webhook `format` and the cause of a failed channel test.**
///
/// Real `APIClient` over `MockURLProtocol`, so the transport's opt-in
/// (`APIRefusalDetail`) and its retry policy are what is under test, not a
/// stub. Fixtures follow server v1.39.0:
/// - `GET /api/settings/webhook` (`src/app/api/settings/webhook/route.ts`)
///   answers `format: "generic" | "gotify"`;
/// - a refused test answers `apiError(sentence, 502, { errorCode,
///   upstreamStatus?, upstreamBody?, smtpCode? })`
///   (`src/lib/notifications/test-delivery-failure.ts`), a private-origin
///   refusal `apiError(sentence, 422, { errorCode })`.
@MainActor
@Suite("#112 — webhook format + channel test failure cause", .serialized, .mockURLSession)
struct NotificationChannelTestFailureTests {
    private static func makeAPI() -> APIClient {
        APIClient(
            environment: AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.5.0",
                buildNumber: "1"
            ),
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
    }

    private nonisolated static func respond(_ req: URLRequest, _ status: Int, _ json: String) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private nonisolated static func body(of req: URLRequest) -> [String: Any] {
        var data = req.httpBody ?? Data()
        if data.isEmpty, let stream = req.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - format on the GET

    @Test("GET format decodes gotify, absent reads generic, a new value reads unknown", arguments: [
        (#","format":"gotify""#, WebhookFormat.gotify),
        ("", WebhookFormat.generic),
        (#","format":"matrix""#, WebhookFormat.unknown)
    ])
    func formatDecodes(fragment: String, expected: WebhookFormat) async throws {
        let config = #"{"enabled":true,"url":"https://push.example.org/message","#
            + #""headerName":"X-Gotify-Key","hasHeaderValue":true"# + fragment + "}"
        MockURLProtocol.install { req in
            Self.respond(req, 200, #"{"data":"# + config + #","error":null}"#)
        }
        let decoded = try await NotificationServicesRepository(api: Self.makeAPI()).webhookConfig()
        #expect(decoded.format == expected)
        #expect(decoded.url == "https://push.example.org/message")
        #expect(decoded.hasHeaderValue)
    }

    // MARK: - format on the PUT

    @Test("PUT sends a chosen format; nil and unknown stay off the wire", arguments: [
        (WebhookFormat?.some(.gotify), String?.some("gotify")),
        (WebhookFormat?.some(.generic), String?.some("generic")),
        (WebhookFormat?.none, String?.none),
        (WebhookFormat?.some(.unknown), String?.none)
    ])
    func formatOnPut(format: WebhookFormat?, wire: String?) async throws {
        nonisolated(unsafe) var sent: [String: Any] = [:]
        MockURLProtocol.install { req in
            sent = Self.body(of: req)
            return Self.respond(req, 200, #"{"data":{"saved":true},"error":null}"#)
        }
        try await NotificationServicesRepository(api: Self.makeAPI()).saveWebhook(
            enabled: true,
            url: "https://push.example.org/message",
            headerName: "X-Gotify-Key",
            headerValue: nil,
            format: format
        )
        #expect(sent["format"] as? String == wire)
        #expect(sent.keys.contains("format") == (wire != nil))
        #expect(sent["headerValue"] == nil, "an unchanged secret is never sent")
    }

    // MARK: - failed test: cause, not "server error"

    @Test("a 502 webhook test names the cause, the relay status and its words — and runs once")
    func webhook502() async {
        nonisolated(unsafe) var posts = 0
        MockURLProtocol.install { req in
            posts += 1
            return Self.respond(req, 502, #"""
            {"data":null,"error":"The webhook answered HTTP 401.",
            "meta":{"errorCode":"credentials_rejected","upstreamStatus":401,"upstreamBody":"{\"error\":\"invalid token\"}"}}
            """#)
        }
        let store = NotificationServicesStore(repo: NotificationServicesRepository(api: Self.makeAPI()))
        await store.testWebhook()

        #expect(posts == 1, "a refused test is not retried: each retry is another message and another rate-limit slot")
        #expect(store.webhookError == nil, "not the generic 'Server error' banner")
        #expect(store.webhookTestSucceeded == false)
        #expect(store.webhookTestFailure == NotificationChannelTestFailure(
            reason: .credentialsRejected,
            upstreamStatus: 401,
            upstreamBody: #"{"error":"invalid token"}"#
        ))
    }

    @Test("an ntfy timeout carries no status and still names the cause")
    func ntfyTimeout() async {
        MockURLProtocol.install { req in
            Self.respond(req, 502, #"""
            {"data":null,"error":"ntfy did not answer in time.","meta":{"errorCode":"timeout"}}
            """#)
        }
        let store = NotificationServicesStore(repo: NotificationServicesRepository(api: Self.makeAPI()))
        await store.testNtfy()
        #expect(store.ntfyError == nil)
        #expect(store.ntfyTestFailure == NotificationChannelTestFailure(reason: .timeout))
    }

    @Test("the 422 private-origin refusal is a named cause too")
    func privateOrigin() async {
        MockURLProtocol.install { req in
            Self.respond(req, 422, #"""
            {"data":null,"error":"The target is on a private network the operator has not approved.",
            "meta":{"errorCode":"private_origin_not_approved"}}
            """#)
        }
        let store = NotificationServicesStore(repo: NotificationServicesRepository(api: Self.makeAPI()))
        await store.testWebhook()
        #expect(store.webhookTestFailure?.reason == .privateOriginNotApproved)
        #expect(store.webhookError == nil)
    }

    @Test("a cause this build does not know reads as unknown, not as an error")
    func unknownCause() async {
        MockURLProtocol.install { req in
            Self.respond(req, 502, #"{"data":null,"error":"x","meta":{"errorCode":"relay_on_fire"}}"#)
        }
        let store = NotificationServicesStore(repo: NotificationServicesRepository(api: Self.makeAPI()))
        await store.testWebhook()
        #expect(store.webhookTestFailure?.reason == .unknown)
    }

    @Test("a 500 without a code keeps the generic path (the server could not name it)")
    func unnamed500() async {
        MockURLProtocol.install { req in
            Self.respond(req, 500, #"{"data":null,"error":"Failed to send test message"}"#)
        }
        let store = NotificationServicesStore(repo: NotificationServicesRepository(api: Self.makeAPI()))
        await store.testWebhook()
        #expect(store.webhookTestFailure == nil)
        #expect(store.webhookError == .server(status: 500, code: nil, message: "Failed to send test message"))
    }

    @Test("the opt-in is per route: an integration test's 502 keeps its HLError.server shape")
    func integrationRouteUnchanged() async {
        MockURLProtocol.install { req in
            Self.respond(req, 502, #"{"data":null,"error":"Token rejected","meta":{"errorCode":"credentials_rejected"}}"#)
        }
        let request: APIRequest<NotificationChannelTestResult> = APIRequest(
            method: .post, path: "/api/integrations/whoop/test", maxRetries: 0
        )
        await #expect(throws: HLError.server(status: 502, code: "credentials_rejected", message: "Token rejected")) {
            _ = try await Self.makeAPI().send(request)
        }
    }

    // MARK: - copy

    @Test("the sentence adds the relay's HTTP status, or the SMTP code")
    func sentence() {
        let http = ChannelTestFailureRow.sentence(for: .init(reason: .upstreamRejected, upstreamStatus: 400))
        #expect(http.hasPrefix(ChannelTestFailureRow.reasonText(.upstreamRejected)))
        #expect(http.contains("400"))
        let smtp = ChannelTestFailureRow.sentence(for: .init(reason: .credentialsRejected, smtpCode: 535))
        #expect(smtp.contains("535"))
        #expect(ChannelTestFailureRow.sentence(for: .init(reason: .timeout)) == ChannelTestFailureRow.reasonText(.timeout))
        // Every reason has its own sentence.
        let all = NotificationChannelTestFailure.Reason.allCases.map(ChannelTestFailureRow.reasonText)
        #expect(Set(all).count == all.count)
    }
}

// swiftlint:enable force_unwrapping
