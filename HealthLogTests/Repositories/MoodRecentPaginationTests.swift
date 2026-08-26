import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.10.0 Walkthrough-3 B16 — mood history pagination.
///
/// The old `MoodRepository.recent(days:)` sent only `days=…` (a param the
/// server silently drops) and **no `limit`**, so the server returned its
/// default 100-row newest-first page; months of mood history never reached
/// the heatmap / year-in-pixels / stats. The fix sends `from`/`to` +
/// `limit=500` + `offset` and **paginates** until `meta.total` is drained
/// (or a short page arrives). These tests drive the real `MoodRepository`
/// over the real `APIClient` (`MockURLProtocol` HTTP) and assert that a
/// multi-page response is fully aggregated.
@Suite("Mood recent() paginates full history (B16)", .serialized)
struct MoodRecentPaginationTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.10.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    /// One mood JSON row with a stable id index.
    private static func row(_ i: Int) -> String {
        """
        {"id":"srv-mood-\(i)","mood":"GUT","tags":[],\
        "moodLoggedAt":"2026-05-31T08:00:00.000Z","source":"MANUAL","note":null}
        """
    }

    private func pageResponse(_ req: URLRequest, entries: [Int], total: Int) -> (HTTPURLResponse, Data) {
        let rows = entries.map { Self.row($0) }.joined(separator: ",")
        let body = #"{"data":{"entries":[\#(rows)],"meta":{"total":\#(total),"limit":500,"offset":0}}}"#
        return (
            HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }

    @Test("recent() drains multiple pages and aggregates all entries (total > one page)")
    func paginatesAcrossPages() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)

        let total = 712 // 500 (page 1) + 212 (page 2)
        let recorder = OffsetRecorder()

        MockURLProtocol.handler = { [self] req in
            let offset = Int(
                URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "offset" })?.value ?? "0"
            ) ?? 0
            recorder.record(offset: offset)
            // First full page (500), then the remaining 212.
            if offset == 0 {
                return pageResponse(req, entries: Array(0 ..< 500), total: total)
            } else {
                return pageResponse(req, entries: Array(500 ..< total), total: total)
            }
        }

        let entries = try await repo.recent(days: 400)

        #expect(entries.count == total, "All \(total) entries across both pages must be aggregated")
        // Exactly two requests: offset 0 then offset 500. No third (short page stops).
        #expect(recorder.offsets() == [0, 500])
        // Distinct ids — no duplication across pages.
        #expect(Set(entries.map(\.id)).count == total)
    }

    @Test("recent() stops after a single short page when history fits in one page")
    func singleShortPageStops() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)

        let recorder = OffsetRecorder()
        MockURLProtocol.handler = { [self] req in
            let offset = Int(
                URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "offset" })?.value ?? "0"
            ) ?? 0
            recorder.record(offset: offset)
            return pageResponse(req, entries: Array(0 ..< 37), total: 37)
        }

        let entries = try await repo.recent(days: 400)

        #expect(entries.count == 37)
        #expect(recorder.offsets() == [0], "A page shorter than pageSize must stop pagination")
    }

    @Test("History request carries range, mood, source, and pagination without touching recent()")
    func historyQueryCarriesFiltersAndPagination() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MoodRepository(api: api, outbox: outbox)
        let recorder = QueryRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let body = #"{"data":{"entries":[],"meta":{"total":42,"limit":25,"offset":25}}}"#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let query = MoodHistoryQuery(
            from: "2026-05-01",
            to: "2026-05-31",
            mood: .bad,
            source: .daylio,
            limit: 25,
            offset: 25
        )
        let response = try await repo.history(query: query)

        #expect(recorder.items == [
            "from": "2026-05-01",
            "to": "2026-05-31",
            "mood": "SCHLECHT",
            "source": "DAYLIO",
            "limit": "25",
            "offset": "25",
            "sortBy": "moodLoggedAt",
            "sortDir": "desc"
        ])
        #expect(response.meta?.total == 42)
        #expect(response.meta?.offset == 25)
    }

    @Test("History filter reset clears every server filter and returns to the first page")
    func historyFilterReset() {
        var filter = MoodHistoryFilter(
            period: .custom,
            customFrom: "2026-05-10",
            customTo: "2026-05-01",
            mood: .great,
            source: .web
        )

        let normalized = filter.query(limit: 25, offset: 50)
        #expect(normalized.from == "2026-05-01")
        #expect(normalized.to == "2026-05-10")
        #expect(normalized.offset == 50)

        filter.reset()
        let reset = filter.query(limit: 25, offset: 0)
        #expect(filter == MoodHistoryFilter())
        #expect(reset.from == nil)
        #expect(reset.to == nil)
        #expect(reset.mood == nil)
        #expect(reset.source == nil)
        #expect(reset.offset == 0)
    }

    @Test("Standalone date matching treats from and to as inclusive local calendar days")
    func historyDateMatchingIsInclusive() throws {
        let formatter = ISO8601DateFormatter()
        let start = try #require(formatter.date(from: "2026-05-01T00:00:00Z"))
        let end = try #require(formatter.date(from: "2026-05-31T23:59:59Z"))
        let before = try #require(formatter.date(from: "2026-04-30T23:59:59Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let query = MoodHistoryQuery(from: "2026-05-01", to: "2026-05-31")

        #expect(query.matches(MoodEntry(id: "a", recordedAt: start, score: 3), calendar: calendar))
        #expect(query.matches(MoodEntry(id: "b", recordedAt: end, score: 3), calendar: calendar))
        #expect(!query.matches(MoodEntry(id: "c", recordedAt: before, score: 3), calendar: calendar))
    }

    @MainActor
    @Test("Filtered history pages never replace MoodStore analytics entries")
    func filteredHistoryDoesNotMutateAnalyticsState() async throws {
        let api = makeAPI()
        let repo = try MoodRepository(api: api, outbox: OutboxQueue(inMemory: true))
        let store = MoodStore(repo: repo)
        MockURLProtocol.handler = { request in
            let body = """
            {"data":{"entries":[{
              "id":"analytics","mood":"SUPER_GUT","tags":[],
              "moodLoggedAt":"2026-05-31T08:00:00.000Z","source":"MANUAL"
            }],"meta":{"total":1,"limit":500,"offset":0}}}
            """
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        await store.load()
        let analyticsEntries = store.entries
        #expect(analyticsEntries.map(\.id) == ["analytics"])

        MockURLProtocol.handler = { request in
            let body = """
            {"data":{"entries":[\(Self.row(1))],"meta":{"total":1,"limit":25,"offset":0}}}
            """
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }

        let page = try await store.history(
            query: MoodHistoryQuery(mood: .good, source: .manual)
        )

        #expect(page.entries.map(\.id) == ["srv-mood-1"])
        #expect(store.entries == analyticsEntries)
    }
}

/// Actor-safe offset recorder (runs inside the URLSession queue).
private final class OffsetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int] = []

    func record(offset: Int) {
        lock.lock()
        defer { lock.unlock() }
        seen.append(offset)
    }

    func offsets() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

private final class QueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func record(_ request: URLRequest) {
        let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        lock.withLock {
            stored = Dictionary(
                queryItems.compactMap { item in item.value.map { (item.name, $0) } },
                uniquingKeysWith: { _, latest in latest }
            )
        }
    }

    var items: [String: String] {
        lock.withLock { stored }
    }
}

// swiftlint:enable force_unwrapping
