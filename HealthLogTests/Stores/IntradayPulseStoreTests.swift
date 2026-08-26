import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// The intraday-pulse store's gating + navigator behaviour, driven through the
/// REAL `APIClient` over `MockURLProtocol` (never a mock server) so a wire
/// drift shows up here too.
///
/// Pins the surface contract:
/// - an empty first load keeps the block gate CLOSED (no dead card body)
/// - a day with buckets opens it
/// - paging into an empty past day keeps the navigator state so the operator
///   can page back out
/// - `403` (module off) hides the block without an error
///
/// `.serialized` — every case installs its own handler.
@Suite("IntradayPulseStore — block gate + day navigator", .serialized)
@MainActor
struct IntradayPulseStoreTests {
    private func makeStore() -> IntradayPulseStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return IntradayPulseStore(repo: IntradayPulseRepository(api: api))
    }

    private var berlin: TimeZone {
        TimeZone(identifier: "Europe/Berlin")!
    }

    private func respond(_ json: String, status: Int = 200) {
        let body = Data(json.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
        }
    }

    private func dayJSON(dateKey: String, buckets: String) -> String {
        """
        {"data":{"dateKey":"\(dateKey)","timezone":"Europe/Berlin","bucketMinutes":10,
        "series":[\(buckets)],"baseline":76,"baselineSource":"resting",
        "tension":null,"resolution":"tenMin"},"error":null}
        """
    }

    @Test("first load with an empty day keeps the block gate closed")
    func emptyFirstLoadStaysHidden() async {
        let store = makeStore()
        respond(dayJSON(dateKey: "2026-07-24", buckets: ""))
        await store.load(in: berlin)
        #expect(store.hasSettledOnce)
        #expect(!store.hasContent, "an empty day must not paint a card shell")
        #expect(!store.isPinnedToPastDay)
        #expect(!store.loadFailed)
    }

    @Test("a day with buckets opens the block gate")
    func dayWithDataIsVisible() async {
        let store = makeStore()
        respond(dayJSON(
            dateKey: "2026-07-24",
            buckets: #"{"startMinute":540,"mean":87,"count":2,"min":85,"max":89}"#
        ))
        await store.load(in: berlin)
        #expect(store.hasContent)
        #expect(store.day?.series.count == 1)
        #expect(store.day?.drawableBaseline == 76)
    }

    @Test("paging back to an empty day keeps the navigator (block stays reachable)")
    func navigatingIntoEmptyDayKeepsShell() async {
        let store = makeStore()
        respond(dayJSON(dateKey: "2026-07-24", buckets: #"{"startMinute":540,"mean":87,"count":2}"#))
        await store.load(in: berlin)
        #expect(store.hasContent)

        respond(dayJSON(dateKey: "2026-07-23", buckets: ""))
        await store.goToPreviousDay(in: berlin)
        #expect(store.day?.series.isEmpty == true)
        #expect(!store.hasContent)
        #expect(store.isPinnedToPastDay, "the shell (and its navigator) must survive an empty past day")
        #expect(!store.isOnToday(in: berlin))
    }

    @Test("the next-day step is capped at today and returns to the live key")
    func nextDayCapped() async throws {
        let store = makeStore()
        let today = IntradayPulseMath.dayKey(in: berlin)
        let yesterday = try #require(IntradayPulseMath.shift(dayKey: today, by: -1, in: berlin))
        respond(dayJSON(dateKey: today, buckets: #"{"startMinute":0,"mean":60,"count":2}"#))
        await store.load(in: berlin)

        respond(dayJSON(dateKey: yesterday, buckets: #"{"startMinute":0,"mean":61,"count":2}"#))
        await store.goToPreviousDay(in: berlin)
        #expect(store.selectedDateKey == yesterday)

        respond(dayJSON(dateKey: today, buckets: #"{"startMinute":0,"mean":60,"count":2}"#))
        await store.goToNextDay(in: berlin)
        #expect(store.selectedDateKey == nil, "landing on today resumes tracking the live day")
        #expect(store.isOnToday(in: berlin))

        // A further forward step is a no-op — never into the future.
        await store.goToNextDay(in: berlin)
        #expect(store.selectedDateKey == nil)
    }

    @Test("403 (module insights off) hides the block — no error, no card")
    func moduleDisabledHidesBlock() async {
        let store = makeStore()
        respond(#"{"data":null,"error":{"message":"Module disabled","code":"MODULE_DISABLED"}}"#, status: 403)
        await store.load(in: berlin)
        #expect(store.day == nil)
        #expect(!store.hasContent)
        #expect(!store.loadFailed, "a gate is not a failure — no retry line")
    }

    @Test("a transport failure drops the stale day and offers a retry")
    func transportFailureIsHonest() async {
        let store = makeStore()
        respond(dayJSON(dateKey: "2026-07-24", buckets: #"{"startMinute":540,"mean":87,"count":2}"#))
        await store.load(in: berlin)
        #expect(store.hasContent)

        // A non-gate failure (400 is outside the 403/404/422 hide-arms and is
        // not retried), so the store must surface it as a retry, not as data.
        respond(#"{"data":null,"error":{"message":"Bad request"}}"#, status: 400)
        await store.refresh(in: berlin)
        #expect(store.day == nil, "a stale curve must never sit under a new day's label")
        #expect(store.loadFailed)
    }

    @Test("clearOnLogout wipes the day and the navigator")
    func logoutWipes() async {
        let store = makeStore()
        respond(dayJSON(dateKey: "2026-07-24", buckets: #"{"startMinute":540,"mean":87,"count":2}"#))
        await store.load(in: berlin)
        store.clearOnLogout()
        #expect(store.day == nil)
        #expect(store.selectedDateKey == nil)
        #expect(!store.hasSettledOnce)
    }
}

// swiftlint:enable force_unwrapping
