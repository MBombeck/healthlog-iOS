import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the wire contract for `GET /api/insights/pulse/intraday`
/// (server `src/app/api/insights/pulse/intraday/route.ts`, payload
/// `IntradayPulseResult` in `src/lib/analytics/intraday-pulse-io.ts:53-70`).
///
/// Covers:
/// - full envelope decode against the REAL server shape (incl. a bucket with
///   no `min`/`max` spread and `tension: null`)
/// - a non-null `tension` window decodes with its typed accessors
/// - `resolution: "hourly"` + `bucketMinutes: 60` (the older-day fallback)
/// - `403` (module `insights` off) / `404` (route absent) / `422` → `nil`, so
///   the block hides — never an error, never a fabricated day
/// - the `?date=` query wiring (present for a past day, absent for today)
/// - the past-day memo (second read never hits the network; today always does)
///
/// `.serialized` because every case installs its own `MockURLProtocol.handler`
/// and some assert on the request URL the handler saw.
@Suite("IntradayPulse — wire contract + gating", .serialized)
struct IntradayPulseRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    /// The operator's live MCP ground truth (2026-07-24), trimmed to four
    /// buckets: a contiguous pair, a gap, then a spread-less bucket.
    private let groundTruth = #"""
    {"data":{
      "dateKey":"2026-07-24",
      "timezone":"Europe/Berlin",
      "bucketMinutes":10,
      "series":[
        {"startMinute":540,"mean":87,"count":2,"min":85,"max":89},
        {"startMinute":550,"mean":82,"count":4,"min":78,"max":90},
        {"startMinute":720,"mean":91,"count":3,"min":88,"max":95},
        {"startMinute":730,"mean":76,"count":1}
      ],
      "baseline":76,
      "baselineSource":"resting",
      "tension":null,
      "resolution":"tenMin"
    },"error":null}
    """#

    @Test("fetch — decodes the real server shape (buckets, baseline, no tension)")
    func fetchFullEnvelope() async throws {
        let repo = IntradayPulseRepository(api: makeAPI())
        let body = Data(groundTruth.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(dateKey: nil, todayKey: "2026-07-24"))
        #expect(dto.dateKey == "2026-07-24")
        #expect(dto.timezone == "Europe/Berlin")
        #expect(dto.bucketMinutes == 10)
        #expect(dto.series.count == 4)
        #expect(dto.series[0].startMinute == 540)
        #expect(dto.series[0].mean == 87)
        #expect(dto.series[0].count == 2)
        #expect(dto.series[0].min == 85)
        // A source without a spread simply omits min/max — it must decode, not throw.
        #expect(dto.series[3].min == nil)
        #expect(dto.series[3].max == nil)
        #expect(dto.baseline == 76)
        #expect(dto.source == .resting)
        #expect(dto.drawableBaseline == 76)
        #expect(dto.tension == nil)
        #expect(dto.grain == .tenMin)
        #expect(dto.hasContent)
    }

    @Test("fetch — a non-null tension window decodes with its typed accessors")
    func fetchWithTension() async throws {
        let repo = IntradayPulseRepository(api: makeAPI())
        let body = Data(#"""
        {"data":{
          "dateKey":"2026-07-23","timezone":"Europe/Berlin","bucketMinutes":10,
          "series":[{"startMinute":1200,"mean":94,"count":5}],
          "baseline":72,"baselineSource":"proxy",
          "tension":{"startMinute":1200,"endMinute":1240,"partOfDay":"evening",
                     "meanHr":94,"baseline":72,"hrvConfirmed":true},
          "resolution":"tenMin"
        },"error":null}
        """#.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(dateKey: "2026-07-23", todayKey: "2026-07-24"))
        let tension = try #require(dto.tension)
        #expect(tension.startMinute == 1200)
        #expect(tension.endMinute == 1240)
        #expect(tension.part == .evening)
        #expect(tension.hrvConfirmed)
        #expect(dto.source == .proxy)
    }

    @Test("fetch — resolution:hourly + bucketMinutes:60 (older-day fallback)")
    func fetchHourly() async throws {
        let repo = IntradayPulseRepository(api: makeAPI())
        let body = Data(#"""
        {"data":{
          "dateKey":"2026-01-02","timezone":"Europe/Berlin","bucketMinutes":60,
          "series":[{"startMinute":480,"mean":70,"count":42}],
          "baseline":null,"baselineSource":"none","tension":null,"resolution":"hourly"
        },"error":null}
        """#.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(dateKey: "2026-01-02", todayKey: "2026-07-24"))
        #expect(dto.bucketMinutes == 60)
        #expect(dto.grain == .hourly)
        #expect(dto.baseline == nil)
        #expect(dto.source == .none)
        // baselineSource "none" must never grow a reference line.
        #expect(dto.drawableBaseline == nil)
    }

    @Test("fetch — an unknown resolution / baselineSource literal survives decoding")
    func fetchTolerantEnums() async throws {
        let repo = IntradayPulseRepository(api: makeAPI())
        let body = Data(#"""
        {"data":{
          "dateKey":"2026-07-24","timezone":"Europe/Berlin","bucketMinutes":5,
          "series":[{"startMinute":0,"mean":60,"count":9}],
          "baseline":61,"baselineSource":"future","tension":null,"resolution":"fiveMin"
        },"error":null}
        """#.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try #require(try await repo.fetch(dateKey: "2026-07-24", todayKey: "2026-07-24"))
        #expect(dto.grain == .unknown)
        #expect(dto.source == .unknown)
        // Unknown provenance is not a licence to draw a line we can't explain.
        #expect(dto.drawableBaseline == nil)
    }

    @Test("fetch — 403 MODULE_DISABLED → nil (block hidden, no error)")
    func fetch403IsNil() async throws {
        let repo = IntradayPulseRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":{"message":"Module disabled","code":"MODULE_DISABLED"}}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        #expect(try await repo.fetch(dateKey: nil, todayKey: "2026-07-24") == nil)
    }

    @Test("fetch — 404 (route absent on an older server) → nil")
    func fetch404IsNil() async throws {
        let repo = IntradayPulseRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetch(dateKey: nil, todayKey: "2026-07-24") == nil)
    }

    @Test("fetch — 422 (rejected date) → nil, never an error")
    func fetch422IsNil() async throws {
        let repo = IntradayPulseRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetch(dateKey: "nonsense", todayKey: "2026-07-24") == nil)
    }

    @Test("fetch — the date key lands in the query; today sends no parameter")
    func queryWiring() async throws {
        let seen = SeenURLs()
        let body = Data(groundTruth.utf8)
        MockURLProtocol.handler = { req in
            seen.record(req.url?.absoluteString ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = IntradayPulseRepository(api: makeAPI())
        _ = try await repo.fetch(dateKey: "2026-07-20", todayKey: "2026-07-24")
        _ = try await repo.fetch(dateKey: nil, todayKey: "2026-07-24")
        let urls = seen.all()
        #expect(urls.count == 2)
        #expect(urls[0].contains("date=2026-07-20"))
        #expect(!urls[1].contains("date="))
    }

    @Test("fetch — a past day is memoized; today is always re-read")
    func pastDayMemo() async throws {
        let seen = SeenURLs()
        let body = Data(groundTruth.utf8)
        MockURLProtocol.handler = { req in
            seen.record(req.url?.absoluteString ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = IntradayPulseRepository(api: makeAPI())
        _ = try await repo.fetch(dateKey: "2026-07-20", todayKey: "2026-07-24")
        _ = try await repo.fetch(dateKey: "2026-07-20", todayKey: "2026-07-24")
        #expect(seen.all().count == 1, "a finished past day is immutable — one round-trip")

        _ = try await repo.fetch(dateKey: "2026-07-24", todayKey: "2026-07-24")
        _ = try await repo.fetch(dateKey: "2026-07-24", todayKey: "2026-07-24")
        #expect(seen.all().count == 3, "today keeps growing — never memoized")
    }
}

/// Tiny thread-safe recorder for the URLs the stub transport saw. The handler
/// closure is `@Sendable` and runs off the test's actor, so a plain array would
/// be a data race.
private final class SeenURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []

    func record(_ url: String) {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

// swiftlint:enable force_unwrapping
