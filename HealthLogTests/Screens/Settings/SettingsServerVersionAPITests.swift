import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.5.5.2 W-IMPL-SERVER-EDITOR — Settings → Server pulls the running
/// server build's `{ version, buildSha, builtAt }` via
/// `APIClient.fetchServerVersion()` against `GET /api/version`. The
/// server route (`src/app/api/version/route.ts`) wraps the payload in
/// the canonical `{ data, error }` envelope; the decoder honours the
/// envelope branch already proven by `APIClientTests.bearerHeader`.
@Suite("APIClient — fetchServerVersion", .serialized)
struct SettingsServerVersionAPITests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.5",
            buildNumber: "22"
        )
        let kc = InMemoryKeychain()
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    @Test("Decodes envelope with full version + sha + builtAt")
    func decodesFullEnvelope() async throws {
        let api = makeClient()
        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            let body = Data(#"""
            {"data":{"version":"1.4.39","buildSha":"28594dc8","builtAt":"2026-05-21T08:14:00.000Z","license":"AGPL-3.0","repository":"https://github.com/example/healthlog","changelog":"https://github.com/example/healthlog/blob/main/CHANGELOG.md","docs":"https://docs.healthlog.dev","offlineGeoEnabled":true},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let info = try await api.fetchServerVersion()
        #expect(capturedPath == "/api/version")
        #expect(info.version == "1.4.39")
        #expect(info.buildSha == "28594dc8")
        #expect(info.builtAt == "2026-05-21T08:14:00.000Z")
    }

    @Test("Decodes envelope with null buildSha + builtAt (pnpm dev shape)")
    func decodesDevShape() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"version":"1.4.40-dev","buildSha":null,"builtAt":null,"license":"AGPL-3.0","repository":"https://github.com/example/healthlog","changelog":"https://github.com/example/healthlog/blob/main/CHANGELOG.md","docs":"https://docs.healthlog.dev","offlineGeoEnabled":false},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let info = try await api.fetchServerVersion()
        #expect(info.version == "1.4.40-dev")
        #expect(info.buildSha == nil)
        #expect(info.builtAt == nil)
    }

    @Test("Surfaces server error envelope as HLError.server")
    func surfacesServerError() async {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Internal error"}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, body)
        }
        do {
            _ = try await api.fetchServerVersion()
            Issue.record("expected throw")
        } catch let HLError.server(status, _, message) {
            #expect(status == 500)
            #expect(message == "Internal error")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("ServerVersionInfo ignores future server fields (forward-compatible)")
    func forwardCompatibleDecoding() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"version":"1.5.0","buildSha":"abc1234","builtAt":"2026-06-01T00:00:00.000Z","futureField":"will-not-break-decoder","nested":{"more":"data"}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let info = try await api.fetchServerVersion()
        #expect(info.version == "1.5.0")
        #expect(info.buildSha == "abc1234")
    }
}

// swiftlint:enable force_unwrapping
