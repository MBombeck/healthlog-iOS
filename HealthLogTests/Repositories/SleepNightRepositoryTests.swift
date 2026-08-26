import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.14.3 E1 — locks the `SleepNightRepository.night(for:)` contract behind the
/// hypnogram detail (#124):
///
/// - the DEFAULT entry passes NO `date` query (the server returns its most-recent
///   night) — the old `latestPoint.at` device-tz day-key missed the server's
///   wake-day/server-tz night key → empty/422 → "konnte nicht geladen werden".
/// - a concrete `date` still sends the `?date=YYYY-MM-DD` query.
/// - a `404`/`422` maps to an EMPTY night (`main == nil`), the calm empty state,
///   never a thrown error (mirrors `NarrativeRepository.fetch`).
@Suite("SleepNightRepository — default-no-date + 422→empty", .serialized)
struct SleepNightRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.3",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private static let nightBody = Data(#"""
    {"data":{
      "main":{
        "night":"2026-06-04","source":"APPLE_HEALTH",
        "start":"2026-06-03T22:10:00Z","end":"2026-06-04T06:30:00Z",
        "asleepMinutes":432,"inBedMinutes":500,"awakeMinutes":24,"awakenings":3,
        "stages":{"CORE":432},
        "segments":[{"stage":"CORE","start":"2026-06-03T22:18:00Z","end":"2026-06-04T06:30:00Z","minutes":432}]
      },
      "naps":[]
    },"error":null}
    """#.utf8)

    @Test("night(for: nil) — default omits the date query + returns the latest night")
    func defaultOmitsDateQuery() async throws {
        let repo = SleepNightRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            // The DEFAULT entry must NOT carry a `date=` query — the server picks
            // the most-recent night, sidestepping the device-tz day-key mismatch.
            // CU-07: assert only on OUR route — the handler is process-global.
            if req.targets("/api/sleep/night") {
                #expect(req.url?.query?.contains("date=") != true)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.nightBody)
        }
        let dto = try await repo.night(for: nil)
        #expect(dto.main != nil)
        #expect(dto.main?.asleepMinutes == 432)
    }

    @Test("night(for: date) — a concrete date still sends ?date=YYYY-MM-DD")
    func concreteDateSendsQuery() async throws {
        let repo = SleepNightRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            if req.targets("/api/sleep/night") {
                #expect(req.url?.query?.contains("date=") == true)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.nightBody)
        }
        // Any concrete date — the assertion is that SOME date query is sent.
        let dto = try await repo.night(for: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(dto.main != nil)
    }

    @Test("night — 422 (day-key rejected) → empty night, NOT a thrown error")
    func unprocessableMapsToEmpty() async throws {
        let repo = SleepNightRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
        }
        // No throw — the screen renders its calm empty state on `main == nil`.
        let dto = try await repo.night(for: nil)
        #expect(dto.main == nil)
        #expect(dto.naps.isEmpty)
    }

    @Test("night — LIVE wire shape (fractional minutes, top-level night key) decodes")
    func liveFractionalBodyDecodes() async throws {
        // W-SLEEP (v0.14.8) — shape captured from the live route: a top-level
        // `night` day-key sibling next to `main`/`naps`, and UNROUNDED float
        // minute sums (only `segments[].minutes` is rounded server-side).
        // This body used to throw `HLError.decoding` (`Int` fields) → the
        // screen showed the error card on essentially every real night.
        let body = Data(#"""
        {"data":{
          "night":"2026-06-10",
          "main":{
            "night":"2026-06-10","source":"APPLE_HEALTH",
            "start":"2026-06-09T22:10:30Z","end":"2026-06-10T06:30:15Z",
            "asleepMinutes":433.49999999999994,"inBedMinutes":499.75,"awakeMinutes":24.25,"awakenings":2,
            "stages":{"REM":90.5,"CORE":282.99999999999994,"DEEP":60.0,"AWAKE":24.25},
            "segments":[
              {"stage":"REM","start":"2026-06-09T22:10:30Z","end":"2026-06-09T23:41:00Z","minutes":91},
              {"stage":"CORE","start":"2026-06-09T23:41:00Z","end":"2026-06-10T04:24:00Z","minutes":283}
            ]
          },
          "naps":[]
        },"error":null}
        """#.utf8)
        let repo = SleepNightRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try await repo.night(for: nil)
        let main = try #require(dto.main)
        #expect(main.asleepMinutes == 433)
        #expect(main.stages[.core] == 283)
        #expect(main.segments.count == 2)
    }

    @Test("night — 404 (route absent) → empty night, NOT a thrown error")
    func notFoundMapsToEmpty() async throws {
        let repo = SleepNightRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let dto = try await repo.night(for: nil)
        #expect(dto.main == nil)
    }

    // MARK: - W-B180 — SWR cache per day-key (night navigation)

    @Test("W-B180 — latest night lands in the cache under nil AND its resolved day-key")
    func latestNightCachesUnderResolvedDayKey() async throws {
        let repo = SleepNightRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.nightBody)
        }
        #expect(await repo.cachedNight(forDayKey: nil) == nil)
        _ = try await repo.night(forDayKey: nil)
        // Latest entry + the fixture's wake-day key ("2026-06-04") both hit.
        #expect(await repo.cachedNight(forDayKey: nil)?.main?.asleepMinutes == 432)
        #expect(await repo.cachedNight(forDayKey: "2026-06-04")?.main?.asleepMinutes == 432)
        // Unrelated keys stay cold.
        #expect(await repo.cachedNight(forDayKey: "2026-06-03") == nil)
    }

    @Test("W-B180 — night(forDayKey:) sends the raw key + REVALIDATES on every call")
    func dayKeyFetchSendsQueryAndRevalidates() async throws {
        let repo = SleepNightRepository(api: makeAPI())
        nonisolated(unsafe) var requestCount = 0
        MockURLProtocol.handler = { req in
            if req.targets("/api/sleep/night") {
                requestCount += 1
                #expect(req.url?.query?.contains("date=2026-06-04") == true)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.nightBody)
        }
        _ = try await repo.night(forDayKey: "2026-06-04")
        // SWR: the cache never swallows the network — the second call still
        // hits the server (the screen paints the cached copy meanwhile).
        _ = try await repo.night(forDayKey: "2026-06-04")
        #expect(requestCount == 2)
        #expect(await repo.cachedNight(forDayKey: "2026-06-04") != nil)
    }

    @Test("W-B180 — UTC day-key round-trip (navigation day arithmetic)")
    func utcDayKeyRoundTrip() throws {
        let anchor = try #require(SleepNightRepository.date(fromDayKey: "2026-06-04"))
        #expect(SleepNightRepository.utcDayKey(for: anchor) == "2026-06-04")
        // Midnight UTC stays on its wake day regardless of device tz offset.
        #expect(anchor == Date(timeIntervalSince1970: 1_780_531_200))
    }
}

// swiftlint:enable force_unwrapping
