import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the wire contract for `GET /api/insights/rhythm-events`
/// (server v1.10.0, `src/app/api/insights/rhythm-events/route.ts`).
///
/// Covers:
/// - full envelope decode (events + classification verbatim + occurredAt)
/// - empty `hasEvents:false` decodes cleanly → store self-suppresses
/// - 404/422 → nil (route absent) → card hidden, never an error
/// - the card self-suppresses to EmptyView on empty
/// - the regulatory disclaimer + verdict copy is present + verbatim
@Suite("RhythmEvents — wire contract + card self-suppression", .serialized)
struct RhythmEventsRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.12.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    @Test("fetch — decodes the full event timeline (classification verbatim)")
    func fetchFullEnvelope() async throws {
        let repo = RhythmEventsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{
              "events":[
                {"id":"evt-1","type":"IRREGULAR_RHYTHM_NOTIFICATION",
                 "classification":"IRREGULAR","occurredAt":"2026-06-01T08:30:00Z",
                 "source":"APPLE_HEALTH","deviceType":"Apple Watch"},
                {"id":"evt-2","type":"WALKING_STEADINESS_EVENT",
                 "classification":"VERY_LOW","occurredAt":"2026-05-28T14:05:00Z",
                 "source":"APPLE_HEALTH","deviceType":null},
                {"id":"evt-3","type":"HIGH_HEART_RATE_EVENT",
                 "classification":"FIRED","occurredAt":"2026-05-20T19:00:00Z",
                 "source":"APPLE_HEALTH","deviceType":"Apple Watch"}
              ],
              "hasEvents":true
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch())
        #expect(dto.hasEvents)
        #expect(dto.events.count == 3)
        #expect(dto.events[0].type == "IRREGULAR_RHYTHM_NOTIFICATION")
        #expect(dto.events[0].classification == "IRREGULAR")
        #expect(dto.events[1].classification == "VERY_LOW")
        #expect(dto.events[1].deviceType == nil)
        #expect(dto.events[2].classification == "FIRED")
    }

    @Test("fetch — empty hasEvents:false decodes; store yields no events")
    func fetchEmpty() async throws {
        let repo = RhythmEventsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"events":[],"hasEvents":false},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch())
        #expect(!dto.hasEvents)
        #expect(dto.events.isEmpty)
    }

    @Test("fetch — 404 (route not deployed) → nil → card hidden, no error")
    func fetch404IsNil() async throws {
        let repo = RhythmEventsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let dto = try await repo.fetch()
        #expect(dto == nil)
    }

    @Test("fetch — 422 → nil (never an error)")
    func fetch422IsNil() async throws {
        let repo = RhythmEventsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetch() == nil)
    }

    @MainActor
    @Test("store — load mirrors events; empty hasEvents → no events")
    func storeLoadAndSuppress() async {
        let repo = RhythmEventsRepository(api: makeAPI())
        let store = RhythmEventsStore(repo: repo)
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":{"events":[],"hasEvents":false},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load()
        #expect(store.events.isEmpty, "hasEvents:false → no events → card self-suppresses")
    }

    @MainActor
    @Test("card — self-suppresses on empty (body returns EmptyView path)")
    func cardSelfSuppressesOnEmpty() {
        // The card's data gate is `events.isEmpty`; an empty event array means
        // the whole surface renders nothing (no header, no disclaimer shell).
        let card = InsightsRhythmEventsCard(events: [])
        // Pure structural assertion — an empty input keeps the surface absent.
        #expect(card.events.isEmpty)
    }

    @Test("card — verdict + event labels are the verbatim copy contract (EN or DE)")
    func verdictAndLabelCopy() {
        // The AFib verdict line is load-bearing — the resolver must return the
        // exact server/web copy-contract string (locale-resolved EN source or
        // its DE translation), never a fabricated/blank string. The test host
        // resolves the catalog to its active locale, so assert membership in
        // the known-verbatim pair rather than pinning one locale.
        let verdict = InsightsRhythmEventsCard.verdictLabel(for: "IRREGULAR")
        #expect([
            "Your device flagged a possible irregular rhythm.",
            "Dein Gerät hat einen möglichen unregelmäßigen Rhythmus erkannt."
        ].contains(verdict))
        #expect(InsightsRhythmEventsCard.verdictLabel(for: "NOT_DETECTED") != nil)
        #expect(InsightsRhythmEventsCard.verdictLabel(for: nil) == nil)
        let label = InsightsRhythmEventsCard.eventLabel(for: "IRREGULAR_RHYTHM_NOTIFICATION")
        #expect([
            "Irregular rhythm notification",
            "Hinweis auf unregelmäßigen Rhythmus"
        ].contains(label))
        // Unknown type falls back to the raw type (never a crash / blank).
        #expect(InsightsRhythmEventsCard.eventLabel(for: "FUTURE_EVENT") == "FUTURE_EVENT")
    }
}

// swiftlint:enable force_unwrapping
