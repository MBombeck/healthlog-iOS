import Foundation

// swiftlint:disable force_unwrapping force_try
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

@Suite("APIClient", .serialized)
struct APIClientTests {
    private func makeClient(
        keychain: InMemoryKeychain = InMemoryKeychain(),
        cf: (id: String?, token: String?) = (nil, nil)
    ) -> (APIClient, InMemoryKeychain) {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: cf.id,
            cfAccessClientToken: cf.token,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
        return (api, keychain)
    }

    @Test("Bearer token attached when present in keychain")
    func bearerHeader() async throws {
        let (api, kc) = makeClient()
        try kc.setString("hlk_test", forKey: KeychainKey.authToken)

        nonisolated(unsafe) var capturedAuth: String?
        MockURLProtocol.handler = { req in
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            // Server emits camelCase (Next.js + Prisma); APIClient does no snake-to-camel conversion.
            let body = #"{"data":{"id":"u1","email":"a@b.c","username":null,"displayName":null,"createdAt":"2026-04-22T10:00:00Z"}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let req: APIRequest<User> = .get("/api/user/profile")
        _ = try await api.send(req)
        #expect(capturedAuth == "Bearer hlk_test")
    }

    @Test("Idempotency-Key set on POST")
    func idempotency() async throws {
        let (api, _) = makeClient()
        nonisolated(unsafe) var capturedIdem: String?
        MockURLProtocol.handler = { req in
            capturedIdem = req.value(forHTTPHeaderField: "Idempotency-Key")
            let body = #"{"data":{}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let req = APIRequest<EmptyPayload>(method: .post, path: "/api/x", body: Data("{}".utf8))
        try await api.sendVoid(req)
        #expect(capturedIdem != nil)
    }

    @Test("CF-Access headers attached when configured")
    func cfHeaders() async {
        let (api, _) = makeClient(cf: ("client-id", "client-token"))
        nonisolated(unsafe) var captured: [String: String] = [:]
        MockURLProtocol.handler = { req in
            for h in ["cf-access-client-id", "cf-access-client-token"] {
                captured[h] = req.value(forHTTPHeaderField: h)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"data":null}"#.utf8))
        }
        let req: APIRequest<EmptyPayload> = .get("/api/x")
        _ = try? await api.send(req)
        #expect(captured["cf-access-client-id"] == "client-id")
        #expect(captured["cf-access-client-token"] == "client-token")
    }

    @Test("401 throws unauthorized")
    func unauthorized() async {
        let (api, _) = makeClient()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, nil)
        }
        do {
            let req: APIRequest<EmptyPayload> = .get("/api/x")
            _ = try await api.send(req)
            Issue.record("expected throw")
        } catch let err as HLError {
            #expect(err == .unauthorized)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("5xx retries up to maxRetries then fails")
    func retries() async {
        let (api, _) = makeClient()
        nonisolated(unsafe) var attempts = 0
        MockURLProtocol.handler = { req in
            attempts += 1
            return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let req = APIRequest<EmptyPayload>(method: .get, path: "/api/x", maxRetries: 2)
        _ = try? await api.send(req)
        #expect(attempts == 3) // initial + 2 retries
    }
}
