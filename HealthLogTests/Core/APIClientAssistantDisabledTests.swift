import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// #114 / #115 · 0.2 — locks how `APIClient` reads an AI refusal.
///
/// Server v1.39 answers every refused AI action with
/// `{ data: null, error, meta: { errorCode, capability, reason, module? } }`
/// (`src/lib/ai/capabilities/refusal.ts` `aiRefusal()`; the envelope schema is
/// OpenAPI `ErrorResponse.meta`). The fixtures below are that function's
/// output, one per reason. Before this build the client read only the
/// TOP-LEVEL `errorCode` and only four invented surface names
/// (`briefing`/`coach`/`trend`/`insights`), so not one v1.39 refusal was
/// recognised: an operator-disabled Coach surfaced as a plain 403, which the
/// Coach sheet worded as "needs your consent".
///
/// The contract:
/// - `assistant.disabled.<switch>` on a 403 → `HLError.aiUnavailable`, any
///   switch (incl. the overall `enabled` and names this build does not know);
/// - `ai.record.notPermitted` / `ai.provider.none` / `ai.unavailable` →
///   `HLError.aiUnavailable` on their own statuses (403 / 422 or 503 / 503);
/// - `meta.capability` + `meta.reason` travel with it, tolerant;
/// - `consent.ai.required` and plain 403s stay `HLError.server` with the
///   `meta` code; `module.disabled` stays `HLError.moduleDisabled`;
/// - an `assistant.disabled.*` code on a non-403 is not the refusal shape;
/// - the pre-v1.39 top-level `errorCode` is still read as a fallback.
@Suite("APIClient — AI refusal envelope (v1.39 meta)", .serialized, .mockURLSession)
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

    private func respond(status: Int, body: String) {
        MockURLProtocol.install { req in
            (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    private func thrown(_ api: APIClient, path: String = "/api/insights/generate") async -> HLError? {
        let req: APIRequest<EmptyPayload> = .get(path)
        do {
            _ = try await api.send(req)
            return nil
        } catch {
            return error as? HLError
        }
    }

    private func refusal(_ error: HLError?) -> AIRefusal? {
        if case let .aiUnavailable(refusal)? = error { return refusal }
        return nil
    }

    // MARK: - Operator switches

    @Test(
        "403 meta assistant.disabled.<switch> → aiUnavailable with capability + reason",
        arguments: [
            ("briefing", "briefing"),
            ("coach", "coach"),
            ("insightStatus", "statusText"),
            ("documentAi", "documentAi"),
            ("enabled", "coach")
        ]
    )
    func operatorSwitch(operatorSwitch: String, capability: String) async throws {
        let api = makeClient()
        respond(status: 403, body: #"""
        {"data":null,"error":"This AI feature is turned off on this server",
         "meta":{"errorCode":"assistant.disabled.\#(operatorSwitch)","capability":"\#(capability)","reason":"operator_disabled"}}
        """#)
        let got = try #require(await refusal(thrown(api)))
        #expect(got.errorCode == "assistant.disabled.\(operatorSwitch)")
        #expect(got.capability == AICapabilityKey(rawValue: capability))
        #expect(got.reason == .operatorDisabled)
        #expect(got.kind == .operatorDisabled(operatorSwitch: operatorSwitch))
        #expect(got.httpStatus == 403)
    }

    @Test("The overall switch `enabled` without meta.capability covers every capability")
    func overallSwitchCoversAll() async throws {
        let api = makeClient()
        respond(status: 403, body: #"{"data":null,"error":"off","meta":{"errorCode":"assistant.disabled.enabled"}}"#)
        let got = try #require(await refusal(thrown(api)))
        #expect(Set(got.affectedCapabilities) == Set(AICapabilityKey.allCases))
    }

    @Test("An operator switch this build does not know is still typed (tolerant), affecting nothing it cannot name")
    func unknownSwitchTyped() async throws {
        let api = makeClient()
        respond(status: 403, body: #"{"data":null,"error":"off","meta":{"errorCode":"assistant.disabled.futureSwitch"}}"#)
        let got = try #require(await refusal(thrown(api, path: "/api/insights/future")))
        #expect(got.kind == .operatorDisabled(operatorSwitch: "futureSwitch"))
        #expect(got.affectedCapabilities.isEmpty)
    }

    // MARK: - The three new v1.39 codes

    @Test("403 ai.record.notPermitted → aiUnavailable(.recordNotPermitted)")
    func recordNotPermitted() async throws {
        let api = makeClient()
        respond(status: 403, body: #"""
        {"data":null,"error":"AI work is not available for this record",
         "meta":{"errorCode":"ai.record.notPermitted","capability":"coach","reason":"not_permitted_for_record"}}
        """#)
        let got = try #require(await refusal(thrown(api, path: "/api/insights/chat")))
        #expect(got.kind == .recordNotPermitted)
        #expect(got.reason == .notPermittedForRecord)
        #expect(got.impliedState.allowsOnDevice == false)
    }

    @Test("422 ai.provider.none → aiUnavailable(.noProvider), device still allowed")
    func providerNone() async throws {
        let api = makeClient()
        respond(status: 422, body: #"""
        {"data":null,"error":"No AI provider is set up for this feature",
         "meta":{"errorCode":"ai.provider.none","capability":"documentAi","reason":"no_provider"}}
        """#)
        let got = try #require(await refusal(thrown(api, path: "/api/documents/inbound/d1/summary")))
        #expect(got.kind == .noProvider)
        #expect(got.httpStatus == 422)
        #expect(got.impliedState.allowsOnDevice)
    }

    @Test("medications/extract keeps 503 but carries meta ai.provider.none (#114 addendum) → aiUnavailable")
    func medicationExtract503ProviderNone() async throws {
        let api = makeClient()
        respond(status: 503, body: #"""
        {"data":null,"error":"No AI provider configured",
         "meta":{"errorCode":"ai.provider.none","capability":"medicationExtract","reason":"no_provider"}}
        """#)
        let got = try #require(await refusal(thrown(api, path: "/api/medications/extract")))
        #expect(got.kind == .noProvider)
        #expect(got.capability == .medicationExtract)
        #expect(got.httpStatus == 503)
    }

    @Test("503 ai.unavailable → aiUnavailable(.unavailable) (check_failed)")
    func checkFailed() async throws {
        let api = makeClient()
        respond(status: 503, body: #"""
        {"data":null,"error":"AI is unavailable right now",
         "meta":{"errorCode":"ai.unavailable","capability":"briefing","reason":"check_failed"}}
        """#)
        let got = try #require(await refusal(thrown(api)))
        #expect(got.kind == .unavailable)
        #expect(got.reason == .checkFailed)
    }

    // MARK: - Tolerance

    @Test("Unknown meta.reason / meta.capability decode tolerantly")
    func unknownReasonAndCapability() async throws {
        let api = makeClient()
        respond(status: 403, body: #"""
        {"data":null,"error":"off",
         "meta":{"errorCode":"assistant.disabled.coach","capability":"futureCapability","reason":"zz_from_the_future"}}
        """#)
        let got = try #require(await refusal(thrown(api)))
        #expect(got.capability == nil)
        #expect(got.reason == .unknown)
        // No capability named → the switch's capabilities are affected.
        #expect(Set(got.affectedCapabilities) == [.coach, .aboutMeQuestions])
    }

    @Test("Pre-v1.39 top-level errorCode is still read as a fallback")
    func legacyTopLevelCode() async throws {
        let api = makeClient()
        respond(status: 403, body: #"{"data":null,"error":"Briefing disabled by operator","errorCode":"assistant.disabled.briefing"}"#)
        let got = try #require(await refusal(thrown(api)))
        #expect(got == AIRefusal(errorCode: "assistant.disabled.briefing"))
    }

    // MARK: - What stays untyped

    @Test("403 meta consent.ai.required stays HLError.server with the meta code")
    func consentStaysServer() async {
        let api = makeClient()
        respond(status: 403, body: #"""
        {"data":null,"error":"AI consent is required for this feature",
         "meta":{"errorCode":"consent.ai.required","capability":"coach","reason":"consent_required"}}
        """#)
        let error = await thrown(api, path: "/api/insights/chat")
        guard case let .server(status, code, _)? = error else {
            Issue.record("expected HLError.server, got \(String(describing: error))")
            return
        }
        #expect(status == 403)
        #expect(code == "consent.ai.required")
    }

    @Test("assistant.disabled.* on a non-403 is not the refusal shape")
    func nonForbiddenStaysServer() async {
        let api = makeClient()
        respond(status: 422, body: #"{"data":null,"error":"Validation failed","meta":{"errorCode":"assistant.disabled.briefing"}}"#)
        let error = await thrown(api)
        guard case let .server(status, code, _)? = error else {
            Issue.record("expected HLError.server, got \(String(describing: error))")
            return
        }
        #expect(status == 422)
        #expect(code == "assistant.disabled.briefing")
    }

    @Test("403 without any code stays a generic HLError.server")
    func plainForbiddenStaysServer() async {
        let api = makeClient()
        respond(status: 403, body: #"{"data":null,"error":"Forbidden"}"#)
        let error = await thrown(api)
        guard case let .server(status, code, _)? = error else {
            Issue.record("expected HLError.server, got \(String(describing: error))")
            return
        }
        #expect(status == 403)
        #expect(code == nil)
    }

    // MARK: - Mirrors

    @Test("A refusal fires the AI-refusal mirror handler with the parsed refusal")
    func mirrorHandlerFiresOnTypedSurface() async {
        let api = makeClient()
        let received = SendableSlot<AIRefusal>()
        await api.setAIRefusalHandler { @Sendable refusal in
            await received.set(refusal)
        }
        respond(status: 403, body: #"""
        {"data":null,"error":"off","meta":{"errorCode":"assistant.disabled.briefing","capability":"briefing","reason":"operator_disabled"}}
        """#)
        #expect(await refusal(thrown(api)) != nil)
        let captured = await received.waitFor(timeoutMs: 500)
        #expect(captured?.capability == .briefing)
        #expect(captured?.reason == .operatorDisabled)
    }

    @Test("module.disabled beside an AI refusal stays moduleDisabled AND reaches the AI mirror with its reason")
    func moduleDisabledAIRefusal() async {
        let api = makeClient()
        let received = SendableSlot<AIRefusal>()
        await api.setAIRefusalHandler { @Sendable refusal in
            await received.set(refusal)
        }
        // `aiRefusal("coach", "user_disabled", "coach")` — the person's own
        // "Hide Coach" switch.
        respond(status: 403, body: #"""
        {"data":null,"error":"This AI feature is turned off in your settings",
         "meta":{"errorCode":"module.disabled","capability":"coach","reason":"user_disabled","module":"coach"}}
        """#)
        let error = await thrown(api, path: "/api/insights/chat")
        guard case let .moduleDisabled(module)? = error else {
            Issue.record("expected moduleDisabled, got \(String(describing: error))")
            return
        }
        #expect(module == "coach")
        let captured = await received.waitFor(timeoutMs: 500)
        #expect(captured?.capability == .coach)
        #expect(captured?.reason == .userDisabled)
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
