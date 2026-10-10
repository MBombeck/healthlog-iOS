import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// #19 — the Workouts list loaded one page of 50 and stopped there; the
/// server's `meta.total` was decoded but never used.
///
/// These cases drive the real `WorkoutsStore` → `WorkoutsRepository` →
/// `APIClient` stack against a paged fake of `GET /api/workouts` that slices
/// one canonical, newest-first array the way the server does
/// (`src/lib/workouts/list-read.ts`, v1.39.0: dedup over the whole filtered
/// set, then `offset`/`limit`; `meta.total` = canonical row count).
@Suite("#19 WorkoutsStore — paging up to meta.total", .serialized, .mockURLSession)
@MainActor
struct WorkoutsStorePagingTests {
    // MARK: - Pages, order, stop

    @Test("pages append in server order until meta.total, the short last page ends it")
    func pagesAppendUntilTotal() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let store = try makeStore(server)

        await store.load()
        #expect(store.workouts.count == 50)
        #expect(store.meta?.total == 730)
        #expect(store.hasMorePages)

        var rounds = 0
        while store.hasMorePages, rounds < 30 {
            await store.loadNextPage()
            rounds += 1
        }

        #expect(store.workouts.count == 730)
        #expect(store.workouts.map(\.id) == server.allIDs())
        #expect(!store.hasMorePages)
        #expect(server.requestedOffsets() == Array(stride(from: 0, through: 700, by: 50)))
        #expect(server.requests().allSatisfy { $0.limit == 50 })

        await store.loadNextPage()
        #expect(server.requests().count == 15, "a complete list must not ask the server again")
    }

    @Test("rapid appear events while a page is in flight fetch that page exactly once")
    func rapidAppearFetchesOnce() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let store = try makeStore(server)
        await store.load()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 6 {
                group.addTask { await store.loadNextPage() }
            }
        }

        #expect(server.requestedOffsets() == [0, 50])
        #expect(store.workouts.count == 100)
        #expect(Set(store.workouts.map(\.id)).count == 100)
    }

    // MARK: - Refresh and filter

    @Test("pull to refresh starts again at page one and keeps the sport filter")
    func refreshResetsAndKeepsFilter() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let store = try makeStore(server)
        await store.setSportType("running")
        await store.loadNextPage()
        #expect(store.workouts.count == 100)

        await store.refresh()

        #expect(store.currentSportType == "running")
        #expect(store.workouts.count == 50)
        #expect(store.currentOffset == 50)
        #expect(store.workouts.map(\.id) == Array(server.allIDs(sportType: "running").prefix(50)))
        #expect(store.meta?.total == server.allIDs(sportType: "running").count)
        #expect(server.requests().allSatisfy { $0.sportType == "running" })
    }

    @Test("changing the sport filter resets paging to the new filter's first page")
    func filterChangeResetsPaging() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let store = try makeStore(server)
        await store.load()
        await store.loadNextPage()
        await store.loadNextPage()
        #expect(store.workouts.count == 150)

        await store.setSportType("running")

        let running = server.allIDs(sportType: "running")
        #expect(store.workouts.map(\.id) == Array(running.prefix(50)))
        #expect(store.meta?.total == running.count)
        #expect(store.currentOffset == 50)
        #expect(server.requests().last == PagedWorkoutsServer.Request(offset: 0, limit: 50, sportType: "running"))
    }

    @Test("a fresh first page evicts the cached later pages of the same filter")
    func freshFirstPageEvictsLaterPages() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let clock = WorkoutsPagingClock()
        let store = try makeStore(server, clock: clock)
        await store.load()
        clock.advance(by: 30)
        await store.loadNextPage()
        #expect(server.requestedOffsets() == [0, 50])

        // Inside the 60 s window both pages come from the cache.
        await store.refresh()
        await store.loadNextPage()
        #expect(server.requestedOffsets() == [0, 50])

        // A workout lands. Page one's window runs out, page two's (cached
        // 30 s later) would still be fresh and is now one row out of step.
        server.insertNewest()
        clock.advance(by: 31)
        await store.refresh()
        await store.loadNextPage()

        #expect(server.requestedOffsets() == [0, 50, 0, 50], "page two must not be the pre-refresh copy")
        #expect(store.workouts.map(\.id) == Array(server.allIDs().prefix(100)))
    }

    // MARK: - Errors

    @Test("a failed page shows an error, blocks automatic retries, and recovers on retry")
    func pageErrorThenRetry() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let store = try makeStore(server)
        await store.load()
        server.failOffset(50)

        await store.loadNextPage()
        #expect(store.loadMoreError != nil)
        #expect(store.workouts.count == 50)
        #expect(!store.isLoadingMore)
        #expect(store.error == nil, "a page error must not replace the list with the full-screen banner")

        await store.loadNextPage()
        #expect(server.requestedOffsets() == [0, 50], "appear events must not hammer a failing page")

        server.failOffset(nil)
        await store.retryNextPage()
        #expect(store.loadMoreError == nil)
        #expect(store.workouts.count == 100)
        #expect(server.requestedOffsets() == [0, 50, 50])
    }

    // MARK: - A moving total

    @Test("a workout inserted between two pages neither duplicates a row nor stalls paging")
    func growingTotal() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let store = try makeStore(server)
        await store.load()
        server.insertNewest()

        var rounds = 0
        while store.hasMorePages, rounds < 30 {
            await store.loadNextPage()
            rounds += 1
        }

        // Reaching the end with total > loaded asks for page one once more,
        // which carries the new row: the header and the list agree again.
        #expect(store.meta?.total == 731)
        #expect(store.workouts.map(\.id) == server.allIDs())
        #expect(!store.hasMorePages)
        #expect(rounds == 15)
        #expect(server.requestedOffsets().last == 0)
    }

    @Test("a workout deleted from pages already passed settles at the end")
    func deletionInPassedPagesSettles() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let store = try makeStore(server)
        await store.load()
        await store.loadNextPage()
        server.remove(at: 10)

        var rounds = 0
        while store.hasMorePages, rounds < 30 {
            await store.loadNextPage()
            rounds += 1
        }

        #expect(store.meta?.total == 729)
        #expect(store.workouts.map(\.id) == server.allIDs())
        #expect(!store.workouts.contains { $0.id == "w0010" })
        #expect(!store.hasMorePages)
    }

    @Test("a total that shrank under the list ends paging instead of looping")
    func shrinkingTotal() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let store = try makeStore(server)
        await store.load()

        server.truncate(to: 60)
        await store.loadNextPage()
        #expect(store.meta?.total == 60)
        #expect(store.workouts.count == 60)

        // The total moved while paging: page one is checked once, then the
        // list is settled and asks for nothing more.
        await store.loadNextPage()
        await store.loadNextPage()
        #expect(!store.hasMorePages)
        #expect(store.workouts.map(\.id) == server.allIDs())
        #expect(server.requestedOffsets() == [0, 50, 0])
    }

    @Test("an empty page although the total promises more stops paging")
    func emptyPageStopsPaging() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let store = try makeStore(server)
        await store.load()

        server.answerEmptyPages()
        await store.loadNextPage()
        #expect(!store.hasMorePages)
        await store.loadNextPage()
        #expect(server.requestedOffsets() == [0, 50])
    }

    @Test("a page that lands after a refresh belongs to the old list and is dropped")
    func latePageAfterRefreshIsDropped() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let store = try makeStore(server)
        await store.load()

        server.holdOffset(50)
        let pending = Task { await store.loadNextPage() }
        try await server.waitUntilHeld()
        #expect(store.isLoadingMore)

        await store.refresh() // page one from the 60 s cache, no network
        server.releaseHeld()
        await pending.value

        #expect(store.workouts.count == 50)
        #expect(store.currentOffset == 50)
        #expect(!store.isLoadingMore)
    }

    // MARK: - Revalidation keeps the scrolled list

    @Test("a stale revalidation merges page one into a long list instead of truncating it")
    func revalidationMergesNewRowOnTop() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let clock = WorkoutsPagingClock()
        let store = try makeStore(server, clock: clock)
        await store.load()
        for _ in 0 ..< 3 {
            await store.loadNextPage()
        }
        #expect(store.workouts.count == 200)

        // Inside the window a re-appear is a no-op.
        await store.revalidateIfStale()
        #expect(server.requestedOffsets() == [0, 50, 100, 150])

        server.insertNewest()
        clock.advance(by: 61)
        await store.revalidateIfStale()

        #expect(store.workouts.count == 201, "the scrolled list must survive a background revalidation")
        #expect(store.workouts.map(\.id) == Array(server.allIDs().prefix(201)))
        #expect(store.meta?.total == 731)
        #expect(store.currentOffset == 201)

        await store.loadNextPage()
        #expect(server.requestedOffsets().last == 201)
        #expect(store.workouts.map(\.id) == Array(server.allIDs().prefix(251)))
    }

    @Test("a revalidation drops a workout deleted inside the page-one window and keeps the rest")
    func revalidationRemovesDeletedRow() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let clock = WorkoutsPagingClock()
        let store = try makeStore(server, clock: clock)
        await store.load()
        await store.loadNextPage()
        await store.loadNextPage()

        server.remove(at: 10)
        clock.advance(by: 61)
        await store.revalidateIfStale()

        #expect(store.workouts.map(\.id) == Array(server.allIDs().prefix(149)))
        #expect(store.meta?.total == 729)
        #expect(store.currentOffset == 149)
    }

    @Test("a change outside page one keeps every row and re-fetches the tail on the next scroll")
    func revalidationMarksTailForRefetch() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let clock = WorkoutsPagingClock()
        let store = try makeStore(server, clock: clock)
        await store.load()
        for _ in 0 ..< 3 {
            await store.loadNextPage()
        }

        // Five older workouts arrive deep in the history (a backfill).
        server.insertOlder(count: 5, at: 120)
        clock.advance(by: 61)
        await store.revalidateIfStale()

        #expect(store.workouts.count == 200, "rows are kept, not dropped")
        #expect(store.meta?.total == 735)
        #expect(store.hasMorePages)

        await store.loadNextPage()
        #expect(Array(server.requestedOffsets().dropFirst(5)) == [50, 100, 150, 200])
        #expect(store.workouts.map(\.id) == Array(server.allIDs().prefix(250)))
        #expect(store.currentOffset == 250)
    }

    @Test("logout clears paging state")
    func logoutClearsPaging() async throws {
        let server = PagedWorkoutsServer(count: 730)
        let store = try makeStore(server)
        await store.setSportType("running")
        await store.loadNextPage()

        store.clearOnLogout()

        #expect(store.workouts.isEmpty)
        #expect(store.meta == nil)
        #expect(store.currentOffset == 0)
        #expect(store.currentSportType == nil)
        #expect(!store.hasMorePages)
    }

    // MARK: - Wiring

    private func makeStore(
        _ server: PagedWorkoutsServer,
        clock: WorkoutsPagingClock = WorkoutsPagingClock()
    ) throws -> WorkoutsStore {
        MockURLProtocol.install { request in try server.respond(to: request) }
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.1",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        let repo = try WorkoutsRepository(
            api: api,
            outbox: OutboxQueue(inMemory: true),
            clock: { clock.now }
        )
        return WorkoutsStore(repo: repo, now: { clock.now })
    }
}

// MARK: - Paged fake of GET /api/workouts

/// One canonical, newest-first row set sliced by `offset`/`limit`, like the
/// server's projection. Every third workout is a run, the rest are walks, so
/// a `sportType` filter has its own total.
final class PagedWorkoutsServer: @unchecked Sendable {
    struct Request: Equatable {
        let offset: Int
        let limit: Int
        let sportType: String?
    }

    private struct Row {
        let id: String
        let sport: String
        let startedAt: Date
    }

    private let lock = NSLock()
    private var rows: [Row]
    private var log: [Request] = []
    private var failingOffset: Int?
    private var emptyPages = false
    private var heldOffset: Int?
    private var held = false
    private let release = DispatchSemaphore(value: 0)

    init(count: Int) {
        let newest = Date(timeIntervalSince1970: 1_790_000_000)
        rows = (0 ..< count).map { index in
            Row(
                id: String(format: "w%04d", index),
                sport: index % 3 == 0 ? "running" : "walking",
                startedAt: newest.addingTimeInterval(-Double(index) * 86400)
            )
        }
    }

    func allIDs(sportType: String? = nil) -> [String] {
        lock.withLock { filtered(sportType).map(\.id) }
    }

    func requests() -> [Request] {
        lock.withLock { log }
    }

    func requestedOffsets() -> [Int] {
        requests().map(\.offset)
    }

    func insertNewest() {
        lock.withLock {
            let newest = rows.first?.startedAt ?? Date(timeIntervalSince1970: 1_790_000_000)
            rows.insert(Row(id: "w-new", sport: "walking", startedAt: newest.addingTimeInterval(3600)), at: 0)
        }
    }

    func remove(at index: Int) {
        lock.withLock { _ = rows.remove(at: index) }
    }

    /// Inserts `count` workouts between the rows at `index - 1` and `index`
    /// (older than the first, newer than the second): a history backfill.
    func insertOlder(count: Int, at index: Int) {
        lock.withLock {
            let newer = rows[index - 1].startedAt
            let older = rows[index].startedAt
            let step = newer.timeIntervalSince(older) / Double(count + 1)
            let added = (1 ... count).map { offset in
                Row(id: "w-old-\(offset)", sport: "walking", startedAt: newer.addingTimeInterval(-step * Double(offset)))
            }
            rows.insert(contentsOf: added, at: index)
        }
    }

    func truncate(to count: Int) {
        lock.withLock { rows = Array(rows.prefix(count)) }
    }

    func failOffset(_ offset: Int?) {
        lock.withLock { failingOffset = offset }
    }

    /// Every later page comes back empty while `meta.total` stays as it was.
    func answerEmptyPages() {
        lock.withLock { emptyPages = true }
    }

    func holdOffset(_ offset: Int) {
        lock.withLock { heldOffset = offset }
    }

    func waitUntilHeld() async throws {
        for _ in 0 ..< 500 {
            if lock.withLock({ held }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("the held page request never reached the fake server")
    }

    func releaseHeld() {
        release.signal()
    }

    func respond(to request: URLRequest) throws -> (HTTPURLResponse, Data?) {
        guard let url = request.url else { throw URLError(.badURL) }
        guard url.path == "/api/workouts" else {
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        let entry = Request(
            offset: Int(query("offset") ?? "0") ?? 0,
            limit: Int(query("limit") ?? "50") ?? 50,
            sportType: query("sportType")
        )
        let shouldHold = lock.withLock { () -> Bool in
            log.append(entry)
            guard heldOffset == entry.offset else { return false }
            heldOffset = nil
            held = true
            return true
        }
        if shouldHold { release.wait() }
        return try lock.withLock { try page(for: entry, url: url) }
    }

    private func filtered(_ sportType: String?) -> [Row] {
        guard let sportType else { return rows }
        return rows.filter { $0.sport == sportType }
    }

    private func page(for entry: Request, url: URL) throws -> (HTTPURLResponse, Data?) {
        if failingOffset == entry.offset {
            let body = Data(#"{"data":null,"error":"bad request"}"#.utf8)
            return (HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!, body)
        }
        let all = filtered(entry.sportType)
        let slice = emptyPages ? [] : Array(all.dropFirst(entry.offset).prefix(entry.limit))
        let formatter = ISO8601DateFormatter()
        let workouts: [[String: Any]] = slice.map { row in
            [
                "id": row.id, "sportType": row.sport,
                "startedAt": formatter.string(from: row.startedAt), "endedAt": NSNull(),
                "durationSec": 1800, "distanceM": 5000, "activeEnergyKcal": 300,
                "avgHr": 140, "maxHr": 165, "source": "APPLE_HEALTH", "externalId": NSNull()
            ]
        }
        let meta: [String: Any] = [
            "total": all.count, "limit": entry.limit, "offset": entry.offset, "droppedDuplicates": 0
        ]
        let body = try JSONSerialization.data(withJSONObject: [
            "data": ["workouts": workouts, "meta": meta], "error": NSNull()
        ])
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }
}

/// Movable wall clock for the repository's 60 s SWR window.
final class WorkoutsPagingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
