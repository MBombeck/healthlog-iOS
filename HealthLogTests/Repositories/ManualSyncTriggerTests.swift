import Foundation
import Testing

// swiftlint:disable force_unwrapping

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **CU-35 (1) — the manual sync trigger, end to end over the real `APIClient`.**
///
/// `POST /api/{oura,polar,strava,nightscout}/sync` (server v1.32.28) is **not in
/// the OpenAPI**; every expectation below was taken off the four route files and
/// `src/lib/outcome/written-outcome.ts` directly. That makes these tests the only
/// written record of the contract on this side, which is why they pin the wire
/// shape and not just the happy path.
///
/// The suite exercises the real `APIClient` over `MockURLProtocol` (PROJECT_GUIDE.md
/// doctrine — never a hand-rolled mock server), so an envelope or status-mapping
/// drift is caught here rather than on a device.
///
/// `.serialized` because the handler is a process-global and several tests count
/// requests: a parallel suite writing the closure would make the counts lie.
@Suite("CU-35 — manual sync trigger", .serialized)
struct ManualSyncTriggerTests {
    // MARK: - Fixtures

    private struct RecordedCall {
        let method: String
        let path: String
        let query: String?
    }

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [RecordedCall] = []

        func record(_ req: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            entries.append(
                RecordedCall(
                    method: req.httpMethod ?? "",
                    path: req.url?.path ?? "",
                    query: req.url?.query
                )
            )
        }

        var snapshot: [RecordedCall] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private static func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    /// Answers `/sync` with `status` + `json`, and every other path with a
    /// connected `/status` snapshot so the stores' post-sync re-read succeeds.
    private static func install(log: RequestLog?, status: Int, json: String) {
        MockURLProtocol.handler = { req in
            log?.record(req)
            let path = req.url?.path ?? ""
            if path.hasSuffix("/sync") {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8)
                )
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"connected":true,"state":"ok"},"error":null}"#.utf8)
            )
        }
    }

    // MARK: - Wire shape

    @Test(
        "POSTs /api/<provider>/sync with no query — for all four providers",
        arguments: [
            (OAuthIntegrationRepository.Provider.oura, "/api/oura/sync"),
            (.polar, "/api/polar/sync"),
            (.strava, "/api/strava/sync"),
            (.fitbit, "/api/fitbit/sync")
        ]
    )
    func oauthSyncPath(provider: OAuthIntegrationRepository.Provider, path: String) async throws {
        let log = RequestLog()
        Self.install(log: log, status: 200, json: #"{"data":{"imported":3,"failed":false,"outcome":"success"},"error":null}"#)
        let result = try await OAuthIntegrationRepository(api: Self.makeAPI(), provider: provider).sync()

        let call = try #require(log.snapshot.first)
        #expect(call.method == "POST")
        #expect(call.path == path)
        // "kein Body, keine Query" — the window is not the caller's to choose.
        #expect(call.query == nil)
        #expect(result.imported == 3)
        #expect(result.outcome == .success)
    }

    @Test("Nightscout posts its own /api/nightscout/sync")
    func nightscoutSyncPath() async throws {
        let log = RequestLog()
        Self.install(log: log, status: 200, json: #"{"data":{"imported":12,"failed":false,"outcome":"success"},"error":null}"#)
        let result = try await NightscoutRepository(api: Self.makeAPI()).sync()

        let call = try #require(log.snapshot.first)
        #expect(call.method == "POST")
        #expect(call.path == "/api/nightscout/sync")
        #expect(call.query == nil)
        #expect(result.imported == 12)
    }

    @Test("every provider now offers the manual trigger — not Fitbit alone")
    func everyProviderSupportsManualSync() {
        for provider in OAuthIntegrationRepository.Provider.allCases {
            #expect(provider.supportsManualSync, "\(provider.rawValue) lost its /sync route")
        }
    }

    // MARK: - The four outcomes

    @Test(
        "the server's own verdict is adopted verbatim",
        arguments: [
            (#"{"imported":0,"failed":false,"outcome":"empty"}"#, 0, false, ManualSyncOutcome.empty),
            (#"{"imported":0,"failed":true,"outcome":"failed"}"#, 0, true, ManualSyncOutcome.failed),
            (#"{"imported":7,"failed":true,"outcome":"partial"}"#, 7, true, ManualSyncOutcome.partial),
            (#"{"imported":7,"failed":false,"outcome":"success"}"#, 7, false, ManualSyncOutcome.success)
        ]
    )
    func outcomeDecodes(payload: String, imported: Int, failed: Bool, outcome: ManualSyncOutcome) async throws {
        Self.install(log: nil, status: 200, json: #"{"data":\#(payload),"error":null}"#)
        let result = try await OAuthIntegrationRepository(api: Self.makeAPI(), provider: .oura).sync()
        #expect(result.imported == imported)
        #expect(result.failed == failed)
        #expect(result.outcome == outcome)
    }

    @Test("`empty` is a completed run, not a setback — and `failed` at 0 is not `empty`")
    func emptyIsNotAFailure() {
        #expect(!ManualSyncOutcome.empty.isSetback)
        #expect(!ManualSyncOutcome.success.isSetback)
        #expect(ManualSyncOutcome.partial.isSetback)
        #expect(ManualSyncOutcome.failed.isSetback)
        // The distinction the server's `classifyWrittenOutcome` exists for: a
        // window whose every row was refused imports 0 and must NOT read like a
        // quiet night.
        #expect(ManualSyncOutcome.derived(imported: 0, failed: false) == .empty)
        #expect(ManualSyncOutcome.derived(imported: 0, failed: true) == .failed)
    }

    @Test("Fitbit's extra `fullSync` key rides along without breaking the decode")
    func fitbitExtraKeyTolerated() async throws {
        Self.install(
            log: nil,
            status: 200,
            json: #"{"data":{"imported":2,"failed":false,"outcome":"success","fullSync":false},"error":null}"#
        )
        let result = try await OAuthIntegrationRepository(api: Self.makeAPI(), provider: .fitbit).sync()
        #expect(result.imported == 2)
        #expect(result.outcome == .success)
    }

    @Test("an outcome literal this build does not know falls back to the server's own rule")
    func unknownOutcomeIsTolerated() async throws {
        Self.install(
            log: nil,
            status: 200,
            json: #"{"data":{"imported":0,"failed":true,"outcome":"quarantined"},"error":null}"#
        )
        let result = try await OAuthIntegrationRepository(api: Self.makeAPI(), provider: .polar).sync()
        // Not a thrown decode error, and not a false "empty": 0 written with a
        // refusal is `failed`.
        #expect(result.outcome == .failed)
    }

    // MARK: - The three states, distinguishable

    @Test("429 rate_limited_self classifies as the friendly 'you just did', not a failure")
    func rateLimitedIsItsOwnState() async throws {
        let log = RequestLog()
        Self.install(
            log: log,
            status: 429,
            json: #"{"data":null,"error":"Too many sync requests","meta":{"errorCode":"rate_limited_self"}}"#
        )
        await #expect(throws: HLError.self) {
            _ = try await OAuthIntegrationRepository(api: Self.makeAPI(), provider: .strava).sync()
        }
        do {
            _ = try await OAuthIntegrationRepository(api: Self.makeAPI(), provider: .strava).sync()
            Issue.record("a 429 must not resolve")
        } catch {
            #expect(ManualSyncState.classify(error) == .rateLimited(retryAfter: nil))
            #expect(ManualSyncState.classify(error) != .upstreamUnavailable)
        }
        // `maxRetries: 0` — one attempt per call, so a tap cannot spend the
        // 5-per-60s budget four times over. Two calls above ⇒ exactly two.
        #expect(log.snapshot.count == 2, "the rate-limited route must not be retried")
    }

    @Test("502 classifies as an UPSTREAM problem — not a generic failure")
    func upstreamIsItsOwnState() async throws {
        let log = RequestLog()
        Self.install(log: log, status: 502, json: #"{"data":null,"error":"Oura sync failed"}"#)
        do {
            _ = try await OAuthIntegrationRepository(api: Self.makeAPI(), provider: .oura).sync()
            Issue.record("a 502 must not resolve")
        } catch {
            let state = ManualSyncState.classify(error)
            #expect(state == .upstreamUnavailable)
            // The three registers are genuinely distinct — this is the whole
            // point of the state enum.
            if case .failed = state { Issue.record("502 must not read as a generic failure") }
            #expect(state != .rateLimited(retryAfter: nil))
        }
        // A 5xx is retriable by default; `maxRetries: 0` stops the client from
        // turning one tap into four fan-outs at the provider.
        #expect(log.snapshot.count == 1, "the 502 must not be retried")
    }

    @Test("anything else stays a plain failure with user-facing copy")
    func otherErrorsRemainFailures() {
        let state = ManualSyncState.classify(HLError.server(status: 500, code: nil, message: "boom"))
        guard case let .failed(text) = state else {
            Issue.record("a 500 should classify as .failed, got \(state)")
            return
        }
        #expect(!text.isEmpty)
        // Defense in depth: a 5xx must never leak the server's own message.
        #expect(text != "boom")
    }

    @Test("a known reset window is carried into the state so the copy can name it")
    func retryAfterSurvivesClassification() {
        #expect(
            ManualSyncState.classify(HLError.rateLimited(retryAfter: 42)) == .rateLimited(retryAfter: 42)
        )
    }

    // MARK: - Store behaviour

    @MainActor
    @Test("a 429 lands on syncState ONLY — the red error line stays empty")
    func rateLimitDoesNotPaintAnError() async {
        Self.install(
            log: nil,
            status: 429,
            json: #"{"data":null,"error":"Too many sync requests","meta":{"errorCode":"rate_limited_self"}}"#
        )
        let store = OAuthIntegrationCore(
            repo: OAuthIntegrationRepository(api: Self.makeAPI(), provider: .oura),
            provider: .oura
        )
        await store.syncNow()
        #expect(store.syncState == .rateLimited(retryAfter: nil))
        #expect(store.error == nil, "a 429 is not the user's fault and must not read as a defect")
    }

    @MainActor
    @Test("a 502 lands on syncState ONLY — it is the provider's problem, not ours")
    func upstreamDoesNotPaintAnError() async {
        Self.install(log: nil, status: 502, json: #"{"data":null,"error":"Nightscout sync failed"}"#)
        let store = NightscoutIntegrationStore(repo: NightscoutRepository(api: Self.makeAPI()))
        await store.syncNow()
        #expect(store.syncState == .upstreamUnavailable)
        #expect(store.error == nil)
    }

    @MainActor
    @Test("a successful empty run publishes the honest non-event, not a failure")
    func emptyRunPublishesFinished() async {
        Self.install(
            log: nil,
            status: 200,
            json: #"{"data":{"imported":0,"failed":false,"outcome":"empty"},"error":null}"#
        )
        let store = OAuthIntegrationCore(
            repo: OAuthIntegrationRepository(api: Self.makeAPI(), provider: .polar),
            provider: .polar
        )
        await store.syncNow()
        guard let result = store.syncState.result else {
            Issue.record("an empty run should still publish a finished result, got \(store.syncState)")
            return
        }
        #expect(result.outcome == .empty)
        #expect(result.imported == 0)
        #expect(store.error == nil)
    }

    @MainActor
    @Test("a genuine failure still reaches the shared error surface")
    func genuineFailureStillErrors() async {
        Self.install(log: nil, status: 500, json: #"{"data":null,"error":"kaputt"}"#)
        let store = OAuthIntegrationCore(
            repo: OAuthIntegrationRepository(api: Self.makeAPI(), provider: .fitbit),
            provider: .fitbit
        )
        await store.syncNow()
        if case .failed = store.syncState {} else {
            Issue.record("a 500 should land on .failed, got \(store.syncState)")
        }
        #expect(store.error != nil)
    }
}

// swiftlint:enable force_unwrapping
