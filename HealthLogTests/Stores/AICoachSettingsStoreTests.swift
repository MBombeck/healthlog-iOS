// swiftlint:disable force_unwrapping
import Foundation
@testable import HealthLog
import Testing

/// **Build 6 / Item 6.6 — Coach/AI privacy toggle persistence.**
///
/// Exercises `AICoachSettingsStore` over the **real** `APIClient` with a stubbed
/// `URLSession` (`MockURLProtocol`) — never a mock server (PROJECT_GUIDE.md). Pins the
/// wire contract of both flags against the verified server routes:
///   - `GET / PATCH /api/auth/me/documents-auto-ai-read`
///   - `GET / PUT  /api/insights/settings` (`privacyMode` field)
/// plus the store's optimistic-write + revert-on-rejection semantics and the
/// tolerant load path (a missing field must not blank the control or crash).
@MainActor
@Suite("AICoachSettingsStore", .serialized)
struct AICoachSettingsStoreTests {
    private func makeStore(defaults: UserDefaults? = nil) -> AICoachSettingsStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        // Per-suite UserDefaults so the Build 9 mirror keys never bleed into
        // `.standard` (or across tests).
        let d = defaults ?? UserDefaults(suiteName: "AICoachSettingsStoreTests.\(UUID().uuidString)")!
        return AICoachSettingsStore(repo: AICoachSettingsRepository(api: api), defaults: d)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AICoachSettingsStoreTests.\(UUID().uuidString)")!
    }

    private static let coachDisabledKey = "hl.settings.coach.disabled"
    private static let reminderMirrorKey = "hl.settings.coach.reminderSuggestions.enabled"

    /// `URLProtocol` swaps `httpBody` for `httpBodyStream` — re-materialize.
    nonisolated static func consumeStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var buf = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&raw, maxLength: 4096)
            guard read > 0 else { break }
            buf.append(raw, count: read)
        }
        return buf.isEmpty ? nil : buf
    }

    // `nonisolated`: pure response builder, called from the @Sendable
    // `MockURLProtocol.handler` closures (off-main) — the @MainActor suite would
    // otherwise isolate it and the handler can't reach it.
    private nonisolated static func ok(_ req: URLRequest, _ payload: String) -> (HTTPURLResponse, Data?) {
        let http = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (http, Data(payload.utf8))
    }

    // MARK: - Load

    @Test("load hydrates both flags from their own routes")
    func loadHydratesBoth() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            switch req.url?.path {
            case "/api/auth/me/documents-auto-ai-read":
                Self.ok(req, #"{"data":{"documentsAutoAiRead":true},"error":null}"#)
            case "/api/insights/settings":
                Self.ok(req, #"{"data":{"privacyMode":"raw"},"error":null}"#)
            default:
                Self.ok(req, #"{"data":{},"error":null}"#)
            }
        }
        await store.load()
        #expect(store.documentsAutoAiRead == true)
        #expect(store.insightsPrivacyMode == .raw)
        #expect(store.didLoad)
        #expect(store.error == nil)
    }

    @Test("load tolerates a documents route that omits the field → OFF, no crash")
    func loadToleratesMissingDocumentsField() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            switch req.url?.path {
            case "/api/auth/me/documents-auto-ai-read":
                // Older / partial payload — field absent.
                Self.ok(req, #"{"data":{},"error":null}"#)
            case "/api/insights/settings":
                Self.ok(req, #"{"data":{"privacyMode":"aggregated"},"error":null}"#)
            default:
                Self.ok(req, #"{"data":{},"error":null}"#)
            }
        }
        await store.load()
        #expect(store.documentsAutoAiRead == false)
        #expect(store.insightsPrivacyMode == .aggregated)
        #expect(store.didLoad)
    }

    // MARK: - documentsAutoAiRead write

    @Test("setDocumentsAutoAiRead PATCHes the route and hard-sets the echoed value")
    func setDocumentsPersists() async throws {
        let store = makeStore()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        nonisolated(unsafe) var capturedKey: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            capturedKey = req.value(forHTTPHeaderField: "Idempotency-Key")
            return Self.ok(req, #"{"data":{"documentsAutoAiRead":true},"error":null}"#)
        }
        await store.setDocumentsAutoAiRead(true)

        #expect(capturedPath == "/api/auth/me/documents-auto-ai-read")
        #expect(capturedMethod == "PATCH")
        #expect(capturedKey?.isEmpty == false)
        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["documentsAutoAiRead"] as? Bool == true)
        #expect(store.documentsAutoAiRead == true)
        #expect(store.isDocumentsWriteInFlight == false)
        #expect(store.error == nil)
    }

    @Test("setDocumentsAutoAiRead reverts to the prior value on a server rejection")
    func setDocumentsRevertsOnError() async {
        let store = makeStore()
        // Seed: server currently OFF.
        MockURLProtocol.handler = { req in
            switch req.url?.path {
            case "/api/auth/me/documents-auto-ai-read":
                Self.ok(req, #"{"data":{"documentsAutoAiRead":false},"error":null}"#)
            default:
                Self.ok(req, #"{"data":{"privacyMode":"aggregated"},"error":null}"#)
            }
        }
        await store.load()
        #expect(store.documentsAutoAiRead == false)

        // The PATCH is rejected with a non-retriable 422 → the optimistic ON
        // must roll back to OFF so the UI never lies about persisted state.
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"data":null,"error":"Invalid request"}"#.utf8))
        }
        await store.setDocumentsAutoAiRead(true)

        #expect(store.documentsAutoAiRead == false)
        #expect(store.error != nil)
        #expect(store.isDocumentsWriteInFlight == false)
    }

    // MARK: - insightsPrivacyMode write

    @Test("setInsightsPrivacyMode PUTs the privacyMode token and keeps the value")
    func setInsightsPersists() async throws {
        let store = makeStore()
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedMethod: String?
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            capturedMethod = req.httpMethod
            capturedBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
            return Self.ok(req, #"{"data":{"updated":true},"error":null}"#)
        }
        await store.setInsightsPrivacyMode(.raw)

        #expect(capturedPath == "/api/insights/settings")
        #expect(capturedMethod == "PUT")
        let body = try #require(capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["privacyMode"] as? String == "raw")
        #expect(store.insightsPrivacyMode == .raw)
        #expect(store.error == nil)
    }

    @Test("setInsightsPrivacyMode reverts to the prior mode on a server rejection")
    func setInsightsRevertsOnError() async {
        let store = makeStore()
        // Store starts on the default `aggregated`; a rejected PUT to `raw` must
        // roll back to `aggregated`.
        MockURLProtocol.handler = { req in
            let http = HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (http, Data(#"{"data":null,"error":"Invalid privacy mode"}"#.utf8))
        }
        await store.setInsightsPrivacyMode(.raw)

        #expect(store.insightsPrivacyMode == .aggregated)
        #expect(store.error != nil)
    }

    // MARK: - Logout hygiene

    @Test("clearOnLogout resets both flags to their defaults")
    func clearOnLogoutResets() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            switch req.url?.path {
            case "/api/auth/me/documents-auto-ai-read":
                Self.ok(req, #"{"data":{"documentsAutoAiRead":true},"error":null}"#)
            default:
                Self.ok(req, #"{"data":{"privacyMode":"raw"},"error":null}"#)
            }
        }
        await store.load()
        #expect(store.documentsAutoAiRead == true)
        #expect(store.insightsPrivacyMode == .raw)

        store.clearOnLogout()
        #expect(store.documentsAutoAiRead == false)
        #expect(store.insightsPrivacyMode == .aggregated)
        #expect(store.didLoad == false)
    }

    // MARK: - Build 9 (Server-Prefs) / 9.2 — coach availability + reminders

    /// **Guard 1 (critical): no initial write.** A fresh load must NEVER PATCH
    /// disable-coach or PUT coach-prefs — even with local legacy off-states
    /// present. The initial state comes FROM the server.
    @Test("load never writes disableCoach / coach-prefs (no initial write)")
    func noInitialWrite() async {
        let defaults = freshDefaults()
        // Local legacy off-states that must NEVER be uploaded.
        defaults.set(false, forKey: "hl.minicoach.enabled")
        defaults.set(false, forKey: "hl.coach.cadenceSuggestions.enabled")
        nonisolated(unsafe) var patchCount = 0
        nonisolated(unsafe) var putCount = 0
        MockURLProtocol.handler = { req in
            if req.httpMethod == "PATCH" { patchCount += 1 }
            if req.httpMethod == "PUT" { putCount += 1 }
            switch req.url?.path {
            case "/api/auth/me/disable-coach":
                return Self.ok(req, #"{"data":{"disableCoach":false},"error":null}"#)
            case "/api/auth/me/coach-prefs":
                return Self.ok(req, #"{"data":{"tone":"neutral"},"error":null}"#)
            case "/api/auth/me/documents-auto-ai-read":
                return Self.ok(req, #"{"data":{"documentsAutoAiRead":false},"error":null}"#)
            default:
                return Self.ok(req, #"{"data":{"privacyMode":"aggregated"},"error":null}"#)
            }
        }
        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(patchCount == 0)
        #expect(putCount == 0)
        #expect(store.coachDisabled == false)
        #expect(store.reminderSuggestionsEnabled == true) // absent key → server default ON
    }

    @Test("server disableCoach:true maps to coachDisabled == true and mirrors")
    func semanticMapping() async {
        let defaults = freshDefaults()
        MockURLProtocol.handler = { req in
            switch req.url?.path {
            case "/api/auth/me/disable-coach":
                Self.ok(req, #"{"data":{"disableCoach":true},"error":null}"#)
            case "/api/auth/me/coach-prefs":
                Self.ok(req, #"{"data":{"reminderSuggestions":{"enabled":false}},"error":null}"#)
            default:
                Self.ok(req, #"{"data":{},"error":null}"#)
            }
        }
        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.coachDisabled == true)
        #expect(store.reminderSuggestionsEnabled == false)
        #expect(defaults.object(forKey: Self.coachDisabledKey) as? Bool == true)
        #expect(defaults.object(forKey: Self.reminderMirrorKey) as? Bool == false)
    }

    @Test("setReminderSuggestionsEnabled RMW PUT carries the GET siblings unchanged")
    func rmwEndToEnd() async throws {
        let defaults = freshDefaults()
        nonisolated(unsafe) var putBody: Data?
        MockURLProtocol.handler = { req in
            if req.httpMethod == "PUT", req.url?.path == "/api/auth/me/coach-prefs" {
                putBody = req.httpBody ?? req.httpBodyStream.flatMap(Self.consumeStream(_:))
                return Self.ok(req, #"{"data":{"ok":true},"error":null}"#)
            }
            switch req.url?.path {
            case "/api/auth/me/coach-prefs":
                return Self.ok(req, #"""
                {"data":{"tone":"warm","verbosity":"brief","reminderSuggestions":
                {"enabled":true,"stopped":false,"dismissedCadences":["x"],"lastSuggestedAt":null}},"error":null}
                """#)
            case "/api/auth/me/disable-coach":
                return Self.ok(req, #"{"data":{"disableCoach":false},"error":null}"#)
            default:
                return Self.ok(req, #"{"data":{},"error":null}"#)
            }
        }
        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.reminderSuggestionsEnabled == true)

        await store.setReminderSuggestionsEnabled(false)
        let json = try #require(putBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(json["tone"] as? String == "warm")
        #expect(json["verbosity"] as? String == "brief")
        let reminder = try #require(json["reminderSuggestions"] as? [String: Any])
        #expect(reminder["enabled"] as? Bool == false)
        #expect(reminder["dismissedCadences"] as? [String] == ["x"])
        #expect(store.reminderSuggestionsEnabled == false)
    }

    @Test("a later server change is adopted, never written back (no ping-pong)")
    func pingPongFree() async {
        let defaults = freshDefaults()
        // A reference box so the @Sendable handler counts writes without a
        // captured-var-mutated-after-capture data race.
        final class Counters: @unchecked Sendable {
            var patch = 0
            var put = 0
        }
        let counters = Counters()
        func handler(disableJSON: String) -> MockURLProtocol.Handler {
            { req in
                if req.httpMethod == "PATCH" { counters.patch += 1 }
                if req.httpMethod == "PUT" { counters.put += 1 }
                switch req.url?.path {
                case "/api/auth/me/disable-coach":
                    return Self.ok(req, disableJSON)
                case "/api/auth/me/coach-prefs":
                    return Self.ok(req, #"{"data":{"tone":"neutral"},"error":null}"#)
                default:
                    return Self.ok(req, #"{"data":{},"error":null}"#)
                }
            }
        }
        MockURLProtocol.handler = handler(disableJSON: #"{"data":{"disableCoach":false},"error":null}"#)
        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.coachDisabled == false)

        // Web-side change: re-install the handler with the new server value.
        MockURLProtocol.handler = handler(disableJSON: #"{"data":{"disableCoach":true},"error":null}"#)
        await store.load()
        #expect(store.coachDisabled == true)
        #expect(counters.patch == 0)
        #expect(counters.put == 0)
    }

    @Test("disable-coach 500 leaves coachDisabled nil; absent reminderSuggestions → true")
    func tolerantLoad() async {
        let defaults = freshDefaults()
        MockURLProtocol.handler = { req in
            switch req.url?.path {
            case "/api/auth/me/disable-coach":
                let http = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (http, Data(#"{"data":null,"error":"boom"}"#.utf8))
            case "/api/auth/me/coach-prefs":
                return Self.ok(req, #"{"data":{"tone":"neutral"},"error":null}"#)
            default:
                return Self.ok(req, #"{"data":{},"error":null}"#)
            }
        }
        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.coachDisabled == nil)
        #expect(defaults.object(forKey: Self.coachDisabledKey) == nil) // not written
        #expect(store.reminderSuggestionsEnabled == true)
        #expect(defaults.object(forKey: Self.reminderMirrorKey) as? Bool == true)
    }

    @Test("clearOnLogout resets the coach flags + removes the mirror keys")
    func coachLogoutClears() async {
        let defaults = freshDefaults()
        MockURLProtocol.handler = { req in
            switch req.url?.path {
            case "/api/auth/me/disable-coach":
                Self.ok(req, #"{"data":{"disableCoach":true},"error":null}"#)
            case "/api/auth/me/coach-prefs":
                Self.ok(req, #"{"data":{"reminderSuggestions":{"enabled":false}},"error":null}"#)
            default:
                Self.ok(req, #"{"data":{},"error":null}"#)
            }
        }
        let store = makeStore(defaults: defaults)
        await store.load()
        #expect(store.coachDisabled == true)
        #expect(store.reminderSuggestionsEnabled == false)

        store.clearOnLogout()
        #expect(store.coachDisabled == nil)
        #expect(store.reminderSuggestionsEnabled == nil)
        #expect(defaults.object(forKey: Self.coachDisabledKey) == nil)
        #expect(defaults.object(forKey: Self.reminderMirrorKey) == nil)
    }
}
