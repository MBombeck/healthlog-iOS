import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Shared fixtures for the CU-33 suites — one `APIClient` recipe, one
/// correlations payload carrying the new decision fields, and a body-stream
/// drain (`URLRequest.httpBody` is nil for stream-backed bodies).
enum CorrelationsDismissFixtures {
    static func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.12.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @MainActor
    static func makeStore(_ api: APIClient) -> CorrelationsDiscoveryStore {
        CorrelationsDiscoveryStore(
            repo: CorrelationsDiscoveryRepository(api: api),
            patterns: PatternsRepository(api: api)
        )
    }

    /// A correlations payload carrying the CU-33 decision fields.
    static func correlationsBody(moodDismissed: Bool, daylightDismissed: Bool = false) -> Data {
        Data("""
        {"data":{
          "discovered":[
            {"behaviour":"TIME_IN_DAYLIGHT","outcome":"SLEEP_DURATION","n":34,
             "r":0.41,"pValue":0.012,"qValue":0.06,
             "interpretation":"On days with more daylight, sleep the next day tended to be longer.",
             "lagDays":1,
             "behaviourLabel":"Zeit im Tageslicht","outcomeLabel":"Schlafdauer",
             "patternId":"clx1pattern0000aaaa","canonicalKey":"p1:aaaa1111",
             "dismissed":\(daylightDismissed)},
            {"behaviour":"MOOD","outcome":"HEART_RATE_VARIABILITY","n":28,
             "r":-0.33,"pValue":0.04,"qValue":0.09,
             "interpretation":"Lower mood days tended to precede lower HRV the next day.",
             "lagDays":1,
             "behaviourLabel":"Stimmung","outcomeLabel":"Herzfrequenzvariabilität",
             "patternId":"clx2pattern0000bbbb","canonicalKey":"p1:bbbb2222",
             "dismissed":\(moodDismissed)}
          ],
          "pairsTested":42,"fdrQ":0.1,"minPairs":20
        },"error":null}
        """.utf8)
    }

    static func ok(_ req: URLRequest, _ body: Data) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }

    static func consumeStream(_ stream: InputStream) -> Data? {
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
}

/// **CU-33** — the relevance statement on the correlation card, end to end:
/// the new `GET /api/insights/correlations` fields, the client-side suppression
/// the server deliberately does NOT do, the optimistic toggle with rollback,
/// and the calm handling of a pattern the server brings back on its own.
///
/// Real `APIClient` + `MockURLProtocol` throughout (never a mock server).
///
/// **Framing under test, not just plumbing.** These pairs are statistical
/// associations over one person's own behaviour and measurements. "Dismiss"
/// here means *"not relevant for me"* — a statement about relevance, never a
/// verdict that the pair is wrong and never a delete. The tests assert the
/// reversibility that framing implies, and that the copy stays non-causal.
@Suite("Korrelations-Verwerfen — Aussage statt Löschen, optimistisch mit Rollback (CU-33)", .serialized)
struct CorrelationsDismissTests {
    private func makeAPI() -> APIClient {
        CorrelationsDismissFixtures.makeAPI()
    }

    @MainActor
    private func makeStore(_ api: APIClient) -> CorrelationsDiscoveryStore {
        CorrelationsDismissFixtures.makeStore(api)
    }

    // MARK: - Decoding the new fields

    @Test("Fixture mit den neuen Feldern dekodiert (Labels, patternId, canonicalKey, dismissed)")
    func decodesNewCorrelationFields() async throws {
        let repo = CorrelationsDiscoveryRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            CorrelationsDismissFixtures.ok(req, CorrelationsDismissFixtures.correlationsBody(moodDismissed: true))
        }
        let dto = try #require(try await repo.fetch())

        let daylight = try #require(dto.discovered.first { $0.behaviour == "TIME_IN_DAYLIGHT" })
        #expect(daylight.behaviourLabel == "Zeit im Tageslicht")
        #expect(daylight.outcomeLabel == "Schlafdauer")
        #expect(daylight.patternId == "clx1pattern0000aaaa")
        #expect(daylight.canonicalKey == "p1:aaaa1111")
        #expect(daylight.dismissed == false)
        #expect(daylight.isDismissed == false)
        #expect(daylight.isDismissable)
        // Identity prefers the server's recomputation-stable canonical key.
        #expect(daylight.id == "p1:aaaa1111")

        let mood = try #require(dto.discovered.first { $0.behaviour == "MOOD" })
        #expect(mood.isDismissed)
    }

    @Test("Ältere Antwort ohne die neuen Felder dekodiert weiterhin (alle fünf optional)")
    func decodesLegacyPayloadWithoutNewFields() async throws {
        let repo = CorrelationsDiscoveryRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            CorrelationsDismissFixtures.ok(req, Data(#"""
            {"data":{"discovered":[
              {"behaviour":"STEPS","outcome":"MOOD","n":30,"r":0.3,"pValue":0.02,
               "qValue":0.07,"interpretation":"x","lagDays":1}
            ],"pairsTested":9,"fdrQ":0.1,"minPairs":20},"error":null}
            """#.utf8))
        }
        let dto = try #require(try await repo.fetch())
        let pair = try #require(dto.discovered.first)
        #expect(pair.behaviourLabel == nil)
        #expect(pair.outcomeLabel == nil)
        #expect(pair.patternId == nil)
        #expect(pair.canonicalKey == nil)
        #expect(pair.dismissed == nil)
        // Absent field → not dismissed. An older server never dismisses anything.
        #expect(pair.isDismissed == false)
        // No handle → no affordance; the app never invents a pattern id.
        #expect(pair.isDismissable == false)
        // Identity falls back to the locally-derived triple.
        #expect(pair.id == "STEPS→MOOD@1")
    }

    // MARK: - Client-side suppression (the server does not filter)

    @MainActor
    @Test("Store blendet verworfene Paare aus, hält sie aber erreichbar")
    func storeSuppressesButKeepsDismissedReachable() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            CorrelationsDismissFixtures.ok(req, CorrelationsDismissFixtures.correlationsBody(moodDismissed: true))
        }
        let store = makeStore(api)
        await store.load()

        // `/api/insights/correlations` returns dismissed pairs INLINE — the
        // suppression is the client's job on this route.
        #expect(store.response?.discovered.count == 2)
        #expect(store.presentable.map(\.behaviour) == ["TIME_IN_DAYLIGHT"])
        #expect(store.dismissedPairs.map(\.behaviour) == ["MOOD"])
        // Set aside, not gone — the block still has something to render.
        #expect(store.hasContent)
    }

    @MainActor
    @Test("Alle Paare verworfen → Block bleibt erreichbar (sonst wäre es unumkehrbar)")
    func allDismissedStillHasContent() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            CorrelationsDismissFixtures.ok(
                req,
                CorrelationsDismissFixtures.correlationsBody(moodDismissed: true, daylightDismissed: true)
            )
        }
        let store = makeStore(api)
        await store.load()
        #expect(store.presentable.isEmpty)
        #expect(store.dismissedPairs.count == 2)
        // If the block hid entirely here, the statement could never be taken
        // back — that would make a reversible action irreversible in practice.
        #expect(store.hasContent)
    }

    // MARK: - Rendering: server labels, non-causal copy

    @Test("Karte rendert die server-lokalisierten Labels statt selbst zu formulieren")
    func headlineRendersServerLabels() {
        let pair = DiscoveredCorrelation(
            behaviour: "CUSTOM_METRIC_42", outcome: "SLEEP_DURATION", n: 34,
            r: 0.41, pValue: 0.012, qValue: 0.06, interpretation: "", lagDays: 1,
            behaviourLabel: "Koffein nach 16 Uhr", outcomeLabel: "Schlafdauer"
        )
        #expect(InsightsCorrelationsDiscoveryBlock.behaviourLabel(for: pair) == "Koffein nach 16 Uhr")
        #expect(InsightsCorrelationsDiscoveryBlock.outcomeLabel(for: pair) == "Schlafdauer")
        let headline = InsightsCorrelationsDiscoveryBlock.headline(for: pair)
        // The server's own wording carries into the headline — the app does not
        // re-invent a name for a channel the server already named.
        #expect(headline.contains("Koffein nach 16 Uhr"))
        #expect(headline.contains("Schlafdauer"))
        // Still an association, never a cause.
        #expect(!headline.lowercased().contains("verbessert"))
        #expect(!headline.lowercased().contains("causes"))
        #expect(!headline.lowercased().contains("improves"))
    }

    @Test("Ohne Server-Label greift die kuratierte Tabelle, leeres Label zählt nicht")
    func fallsBackToCuratedLabel() {
        let none = DiscoveredCorrelation(
            behaviour: "TIME_IN_DAYLIGHT", outcome: "SLEEP_DURATION", n: 34,
            r: 0.41, pValue: 0.012, qValue: 0.06, interpretation: "", lagDays: 1
        )
        #expect(InsightsCorrelationsDiscoveryBlock.behaviourLabel(for: none)
            == InsightsCorrelationsDiscoveryBlock.label(for: "TIME_IN_DAYLIGHT"))

        let blank = DiscoveredCorrelation(
            behaviour: "TIME_IN_DAYLIGHT", outcome: "SLEEP_DURATION", n: 34,
            r: 0.41, pValue: 0.012, qValue: 0.06, interpretation: "", lagDays: 1,
            behaviourLabel: "   ", outcomeLabel: ""
        )
        // A blank server label must not render as a gap in the sentence.
        #expect(InsightsCorrelationsDiscoveryBlock.behaviourLabel(for: blank)
            == InsightsCorrelationsDiscoveryBlock.label(for: "TIME_IN_DAYLIGHT"))
        #expect(InsightsCorrelationsDiscoveryBlock.outcomeLabel(for: blank)
            == InsightsCorrelationsDiscoveryBlock.label(for: "SLEEP_DURATION"))
    }

    @Test("Verwerfen-Copy ist eine Relevanz-Aussage — kein Löschen, kein Urteil, kein Ratschlag")
    func relevanceCopyIsAStatementNotAVerdict() {
        let all = [
            InsightsCorrelationsDiscoveryBlock.dismissLabel,
            InsightsCorrelationsDiscoveryBlock.restoreLabel,
            InsightsCorrelationsDiscoveryBlock.dismissedNote,
            InsightsCorrelationsDiscoveryBlock.resurfacedNote,
            InsightsCorrelationsDiscoveryBlock.dismissedToggleLabel(count: 2)
        ]
        for text in all {
            #expect(!text.isEmpty)
            let lower = text.lowercased()
            // Not a delete, and not a verdict on the data.
            for forbidden in [
                "löschen", "delete", "entfernen", "remove", "falsch", "wrong",
                "ignorieren", "verbessert", "improves", "causes", "verursacht",
                "solltest", "should"
            ] {
                #expect(!lower.contains(forbidden), "‘\(forbidden)’ in: \(text)")
            }
        }
        // The restore path exists at all — a statement you cannot take back is
        // not a statement, it is a deletion.
        #expect(InsightsCorrelationsDiscoveryBlock.restoreLabel
            != InsightsCorrelationsDiscoveryBlock.dismissLabel)
    }
}

/// **CU-33 (write path)** — the relevance statement going to the server:
/// optimistic application, rollback on failure, reversal, and the calm handling
/// of a pattern the SERVER brings back on its own after a recomputation.
@Suite("Korrelations-Verwerfen — Schreibpfad, Rollback und Wiederkehr (CU-33)", .serialized)
struct CorrelationsDismissWriteTests {
    private func makeAPI() -> APIClient {
        CorrelationsDismissFixtures.makeAPI()
    }

    @MainActor
    private func makeStore(_ api: APIClient) -> CorrelationsDiscoveryStore {
        CorrelationsDismissFixtures.makeStore(api)
    }

    // MARK: - Optimistic write + rollback

    @MainActor
    @Test("Verwerfen — optimistisch sofort, PATCH-Body geprüft, Server-Wahrheit gewinnt")
    func dismissAppliesOptimisticallyAndConfirms() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var patchPath: String?
        nonisolated(unsafe) var patchBody: Data?
        MockURLProtocol.handler = { req in
            guard req.httpMethod == "PATCH" else {
                return CorrelationsDismissFixtures.ok(
                    req,
                    CorrelationsDismissFixtures.correlationsBody(moodDismissed: false)
                )
            }
            patchPath = req.url?.path
            patchBody = req.httpBody ?? req.httpBodyStream.flatMap(CorrelationsDismissFixtures.consumeStream(_:))
            return CorrelationsDismissFixtures.ok(req, Data(#"""
            {"data":{"id":"clx2pattern0000bbbb","canonicalKey":"p1:bbbb2222","dismissed":true,
             "dismissedAt":"2026-07-30T09:00:00.000Z","evidenceHash":"1c7d"},"error":null}
            """#.utf8))
        }
        let store = makeStore(api)
        await store.load()
        let mood = try #require(store.presentable.first { $0.behaviour == "MOOD" })

        await store.setDismissed(true, for: mood)

        #expect(patchPath == "/api/insights/patterns/clx2pattern0000bbbb")
        let raw = try #require(patchBody)
        let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(json["dismissed"] as? Bool == true)
        #expect(json.count == 1)

        #expect(store.presentable.map(\.behaviour) == ["TIME_IN_DAYLIGHT"])
        #expect(store.dismissedPairs.map(\.behaviour) == ["MOOD"])
        #expect(store.actionError == nil)
        #expect(store.pendingIDs.isEmpty)
    }

    @MainActor
    @Test("Fehlschlag — das optimistische Update rollt zurück statt eine Lüge stehenzulassen")
    func failedDismissRollsBack() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            guard req.httpMethod == "PATCH" else {
                return CorrelationsDismissFixtures.ok(
                    req,
                    CorrelationsDismissFixtures.correlationsBody(moodDismissed: false)
                )
            }
            let body = Data(#"{"data":null,"error":"boom"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, body)
        }
        let store = makeStore(api)
        await store.load()
        let mood = try #require(store.presentable.first { $0.behaviour == "MOOD" })

        await store.setDismissed(true, for: mood)

        // The pair is BACK in the visible list — the write did not happen, so
        // the surface must not claim it did.
        #expect(store.presentable.map(\.behaviour).sorted() == ["MOOD", "TIME_IN_DAYLIGHT"])
        #expect(store.dismissedPairs.isEmpty)
        // …and the person is told, rather than left with a silent no-op.
        #expect(store.actionError != nil)
        #expect(store.pendingIDs.isEmpty)
    }

    @MainActor
    @Test("Zurückgezogenes Muster (404) — Rollback plus eigene, ehrliche Meldung")
    func withdrawnPatternRollsBackWithOwnMessage() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            guard req.httpMethod == "PATCH" else {
                return CorrelationsDismissFixtures.ok(
                    req,
                    CorrelationsDismissFixtures.correlationsBody(moodDismissed: false)
                )
            }
            let body = Data(#"{"data":null,"error":"Correlation pattern not found"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, body)
        }
        let store = makeStore(api)
        await store.load()
        let mood = try #require(store.presentable.first { $0.behaviour == "MOOD" })

        await store.setDismissed(true, for: mood)
        #expect(store.dismissedPairs.isEmpty)
        let message = try #require(store.actionError)
        #expect(!message.isEmpty)
    }

    @MainActor
    @Test("Zurücknehmen — dieselbe Bedienung schickt dismissed:false und zeigt das Paar wieder")
    func restoreIsReversible() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var patchBody: Data?
        MockURLProtocol.handler = { req in
            guard req.httpMethod == "PATCH" else {
                return CorrelationsDismissFixtures.ok(
                    req,
                    CorrelationsDismissFixtures.correlationsBody(moodDismissed: true)
                )
            }
            patchBody = req.httpBody ?? req.httpBodyStream.flatMap(CorrelationsDismissFixtures.consumeStream(_:))
            return CorrelationsDismissFixtures.ok(req, Data(#"""
            {"data":{"id":"clx2pattern0000bbbb","canonicalKey":"p1:bbbb2222","dismissed":false,
             "dismissedAt":null,"evidenceHash":"1c7d"},"error":null}
            """#.utf8))
        }
        let store = makeStore(api)
        await store.load()
        let mood = try #require(store.dismissedPairs.first { $0.behaviour == "MOOD" })

        await store.setDismissed(false, for: mood)

        let raw = try #require(patchBody)
        let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(json["dismissed"] as? Bool == false)
        #expect(store.presentable.map(\.behaviour).sorted() == ["MOOD", "TIME_IN_DAYLIGHT"])
        #expect(store.dismissedPairs.isEmpty)
    }

    @MainActor
    @Test("Server-Wahrheit gewinnt über das Gesendete (Antwort dismissed:false trotz true-Request)")
    func serverSettledStateWins() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            guard req.httpMethod == "PATCH" else {
                return CorrelationsDismissFixtures.ok(
                    req,
                    CorrelationsDismissFixtures.correlationsBody(moodDismissed: false)
                )
            }
            // The server answers with the state it actually settled on.
            return CorrelationsDismissFixtures.ok(req, Data(#"""
            {"data":{"id":"clx2pattern0000bbbb","canonicalKey":"p1:bbbb2222","dismissed":false,
             "dismissedAt":null,"evidenceHash":"1c7d"},"error":null}
            """#.utf8))
        }
        let store = makeStore(api)
        await store.load()
        let mood = try #require(store.presentable.first { $0.behaviour == "MOOD" })

        await store.setDismissed(true, for: mood)
        // Reconciled against the response, not against the request.
        #expect(store.dismissedPairs.isEmpty)
        #expect(store.presentable.count == 2)
    }

    @MainActor
    @Test("Ohne patternId wird die Zeile über das Ledger-Tripel aufgelöst")
    func resolvesPatternIdFromLedgerWhenAbsent() async throws {
        let api = makeAPI()
        nonisolated(unsafe) var patchPath: String?
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if req.httpMethod == "PATCH" {
                patchPath = path
                return CorrelationsDismissFixtures.ok(req, Data(#"""
                {"data":{"id":"ledgerRow1","canonicalKey":"p1:eeee","dismissed":true,
                 "dismissedAt":"2026-07-30T09:00:00.000Z","evidenceHash":"ee"},"error":null}
                """#.utf8))
            }
            if path.hasSuffix("/insights/patterns") {
                return CorrelationsDismissFixtures.ok(req, Data(#"""
                {"data":{"patterns":[
                  {"id":"ledgerRow1","canonicalKey":"p1:eeee","family":"DISCOVERY_RETROSPECTIVE",
                   "factorKey":"STEPS","outcomeKey":"MOOD","lagDays":1,
                   "sampleSize":30,"effectSize":0.3,"pValue":0.02,"qValue":0.07,
                   "evidenceHash":"ee","lastComputedAt":"2026-07-30T03:15:00.000Z","dismissedAt":null}
                ]},"error":null}
                """#.utf8))
            }
            // Correlations payload WITHOUT the decision fields (older server /
            // decision not attached).
            return CorrelationsDismissFixtures.ok(req, Data(#"""
            {"data":{"discovered":[
              {"behaviour":"STEPS","outcome":"MOOD","n":30,"r":0.3,"pValue":0.02,
               "qValue":0.07,"interpretation":"x","lagDays":1}
            ],"pairsTested":9,"fdrQ":0.1,"minPairs":20},"error":null}
            """#.utf8))
        }
        let store = makeStore(api)
        await store.load()
        let pair = try #require(store.presentable.first)
        #expect(pair.patternId == nil)

        await store.setDismissed(true, for: pair)

        // Recovered by the `(factor, outcome, lag)` identity triple — the same
        // triple the server's canonical key is derived from.
        #expect(patchPath == "/api/insights/patterns/ledgerRow1")
        #expect(store.dismissedPairs.count == 1)
    }

    // MARK: - The server can bring a dismissed pattern back

    @MainActor
    @Test("Neuberechnung holt ein verworfenes Muster zurück → ruhig markiert, kein Fehler")
    func resurfacedPatternIsMarkedCalmly() async throws {
        let api = makeAPI()
        // The GET always answers `dismissed: false` — it is the recomputation
        // itself, and it has decided the evidence moved materially enough to
        // lift the dismissal it stored a moment ago.
        MockURLProtocol.handler = { req in
            if req.httpMethod == "PATCH" {
                return CorrelationsDismissFixtures.ok(req, Data(#"""
                {"data":{"id":"clx2pattern0000bbbb","canonicalKey":"p1:bbbb2222","dismissed":true,
                 "dismissedAt":"2026-07-30T09:00:00.000Z","evidenceHash":"1c7d"},"error":null}
                """#.utf8))
            }
            return CorrelationsDismissFixtures.ok(
                req,
                CorrelationsDismissFixtures.correlationsBody(moodDismissed: false)
            )
        }
        let store = makeStore(api)
        await store.load()
        let mood = try #require(store.presentable.first { $0.behaviour == "MOOD" })
        await store.setDismissed(true, for: mood)
        #expect(store.dismissedPairs.map(\.behaviour) == ["MOOD"])

        // The next recomputation finds a materially changed evidence base
        // (sign flip / |Δeffect| ≥ 0.10 / sample growth ≥ max(10, 25 %)),
        // clears `dismissedAt` server-side, and the pair returns unflagged.
        await store.refresh()

        #expect(store.presentable.map(\.behaviour).sorted() == ["MOOD", "TIME_IN_DAYLIGHT"])
        #expect(store.dismissedPairs.isEmpty)
        // Recognised as a server-initiated return so the card can say why it is
        // back — never surfaced as an error or a lost setting.
        #expect(store.resurfacedIDs.contains("p1:bbbb2222"))
        #expect(store.actionError == nil)
    }

    @MainActor
    @Test("Nie verworfenes Paar wird nie als 'zurückgekehrt' markiert")
    func neverDismissedIsNeverResurfaced() async {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            CorrelationsDismissFixtures.ok(req, CorrelationsDismissFixtures.correlationsBody(moodDismissed: false))
        }
        let store = makeStore(api)
        await store.load()
        await store.refresh()
        #expect(store.resurfacedIDs.isEmpty)
    }

    @MainActor
    @Test("Logout räumt Antwort, Sitzungsgedächtnis und Fehlermeldung ab")
    func logoutClearsEverything() async throws {
        let api = makeAPI()
        MockURLProtocol.handler = { req in
            if req.httpMethod == "PATCH" {
                return CorrelationsDismissFixtures.ok(req, Data(#"""
                {"data":{"id":"clx2pattern0000bbbb","canonicalKey":"p1:bbbb2222","dismissed":true,
                 "dismissedAt":"2026-07-30T09:00:00.000Z","evidenceHash":"1c7d"},"error":null}
                """#.utf8))
            }
            return CorrelationsDismissFixtures.ok(
                req,
                CorrelationsDismissFixtures.correlationsBody(moodDismissed: false)
            )
        }
        let store = makeStore(api)
        await store.load()
        let mood = try #require(store.presentable.first { $0.behaviour == "MOOD" })
        await store.setDismissed(true, for: mood)

        store.clearOnLogout()
        #expect(store.response == nil)
        #expect(store.presentable.isEmpty)
        #expect(store.dismissedPairs.isEmpty)
        #expect(store.resurfacedIDs.isEmpty)
        #expect(store.actionError == nil)
        #expect(store.hasContent == false)
    }
}

// swiftlint:enable force_unwrapping
