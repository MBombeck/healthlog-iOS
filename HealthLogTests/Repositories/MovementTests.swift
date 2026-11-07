import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping file_length type_body_length

/// **1.5 MOVE (#133)** — movement from Dawarich under Environment: the wire
/// contract of `GET /api/dawarich/status`, the `movement` block of
/// `GET /api/day/{date}` and the `dawarich` entry of `GET /api/integrations/status`
/// (server with and without each), the section state (not connected, no
/// data, refusal, failure and retry, the day switcher across month and year
/// ends, never into the future), the owner-only rule for a delegate's
/// record, and the wording that shows the server's figures without a `null`
/// ever turning into zero.
@Suite("1.5 MOVE — movement under Environment", .serialized, .mockURLSession)
struct MovementTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.5.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private static func response(_ request: URLRequest, status: Int = 200, body: String) -> (HTTPURLResponse, Data?) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    /// `DawarichStatus` as the v1.47.0 OpenAPI documents it.
    static let statusBody = #"""
    {"data":{"connected":true,"configured":true,"homePlaceSet":true,"homeCountry":"DE","daysStored":5,
      "oldestDay":"2026-10-30","latestDay":"2026-11-03",
      "health":{"state":"ok","reason":"data_arriving","since":null,"action":null,"unavailable":[]}},"error":null}
    """#

    /// A whole `Day` with the movement block among sections this build does
    /// not read (they must not break the decode).
    static let dayBody = #"""
    {"data":{"date":"2026-11-03","tz":"Europe/Berlin","counts":{"values":4,"entries":2},
      "readings":[{"type":"WEIGHT","value":81.2}],"sections":{"life":{"available":false,"reason":"not_shared"}},
      "movement":{"source":"dawarich","distance":{"unit":"km","total":42.7,"driving":31.2,"train":null},
        "placesVisited":6,"awayFromHomeMinutes":412,"travel":{"isTravelDay":true,"countryCode":"NL"},
        "fetchedAt":"2026-11-04T05:00:00.000Z"}},"error":null}
    """#

    private static func decodeDay(_ json: String) throws -> DayMovement? {
        try JSONDecoder.hlDefault.decode(Envelope<DayMovementPayload>.self, from: Data(json.utf8)).data.movement
    }

    private struct Envelope<T: Decodable>: Decodable {
        let data: T
    }

    private static let de = Locale(identifier: "de_DE")
    private static let en = Locale(identifier: "en_US")

    // MARK: - Wire contract

    @Test("the status reads connection and the stored day range")
    func decodesStatus() throws {
        let status = try JSONDecoder.hlDefault.decode(Envelope<DawarichStatus>.self, from: Data(Self.statusBody.utf8)).data
        #expect(status == DawarichStatus(connected: true, oldestDay: "2026-10-30", latestDay: "2026-11-03"))
    }

    @Test("a status without days, with a bad day key or with missing fields stays readable")
    func decodesTolerantStatus() throws {
        let none = try JSONDecoder.hlDefault.decode(
            DawarichStatus.self,
            from: Data(#"{"connected":true,"oldestDay":null,"latestDay":null}"#.utf8)
        )
        #expect(none == DawarichStatus(connected: true))
        let bad = try JSONDecoder.hlDefault.decode(DawarichStatus.self, from: Data(#"{"connected":true,"latestDay":"2026-02-30"}"#.utf8))
        #expect(bad.latestDay == nil)
        let empty = try JSONDecoder.hlDefault.decode(DawarichStatus.self, from: Data("{}".utf8))
        #expect(empty == DawarichStatus(connected: false))
    }

    @Test("server with the field: the movement block decodes as given, the rest of the day is ignored")
    func decodesMovement() throws {
        let movement = try #require(try Self.decodeDay(Self.dayBody))
        #expect(movement.distance == DayMovement.Distance(unit: "km", total: 42.7, driving: 31.2, train: nil))
        #expect(movement.placesVisited == 6)
        #expect(movement.awayFromHomeMinutes == 412)
        #expect(movement.travel == DayMovement.Travel(isTravelDay: true, countryCode: "NL"))
        #expect(movement.hasValues)
    }

    @Test("server without the field: absent, null and malformed movement all read as no block")
    func decodesWithoutMovement() throws {
        #expect(try Self.decodeDay(#"{"data":{"date":"2026-11-03","tz":"Europe/Berlin"},"error":null}"#) == nil)
        #expect(try Self.decodeDay(#"{"data":{"date":"2026-11-03","movement":null},"error":null}"#) == nil)
        #expect(try Self.decodeDay(#"{"data":{"date":"2026-11-03","movement":"soon"},"error":null}"#) == nil)
    }

    @Test("a null is never zero: every null field stays nil and the day has no values")
    func nullsStayNil() throws {
        let json = #"""
        {"data":{"movement":{"source":"dawarich","distance":{"unit":"mi","total":null,"driving":null,"train":null},
          "placesVisited":null,"awayFromHomeMinutes":null,"travel":null,"fetchedAt":"2026-11-04T05:00:00.000Z"}},"error":null}
        """#
        let movement = try #require(try Self.decodeDay(json))
        #expect(movement.distance == DayMovement.Distance(unit: "mi", total: nil, driving: nil, train: nil))
        #expect(movement.placesVisited == nil)
        #expect(movement.awayFromHomeMinutes == nil)
        #expect(movement.travel == nil)
        #expect(!movement.hasValues)
        #expect(EnvironmentMovementSection.rows(movement, locale: Self.de).isEmpty)
    }

    @Test("a zero the server sends is a real zero and is shown")
    func zeroIsShown() {
        let movement = DayMovement(
            distance: .init(unit: "km", total: 0, driving: nil, train: nil),
            placesVisited: 0,
            awayFromHomeMinutes: 0,
            travel: .init(isTravelDay: false, countryCode: nil)
        )
        let rows = EnvironmentMovementSection.rows(movement, locale: Self.de)
        #expect(rows.map(\.id) == ["total", "places", "away"])
        #expect(rows[0].value == "0,0\u{00A0}km")
        #expect(rows[1].value == "0")
    }

    @Test("a distance without a unit is not shown")
    func distanceWithoutUnit() throws {
        let json = #"{"data":{"movement":{"distance":{"total":12.5},"placesVisited":2}},"error":null}"#
        let movement = try #require(try Self.decodeDay(json))
        #expect(movement.distance == nil)
        #expect(EnvironmentMovementSection.rows(movement, locale: Self.en).map(\.id) == ["places"])
    }

    // MARK: - Repository

    @Test("the repository reads the status and the day by its key")
    func repositoryPaths() async throws {
        let repo = MovementRepository(api: makeAPI())
        let seen = LockedPaths()
        MockURLProtocol.install { req in
            seen.append(req.url!.path)
            let body = req.url!.path == "/api/dawarich/status" ? Self.statusBody : Self.dayBody
            return Self.response(req, body: body)
        }
        let status = try await repo.status()
        #expect(status.latestDay == "2026-11-03")
        let movement = try await repo.movement(on: "2026-11-03")
        #expect(movement?.placesVisited == 6)
        #expect(seen.all == ["/api/dawarich/status", "/api/day/2026-11-03"])
    }

    @Test("integrations status: the dawarich entry with its health; unknown entries skipped; absent on older servers")
    func integrationEntry() async throws {
        let repo = MovementRepository(api: makeAPI())
        MockURLProtocol.install { req in
            Self.response(req, body: #"""
            {"data":{"threshold":3,"metricFreshnessDegraded":false,"integrations":[
              {"integration":"withings","connected":true},
              {"integration":"somethingNew","connected":"maybe"},
              {"integration":"dawarich","connected":true,
               "health":{"state":"degraded","reason":"no_new_data","since":"2026-11-01T08:00:00.000Z","action":null,"unavailable":[]}}
            ]},"error":null}
            """#)
        }
        let entry = try #require(try await repo.integrationEntry())
        #expect(entry.connected)
        #expect(entry.health?.state == .degraded)
        #expect(entry.health?.reason == .noNewData)

        MockURLProtocol.install { req in
            Self.response(req, body: #"{"data":{"threshold":3,"integrations":[{"integration":"withings","connected":true}]},"error":null}"#)
        }
        #expect(try await repo.integrationEntry() == nil)
    }

    @Test("for a delegate's record the reads never go out and the section stays away")
    func delegateNeverSeesMovement() async throws {
        let api = makeAPI()
        let entry = try #require(try JSONDecoder.hlDefault.decode([AccountAccessEntry].self, from: Data(#"""
        [{"accountId":"fixture-record","username":"fixture","access":"read","level":"read",
          "recordKind":"shared","sections":null,"canWrite":false}]
        """#.utf8)).first)
        await api.selectAccount(entry)
        let seen = LockedPaths()
        MockURLProtocol.install { req in
            seen.append(req.url!.path)
            return Self.response(req, body: Self.statusBody)
        }
        let store = await MovementStore(repository: MovementRepository(api: api))
        await store.load()
        #expect(await store.phase == .hidden)
        #expect(seen.all.isEmpty)
    }

    // MARK: - Section state

    @MainActor
    private func makeStore(
        status: Result<DawarichStatus, Error> = .success(DawarichStatus(connected: true, oldestDay: "2026-10-30", latestDay: "2026-11-03")),
        today: String = "2026-11-05",
        days: @escaping @Sendable (String) throws -> DayMovement? = { _ in MovementTests.sample }
    ) -> (MovementStore, LockedPaths) {
        let asked = LockedPaths()
        let store = MovementStore(
            fetchStatus: { try status.get() },
            fetchDay: { day in
                asked.append(day)
                return try days(day)
            },
            today: { today }
        )
        return (store, asked)
    }

    static let sample = DayMovement(
        distance: .init(unit: "km", total: 12.3, driving: nil, train: nil),
        placesVisited: 2,
        awayFromHomeMinutes: nil,
        travel: nil
    )

    @Test("not connected: the web-only line, no day read")
    @MainActor
    func notConnected() async {
        let (store, asked) = makeStore(status: .success(DawarichStatus(connected: false)))
        await store.load()
        #expect(store.phase == .notConnected)
        #expect(asked.all.isEmpty)
    }

    @Test("connected without any stored day: the no-data line")
    @MainActor
    func connectedWithoutDays() async {
        let (store, asked) = makeStore(status: .success(DawarichStatus(connected: true)))
        await store.load()
        #expect(store.phase == .noData)
        #expect(asked.all.isEmpty)
    }

    @Test("starts on the latest stored day")
    @MainActor
    func startsOnLatestDay() async {
        let (store, asked) = makeStore()
        await store.load()
        #expect(store.phase == .ready)
        #expect(store.selectedDay == "2026-11-03")
        #expect(store.dayPhase == .loaded(Self.sample))
        #expect(asked.all == ["2026-11-03"])
    }

    @Test(
        "a refusal or a server without the route closes the section",
        arguments: [
            HLError.moduleDisabled("environment"),
            HLError.server(status: 403, code: "sharing.client.access.denied", message: ""),
            HLError.server(status: 404, code: nil, message: "Not found")
        ]
    )
    @MainActor
    func refusalHides(error: HLError) async {
        let (store, _) = makeStore(status: .failure(error))
        await store.load()
        #expect(store.phase == .hidden)
    }

    @Test("server without the movement block on the first day: no section")
    @MainActor
    func noBlockHides() async {
        let (store, _) = makeStore(days: { _ in nil })
        await store.load()
        #expect(store.phase == .hidden)
    }

    @Test("a failed status read shows the retry row; retry recovers")
    @MainActor
    func failedThenRetry() async {
        let flaky = Flaky()
        let store = MovementStore(
            fetchStatus: {
                if flaky.next() { throw HLError.server(status: 502, code: nil, message: "") }
                return DawarichStatus(connected: true, latestDay: "2026-11-03")
            },
            fetchDay: { _ in Self.sample },
            today: { "2026-11-05" }
        )
        await store.load()
        #expect(store.phase == .failed)
        await store.retry()
        #expect(store.phase == .ready)
        #expect(store.dayPhase == .loaded(Self.sample))
    }

    @Test("a failed day keeps the switcher and offers retry")
    @MainActor
    func failedDay() async {
        let (store, _) = makeStore(days: { day in
            if day == "2026-11-02" { throw HLError.server(status: 500, code: nil, message: "") }
            return Self.sample
        })
        await store.load()
        await store.step(by: -1)
        #expect(store.phase == .ready)
        #expect(store.selectedDay == "2026-11-02")
        #expect(store.dayPhase == .failed)
        #expect(store.canGoBack && store.canGoForward)
    }

    @Test("a later day without a block reads as a day without values, not as a missing section")
    @MainActor
    func laterDayWithoutBlock() async {
        let (store, _) = makeStore(days: { day in day == "2026-11-03" ? Self.sample : nil })
        await store.load()
        await store.step(by: -1)
        #expect(store.phase == .ready)
        #expect(store.dayPhase == .loaded(nil))
    }

    @Test("stepping back crosses the month and stops at the oldest stored day")
    @MainActor
    func stepsBackAcrossMonth() async {
        let (store, asked) = makeStore(status: .success(DawarichStatus(connected: true, oldestDay: "2026-10-31", latestDay: "2026-11-01")))
        await store.load()
        #expect(store.canGoBack)
        await store.step(by: -1)
        #expect(store.selectedDay == "2026-10-31")
        #expect(!store.canGoBack)
        await store.step(by: -1)
        #expect(store.selectedDay == "2026-10-31")
        #expect(asked.all == ["2026-11-01", "2026-10-31"])
    }

    @Test("stepping forward stops at today, never in the future, also across a year end")
    @MainActor
    func forwardStopsAtToday() async {
        let (store, asked) = makeStore(
            status: .success(DawarichStatus(connected: true, latestDay: "2026-12-31")),
            today: "2027-01-01"
        )
        await store.load()
        #expect(store.canGoForward)
        await store.step(by: 1)
        #expect(store.selectedDay == "2027-01-01")
        #expect(!store.canGoForward)
        await store.step(by: 1)
        #expect(store.selectedDay == "2027-01-01")
        #expect(asked.all == ["2026-12-31", "2027-01-01"])
    }

    @Test("a latest day ahead of the device's today starts on today")
    @MainActor
    func latestAheadOfToday() async {
        let (store, _) = makeStore(status: .success(DawarichStatus(connected: true, latestDay: "2026-11-06")), today: "2026-11-05")
        await store.load()
        #expect(store.selectedDay == "2026-11-05")
        #expect(!store.canGoForward)
    }

    @Test("a day already read shows at once and is read again behind it")
    @MainActor
    func staleWhileRevalidate() async {
        let (store, asked) = makeStore()
        await store.load()
        await store.step(by: -1)
        await store.step(by: 1)
        #expect(store.dayPhase == .loaded(Self.sample))
        #expect(asked.all == ["2026-11-03", "2026-11-02", "2026-11-03"])
    }

    @Test("refresh keeps the chosen day")
    @MainActor
    func refreshKeepsDay() async {
        let (store, _) = makeStore()
        await store.load()
        await store.step(by: -1)
        await store.load()
        #expect(store.selectedDay == "2026-11-02")
    }

    // MARK: - Day keys

    @Test(
        "day keys step over month, year and leap-day boundaries",
        arguments: [
            ("2026-11-01", -1, "2026-10-31"),
            ("2026-03-01", -1, "2026-02-28"),
            ("2024-03-01", -1, "2024-02-29"),
            ("2026-12-31", 1, "2027-01-01"),
            ("2026-03-29", 1, "2026-03-30"),
            ("2026-10-25", -1, "2026-10-24")
        ]
    )
    func dayKeys(start: String, offset: Int, expected: String) {
        #expect(MovementDay.shift(start, by: offset) == expected)
    }

    @Test("an invalid key does not step; today is the device's local date")
    func todayAndInvalid() throws {
        #expect(MovementDay.shift("2026-13-01", by: 1) == nil)
        #expect(MovementDay.shift("yesterday", by: 1) == nil)
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-11-04T23:30:00Z"))
        #expect(try MovementDay.today(now: instant, timeZone: #require(TimeZone(identifier: "Europe/Berlin"))) == "2026-11-05")
        #expect(try MovementDay.today(now: instant, timeZone: #require(TimeZone(identifier: "America/New_York"))) == "2026-11-04")
    }

    // MARK: - Wording

    @Test("rows in fixed order with the server's unit; nulls left out")
    func rowsGerman() throws {
        let movement = try #require(try Self.decodeDay(Self.dayBody))
        let rows = EnvironmentMovementSection.rows(movement, locale: Self.de)
        #expect(rows.map(\.id) == ["total", "driving", "places", "away", "travel"])
        #expect(rows[0].value == "42,7\u{00A0}km")
        #expect(rows[1].value == "31,2\u{00A0}km")
        #expect(rows[2].value == "6")
        #expect(rows[3].value.contains("6") && rows[3].value.contains("52"))
        #expect(rows[4].value == "Niederlande")
    }

    @Test("miles stay miles, English country name")
    func rowsEnglishMiles() {
        let movement = DayMovement(
            distance: .init(unit: "mi", total: 26.5, driving: nil, train: 20.1),
            placesVisited: nil,
            awayFromHomeMinutes: 95,
            travel: .init(isTravelDay: true, countryCode: "fr")
        )
        let rows = EnvironmentMovementSection.rows(movement, locale: Self.en)
        #expect(rows.map(\.id) == ["total", "train", "away", "travel"])
        #expect(rows[0].value == "26.5\u{00A0}mi")
        #expect(rows[1].value == "20.1\u{00A0}mi")
        #expect(rows[2].value.contains("1") && rows[2].value.contains("35"))
        #expect(rows[3].value == "France")
    }

    @Test("a travel day without a country says yes; a day that is not one has no row")
    func travelRow() {
        let unknown = DayMovement(
            distance: nil,
            placesVisited: nil,
            awayFromHomeMinutes: nil,
            travel: .init(isTravelDay: true, countryCode: nil)
        )
        let rows = EnvironmentMovementSection.rows(unknown, locale: Self.de)
        #expect(rows.map(\.id) == ["travel"])
        #expect(rows[0].value == String(localized: "environment.movement.travelDay.yes"))
        let home = DayMovement(
            distance: nil,
            placesVisited: nil,
            awayFromHomeMinutes: nil,
            travel: .init(isTravelDay: false, countryCode: "DE")
        )
        #expect(EnvironmentMovementSection.rows(home, locale: Self.de).isEmpty)
        #expect(!home.hasValues)
    }

    @Test("the switcher's title names the server's day, not the device's")
    func dayTitle() {
        let title = EnvironmentMovementSection.dayTitle("2026-11-03", locale: Self.de)
        #expect(title.contains("3"))
        #expect(title.contains("November"))
        #expect(title.contains("Dienstag"))
        #expect(EnvironmentMovementSection.dayTitle("garbage", locale: Self.de) == "garbage")
    }

    @Test("every new text resolves in the catalog, never to its key")
    func catalogKeys() {
        let keys = [
            "environment.movement.section", "environment.movement.previousDay", "environment.movement.nextDay",
            "environment.movement.distance.total", "environment.movement.distance.driving",
            "environment.movement.distance.train", "environment.movement.places", "environment.movement.away",
            "environment.movement.travelDay", "environment.movement.travelDay.yes", "environment.movement.dayEmpty",
            "environment.movement.noData", "environment.movement.notConnected", "environment.movement.error",
            "integration.dawarich.webOnly"
        ]
        for key in keys {
            #expect(String(localized: String.LocalizationValue(key)) != key, "\(key) resolves to itself")
        }
    }
}

// MARK: - Small thread-safe helpers

private final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }

    var all: [String] {
        lock.withLock { values }
    }
}

/// Fails the first call, succeeds after.
private final class Flaky: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func next() -> Bool {
        lock.withLock {
            calls += 1
            return calls == 1
        }
    }
}
