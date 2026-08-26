import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// I-3 ITEM 5 — locks the wire contract for
/// `GET /api/insights/narrative?period=week|month` (server v1.11.0 W3,
/// `src/app/api/insights/narrative/route.ts`) + the ``NarrativeStore``
/// display-only / per-period / empty-state semantics.
///
/// Covers:
/// - full envelope decode (narrative text verbatim + provenance + updatedAt)
/// - `narrative: null` (provider-less / fresh account) decodes → calm empty
/// - 404/422 → nil (route absent / unknown period) → card hidden, never error
/// - store: per-period lazy load, settled-vs-empty distinction, double-optional
///   flattening in `narrative(for:)`
@Suite("Narrative — wire contract + retrospective store semantics", .serialized)
struct NarrativeRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @Test("fetch — decodes the narrative envelope; tolerates the OBJECT-shaped provenance")
    func fetchFullEnvelope() async throws {
        // v0.14.7 A2 regression lock: the server's `provenance` is a STRUCTURED
        // OBJECT (`{metrics, window, pairsTested, fdrQ, computedAt}`), not the
        // `String` an earlier DTO draft assumed. Decoding it as `String?` threw
        // `DecodingError` the moment a real narrative row existed → the recurring
        // "Rückblick konnte nicht geladen werden" error. iOS doesn't model
        // provenance anymore (Codable ignores the unknown key), so the REAL
        // object payload must decode cleanly with the text + updatedAt intact.
        let repo = NarrativeRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "period":"week",
              "locale":"de",
              "narrative":{
                "text":"Diese Woche lag dein Blutdruck etwas niedriger als in der Vorwoche.",
                "provenance":{
                  "metrics":["bloodPressureSystolic","bloodPressureDiastolic"],
                  "window":"week",
                  "pairsTested":12,
                  "fdrQ":0.1,
                  "computedAt":"2026-06-03T06:00:00Z"
                },
                "updatedAt":"2026-06-03T06:00:00Z"
              },
              "revalidating":false
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(period: .week, locale: "de"))
        #expect(dto.period == "week")
        #expect(dto.narrative?.text.contains("Blutdruck") == true)
        #expect(dto.narrative?.updatedAt != nil)
        #expect(dto.revalidating == false)
    }

    @Test("fetch — narrative:null (fresh / provider-less) decodes to empty arm")
    func fetchNullNarrative() async throws {
        let repo = NarrativeRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"period":"month","locale":"en","narrative":null,"revalidating":true},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(period: .month, locale: "en"))
        #expect(dto.narrative == nil)
        #expect(dto.revalidating == true)
    }

    @Test("fetch — 404 (route not deployed) → nil → card hidden, no error")
    func fetch404IsNil() async throws {
        let repo = NarrativeRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetch(period: .week, locale: "de") == nil)
    }

    @Test("fetch — 422 (unknown period rejected) → nil (never an error)")
    func fetch422IsNil() async throws {
        let repo = NarrativeRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetch(period: .month, locale: "en") == nil)
    }

    @Test("v0.14.3 B5 — 403 assistant.disabled (provider-less) → nil (calm empty, not error)")
    func fetch403AssistantDisabledIsNil() async throws {
        // The route calls `requireAssistantSurface("insightStatus")`; a
        // provider-less / operator-gated account throws 403 with errorCode
        // `assistant.disabled.insights`, which the APIClient surfaces as
        // `HLError.assistantDisabled`. The repo must map that to nil so the
        // "Zeitraum im Rückblick" card shows the calm empty state, not its error
        // arm (the b150 bug: provider-less ⇒ broken-looking tile).
        let repo = NarrativeRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":"Assistant disabled","errorCode":"assistant.disabled.insights"}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        #expect(try await repo.fetch(period: .week, locale: "de") == nil)
    }

    @Test("v0.14.3 B5 — a plain 403 (no assistant errorCode) → nil too")
    func fetchPlain403IsNil() async throws {
        // Defensive: even a 403 that does NOT carry the typed assistant-disabled
        // errorCode (so it surfaces as `.server(403,…)`) maps to the empty state.
        let repo = NarrativeRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetch(period: .month, locale: "en") == nil)
    }

    @MainActor
    @Test("store — load surfaces narrative; settled-but-empty distinct from loading")
    func storeLoadAndSettle() async {
        let repo = NarrativeRepository(api: makeAPI())
        let store = NarrativeStore(repo: repo)
        // Before any load: not settled, no narrative.
        #expect(!store.hasSettled(.week))
        #expect(store.narrative(for: .week) == nil)

        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"period":"week","locale":"de",
             "narrative":{"text":"Kurzer Rückblick.","provenance":null,"updatedAt":null},
             "revalidating":false},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load(period: .week, locale: "de")
        #expect(store.hasSettled(.week))
        #expect(store.narrative(for: .week)?.text == "Kurzer Rückblick.")
        // Month was never loaded → still not settled.
        #expect(!store.hasSettled(.month))
    }

    @MainActor
    @Test("store — narrative:null settles the period but yields no narrative (calm empty)")
    func storeEmptyArm() async {
        let repo = NarrativeRepository(api: makeAPI())
        let store = NarrativeStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"period":"month","locale":"de","narrative":null,"revalidating":false},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load(period: .month, locale: "de")
        // Settled (so the view shows the empty state, not a spinner-forever) but
        // no narrative text — the double-optional flattening returns nil.
        #expect(store.hasSettled(.month))
        #expect(store.narrative(for: .month) == nil)
        #expect(!store.isLoading(.month))
    }

    @MainActor
    @Test("v0.14.3 B5 — revalidating+narrative:null does NOT settle (re-polls in-session)")
    func storeRevalidatingDoesNotSettle() async {
        // When a provider IS configured but the row is missing/stale, the route
        // returns `narrative:null, revalidating:true` and warms out-of-band.
        // The store must NOT settle that empty (which would freeze the empty
        // state until the next Berlin-day) — it leaves the period unsettled so
        // the card re-polls in the SAME session once the warm completes.
        let repo = NarrativeRepository(api: makeAPI())
        let store = NarrativeStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"period":"week","locale":"de","narrative":null,"revalidating":true},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load(period: .week, locale: "de")
        // Warm in flight → NOT settled (so the card keeps polling), no error.
        #expect(!store.hasSettled(.week))
        #expect(store.narrative(for: .week) == nil)
        #expect(!store.hasErrored(.week))
    }

    @MainActor
    @Test("v0.14.3 B5 — a settled non-empty narrative still wins after a warm completes")
    func storeRevalidatingThenResolved() async {
        // Once the warm produces a real narrative (revalidating:false or a text
        // body), the store settles normally and surfaces the text.
        let repo = NarrativeRepository(api: makeAPI())
        let store = NarrativeStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"period":"week","locale":"de",
             "narrative":{"text":"Warmer Rückblick.","provenance":null,"updatedAt":null},
             "revalidating":true},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load(period: .week, locale: "de")
        // narrative present (even with revalidating:true) → settles + surfaces.
        #expect(store.hasSettled(.week))
        #expect(store.narrative(for: .week)?.text == "Warmer Rückblick.")
    }

    @MainActor
    @Test("store — clearOnLogout wipes the per-period cache")
    func storeClearOnLogout() async {
        let repo = NarrativeRepository(api: makeAPI())
        let store = NarrativeStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(
                #"{"data":{"period":"week","locale":"de","narrative":{"text":"x","provenance":null,"updatedAt":null},"revalidating":false},"error":null}"#
                    .utf8
            )
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load(period: .week, locale: "de")
        #expect(store.hasSettled(.week))
        store.clearOnLogout()
        #expect(!store.hasSettled(.week))
        #expect(store.narrative(for: .week) == nil)
    }
}

// swiftlint:enable force_unwrapping
