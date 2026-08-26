import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the F-1 APIClient interception of the
/// `403 + errorCode: "assistant.disabled.<surface>"` envelope
/// (server brief v1.4.31 §5 + cross-coordination audit §c.1).
///
/// The contract:
/// - 403 + `errorCode: "assistant.disabled.briefing"` →
///   `HLError.assistantDisabled(.assistantBriefing)`
/// - 403 without `errorCode` or with a non-assistant code →
///   generic `HLError.server(status: 403, ...)` (no over-eager
///   typing)
/// - any other status with an `assistant.disabled.*` code →
///   generic `HLError.server(...)` (status discriminator gates the
///   typed branch so future server-surfaces can't accidentally
///   collide)
/// - the typed error wraps the matching ``FeatureFlag`` so the
///   caller can mirror state into ``FeatureFlagsStore`` without
///   parsing the wire string twice.
@Suite("APIClient — assistant-disabled envelope", .serialized)
struct APIClientAssistantDisabledTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    @Test("403 + assistant.disabled.briefing → HLError.assistantDisabled(.briefing)")
    func briefingSurfacesTypedError() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Briefing disabled by operator","errorCode":"assistant.disabled.briefing"}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/insights/generate")
        do {
            _ = try await api.send(req)
            Issue.record("expected assistantDisabled")
        } catch let HLError.assistantDisabled(flag) {
            #expect(flag == .assistantBriefing)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("403 + assistant.disabled.coach → HLError.assistantDisabled(.coach)")
    func coachSurfacesTypedError() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Coach disabled","errorCode":"assistant.disabled.coach"}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/insights/chat")
        do {
            _ = try await api.send(req)
            Issue.record("expected assistantDisabled")
        } catch let HLError.assistantDisabled(flag) {
            #expect(flag == .assistantCoach)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("403 + assistant.disabled.insights → HLError.assistantDisabled(.insights)")
    func insightsSurfacesTypedError() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Insights disabled","errorCode":"assistant.disabled.insights"}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/insights/comprehensive")
        do {
            _ = try await api.send(req)
            Issue.record("expected assistantDisabled")
        } catch let HLError.assistantDisabled(flag) {
            #expect(flag == .assistantInsights)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("403 + assistant.disabled.trend → HLError.assistantDisabled(.trend)")
    func trendSurfacesTypedError() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Trend disabled","errorCode":"assistant.disabled.trend"}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/insights/blood-pressure-status")
        do {
            _ = try await api.send(req)
            Issue.record("expected assistantDisabled")
        } catch let HLError.assistantDisabled(flag) {
            #expect(flag == .assistantTrend)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("403 without errorCode → generic HLError.server (no false-positive typing)")
    func plain403StaysGenericServerError() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":"Forbidden"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/restricted")
        do {
            _ = try await api.send(req)
            Issue.record("expected server error")
        } catch let HLError.server(status, code, _) {
            #expect(status == 403)
            #expect(code == nil)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("403 with non-assistant errorCode → generic HLError.server (passes code through)")
    func nonAssistantErrorCodeStaysGeneric() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Plan disabled","errorCode":"plan.disabled.premium"}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/premium-only")
        do {
            _ = try await api.send(req)
            Issue.record("expected server error")
        } catch let HLError.server(status, code, _) {
            #expect(status == 403)
            #expect(code == "plan.disabled.premium")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Non-403 with assistant.disabled.* code → generic HLError.server (status gates typing)")
    func nonForbiddenStaysGeneric() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            // 422 with assistant.disabled.briefing — should NOT promote
            // to assistantDisabled. Status is the discriminator.
            let body = Data(#"""
            {"data":null,"error":"Validation failed","errorCode":"assistant.disabled.briefing"}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/insights/generate")
        do {
            _ = try await api.send(req)
            Issue.record("expected server error")
        } catch let HLError.server(status, code, _) {
            #expect(status == 422)
            #expect(code == "assistant.disabled.briefing")
        } catch HLError.assistantDisabled {
            Issue.record("must not surface assistantDisabled for non-403")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("403 + assistant.disabled.* fires the assistant-disabled mirror handler")
    func mirrorHandlerFiresOnTypedSurface() async throws {
        let api = makeClient()
        // Capture the flag passed to the mirror handler.
        let received = SendableSlot<FeatureFlag>()
        await api.setAssistantDisabledHandler { @Sendable flag in
            await received.set(flag)
        }
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Briefing disabled","errorCode":"assistant.disabled.briefing"}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/insights/generate")
        do {
            _ = try await api.send(req)
            Issue.record("expected assistantDisabled")
        } catch HLError.assistantDisabled {
            // Wait briefly for the detached mirror task to land —
            // the handler runs fire-and-forget so we poll the slot
            // up to a short ceiling rather than blocking the throw.
            let captured = await received.waitFor(timeoutMs: 500)
            #expect(captured == .assistantBriefing)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("403 with unknown surface suffix → generic HLError.server (no silent typing)")
    func unknownSurfaceStaysGeneric() async throws {
        let api = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":"Disabled","errorCode":"assistant.disabled.futureSurface"}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let req: APIRequest<EmptyPayload> = .get("/api/insights/future")
        do {
            _ = try await api.send(req)
            Issue.record("expected server error")
        } catch HLError.assistantDisabled {
            Issue.record("must not surface assistantDisabled for unknown surface suffix")
        } catch let HLError.server(status, code, _) {
            #expect(status == 403)
            #expect(code == "assistant.disabled.futureSurface")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// swiftlint:enable force_unwrapping

/// Minimal Sendable cell for capturing async-fired values from a
/// fire-and-forget task. Polls `waitFor` until set or timeout —
/// no XCTest expectations on Swift Testing.
private actor SendableSlot<T: Sendable> {
    private var value: T?
    func set(_ v: T) {
        value = v
    }

    func get() -> T? {
        value
    }

    func waitFor(timeoutMs: Int) async -> T? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let v = value { return v }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        return value
    }
}
