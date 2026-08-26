import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the daily-briefing store behaviour against the v0.4.0 contract:
///
/// 1. `load()` calls `POST /api/insights/generate`, decodes the envelope, and
///    publishes the briefing/summary slots.
/// 2. `refresh()` always sends `force=true` (bypasses the 24h server cache).
/// 3. Errors surface via `.error` without clobbering a prior `response`.
/// 4. `CacheKey.dailyBriefing.staleAfter == 24h` (matches the SwiftData TTL).
///
/// Uses a real `APIClient` against `MockURLProtocol` — anti-pattern per
/// PROJECT_GUIDE.md is using a mock-server for replay paths because we miss
/// schema-drift bugs. We exercise the actual on-wire envelope.
@Suite("DailyBriefingStore", .serialized)
struct DailyBriefingStoreTests {
    @Test("Direct-fetch load populates briefing + summary + provider label")
    @MainActor
    func directFetchHappyPath() async {
        let (api, _) = makeAPIClient()
        // CU-07: the handler is process-global, so an in-handler `#expect` fires
        // on a PARALLEL suite's request too. Record OUR namespace and assert
        // afterwards instead — same claim, no dependence on the schedule.
        nonisolated(unsafe) var insightsPaths: [String] = []
        MockURLProtocol.handler = { request in
            if request.targets(prefixedBy: "/api/insights") {
                insightsPaths.append(request.url?.path ?? "")
            }
            return (Self.ok(request), Self.wrap(Self.successJSON))
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))

        await store.load()

        // Sanity: hits the generate endpoint, not comprehensive.
        #expect(!insightsPaths.isEmpty, "load() must reach the insights API")
        #expect(insightsPaths.allSatisfy { $0 == "/api/insights/generate" })

        #expect(store.summary == "Heute eingestellt: Werte im Zielbereich.")
        #expect(store.briefing?.paragraph.contains("132/86") == true)
        #expect(store.providerLabel == "Anthropic")
        #expect(store.error == nil)
        #expect(store.lastUpdatedAt != nil)
    }

    @Test("refresh() POST body sets force=true (bypasses 24h cache)")
    @MainActor
    func refreshSetsForceFlag() async {
        let (api, _) = makeAPIClient()
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { request in
            // CU-07: record only OUR route — the handler is process-global.
            if request.targets("/api/insights/generate") { capturedBody = request.bodyBytes() }
            return (Self.ok(request), Self.wrap(Self.successJSON))
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))
        await store.refresh()
        let bodyText = capturedBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(bodyText.contains("\"force\":true"))
        #expect(store.summary == "Heute eingestellt: Werte im Zielbereich.")
        #expect(store.isShowingStaleCache == false)
    }

    @Test("Error path surfaces .error without clobbering previous response")
    @MainActor
    func errorPathPreservesPrevious() async {
        let (api, _) = makeAPIClient()
        nonisolated(unsafe) var callCount = 0
        MockURLProtocol.handler = { request in
            // CU-07: only OUR route advances the phase machine.
            if request.targets("/api/insights/generate") { callCount += 1 }
            if callCount == 1 {
                return (Self.ok(request), Self.wrap(Self.successJSON))
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":"down"}"#.utf8))
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))
        await store.load()
        let first = store.summary
        #expect(first == "Heute eingestellt: Werte im Zielbereich.")
        await store.refresh()
        // Previous payload preserved; error surfaced.
        #expect(store.summary == first)
        #expect(store.error != nil)
    }

    @Test("clearOnLogout zeroes state")
    @MainActor
    func clearOnLogout() async {
        let (api, _) = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Self.wrap(Self.successJSON))
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))
        await store.load()
        #expect(store.summary != nil)
        store.clearOnLogout()
        #expect(store.response == nil)
        #expect(store.lastUpdatedAt == nil)
        #expect(store.isShowingStaleCache == false)
    }

    @Test("CacheKey.dailyBriefing has 24h staleAfter (matches SWR TTL contract)")
    func cacheKeyTTL() {
        #expect(CacheKey.dailyBriefing(day: "2026-06-06").staleAfter == 24 * 60 * 60)
    }

    /// AUD-6 Critical #1 — the briefing key is now day-anchored like every sibling
    /// daily key, so a new Berlin day is a STRUCTURAL cache miss (no longer serving
    /// yesterday's briefing all of today).
    @Test("CacheKey.dailyBriefing differs across Berlin days, stable within a day")
    func cacheKeyDayAnchored() {
        let today = CacheKey.dailyBriefing(day: "2026-06-06").persistentHash
        let tomorrow = CacheKey.dailyBriefing(day: "2026-06-07").persistentHash
        let sameAgain = CacheKey.dailyBriefing(day: "2026-06-06").persistentHash
        #expect(today != tomorrow)
        #expect(today == sameAgain)
        #expect(CacheKey.dailyBriefing(day: "2026-06-06").canonicalString == "dailyBriefing:2026-06-06")
    }

    @Test("load() short-circuits when consentGate returns false (R1/F5/PA9 RC5)")
    @MainActor
    func loadGatedByConsent() async {
        // Master-prompt v0.5.0+ F5 — DailyBriefingStore.load() must consult
        // the consent gate before any POST /api/insights/generate. Previously
        // the briefing endpoint bypassed S7's gate entirely, contradicting
        // App Store Guideline 5.1.2(i). The gate closure returning false
        // must leave `response` nil, no network call must fire.
        let (api, _) = makeAPIClient()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { request in
            // CU-07: `requestCount == 0` is only an assertion about the consent
            // gate if a parallel suite's request cannot raise it.
            if request.targets(prefixedBy: "/api/insights") { requestCount += 1 }
            return (Self.ok(request), Self.wrap(Self.successJSON))
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))
        // Wire the gate to a closed state — mirrors the production case
        // where the user has a remote LLM configured but has not yet
        // tapped "Akzeptieren" on the AIConsentSheet.
        store.consentGate = { false }

        await store.load()

        #expect(store.response == nil, "consent-denied load must not populate response")
        #expect(store.error == nil, "consent-denied load is a no-op, not an error")
        #expect(store.lastUpdatedAt == nil)
        #expect(requestCount == 0, "no network round-trip when consent is denied")
    }

    @Test("refresh() short-circuits when consentGate returns false")
    @MainActor
    func refreshGatedByConsent() async {
        // The user-initiated pull-to-refresh path must also respect the
        // gate — App Store rejection risk if pull-to-refresh sneaks data
        // past the consent boundary.
        let (api, _) = makeAPIClient()
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { request in
            // CU-07: `requestCount == 0` is only an assertion about the consent
            // gate if a parallel suite's request cannot raise it.
            if request.targets(prefixedBy: "/api/insights") { requestCount += 1 }
            return (Self.ok(request), Self.wrap(Self.successJSON))
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))
        store.consentGate = { false }

        await store.refresh()

        #expect(store.response == nil)
        #expect(requestCount == 0)
    }

    // MARK: - v1.16.x snapshot briefing slot (GH issue #15)

    @Test("Stale snapshot slot feeds briefing + staleBriefingAsOf even when gated")
    @MainActor
    func staleSnapshotBriefingSurfaces() async {
        let (api, _) = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Self.wrap(Self.successJSON))
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))
        // Consent gate CLOSED — the snapshot read is a no-LLM server lift and
        // must still run so the stale render branch stays honest.
        store.consentGate = { false }
        let asOf = Date(timeIntervalSince1970: 1_780_000_000)
        let stale = DashboardSnapshotBriefing(
            briefing: DailyBriefing(paragraph: "Gestern: BP 124/82 stabil."),
            briefingState: .preparing,
            briefingUpdatedAt: asOf,
            briefingStale: true
        )
        store.snapshotFetch = { stale }

        await store.load()

        #expect(store.response == nil, "generate stays consent-gated")
        #expect(store.briefing?.paragraph == "Gestern: BP 124/82 stabil.")
        #expect(store.staleBriefingAsOf == asOf)
        #expect(store.isServerBriefingUnavailable == false)
    }

    @Test("Fresh generate response masks the stale caption")
    @MainActor
    func freshResponseMasksStaleCaption() async {
        let (api, _) = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Self.wrap(Self.successJSON))
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))
        store.snapshotFetch = {
            DashboardSnapshotBriefing(
                briefing: DailyBriefing(paragraph: "Alter Stand."),
                briefingState: .preparing,
                briefingUpdatedAt: .distantPast,
                briefingStale: true
            )
        }

        await store.load()

        // The generate-path briefing wins; the "Stand HH:MM" caption must
        // never mislabel fresh prose as stale.
        #expect(store.briefing?.paragraph.contains("132/86") == true)
        #expect(store.staleBriefingAsOf == nil)
    }

    @Test("no-provider snapshot → deterministic fallback flag, no stale caption")
    @MainActor
    func noProviderSnapshotFlagsFallback() async {
        let (api, _) = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Self.wrap(Self.successJSON))
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))
        store.consentGate = { false }
        store.snapshotFetch = {
            DashboardSnapshotBriefing(briefingState: .noProvider)
        }

        await store.load()

        #expect(store.isServerBriefingUnavailable == true)
        #expect(store.briefing == nil)
        #expect(store.staleBriefingAsOf == nil)
        #expect(store.snapshotRenderPolicy == .deterministicFallback)
    }

    @Test("Snapshot fetch failure is best-effort — keeps last slot, no error")
    @MainActor
    func snapshotFetchFailureIsSilent() async {
        let (api, _) = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Self.wrap(Self.successJSON))
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))
        store.snapshotFetch = { throw HLError.offline }

        await store.load()

        #expect(store.snapshotBriefing == nil)
        // The generate path is untouched by the snapshot failure.
        #expect(store.summary != nil)
    }

    @Test("clearOnLogout also drops the snapshot slot")
    @MainActor
    func clearOnLogoutDropsSnapshot() async {
        let (api, _) = makeAPIClient()
        MockURLProtocol.handler = { request in
            (Self.ok(request), Self.wrap(Self.successJSON))
        }
        let store = DailyBriefingStore(repo: InsightsRepository(api: api))
        store.snapshotFetch = {
            DashboardSnapshotBriefing(briefingState: .ready)
        }
        await store.load()
        #expect(store.snapshotBriefing != nil)

        store.clearOnLogout()

        #expect(store.snapshotBriefing == nil)
    }

    // MARK: - Helpers

    @MainActor
    private func makeAPIClient() -> (APIClient, InMemoryKeychain) {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.4.0",
            buildNumber: "1"
        )
        let api = APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
        return (api, keychain)
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// Wraps the inner `insights`-envelope JSON as the `{ data: { ... } }`
    /// shape `APIClient.send` expects on success.
    private static func wrap(_ inner: String) -> Data {
        Data(#"{"data":\#(inner)}"#.utf8)
    }

    /// Wire-shape fixture mirroring `/api/insights/generate` envelope —
    /// `{ insights: AIInsightResponse, cached: Bool, legacyPayload: Bool }`.
    private static let successJSON = """
    {
        "insights": {
            "summary": "Heute eingestellt: Werte im Zielbereich.",
            "recommendations": [],
            "citations": [],
            "warnings": [],
            "dailyBriefing": {
                "paragraph": "Dein Blutdruck ist seit letzter Woche um 4 mmHg auf 132/86 gesunken.",
                "keyFindings": []
            },
            "provider": "anthropic"
        },
        "cached": false,
        "legacyPayload": false
    }
    """
}

private extension URLRequest {
    /// Reads either `httpBody` or `httpBodyStream` (URLSession converts POST
    /// bodies to streams for upload). Required because `APIClient` may attach
    /// the request body either way depending on the URL session config.
    func bodyBytes() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
