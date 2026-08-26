import Foundation
@testable import HealthLog
import Synchronization
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

// One serialized fixture owns every HR-history state-machine case, so
// splitting it would weaken isolation. Since Plan 09-12 the transport is
// session-owned: each test retains its own `MockURLProtocolSession` and the
// process-global slot is never assigned here.
// swiftlint:disable file_length type_body_length

/// **GH #86** — the catch-up sweep that re-posts already-synced workouts WITH
/// their HR series.
///
/// Exercised against the real `APIClient` over a per-test
/// ``MockURLProtocolSession`` and a real `WorkoutsRepository`
/// (PROJECT_GUIDE.md: no mock server — a stubbed repository would hide exactly
/// the schema drift these tests exist to catch). HealthKit sits behind
/// ``WorkoutHRBackfillSourcing``, so no real samples are involved.
///
/// ## Issue #82 / Plan 09-12 — the transport is session-owned
///
/// Every response handler below is installed on a session this test retains,
/// and that session's configuration is what builds this test's `APIClient`.
/// No test in this file assigns `MockURLProtocol`'s process-global slot, so a
/// parallel or later suite cannot replace a handler between our install and
/// our request — the failure mode that made a handler-side counter read zero
/// for reasons unrelated to the code under test.
@Suite("Workouts — HR backfill sweep (GH #86)", .serialized)
struct WorkoutHRBackfillSweepTests {
    // MARK: - Fixtures

    /// Deterministic page producer standing in for the HealthKit walk. Records
    /// every `before` bound it was asked for, so the tests can assert the
    /// cursor really moves (and really does not, when it must not).
    private actor StubSource: WorkoutHRBackfillSourcing {
        private var outcomes: [WorkoutHRBackfillPageOutcome]
        private(set) var requestedBounds: [WorkoutHRBackfillCursor] = []

        init(pages: [WorkoutHRBackfillPage]) {
            outcomes = pages.map(WorkoutHRBackfillPageOutcome.page)
        }

        init(outcomes: [WorkoutHRBackfillPageOutcome]) {
            self.outcomes = outcomes
        }

        func page(before: WorkoutHRBackfillCursor, limit _: Int) async -> WorkoutHRBackfillPageOutcome {
            requestedBounds.append(before)
            guard !outcomes.isEmpty else { return .exhausted }
            return outcomes.removeFirst()
        }

        func bounds() -> [Date] {
            requestedBounds.map(\.startDate)
        }

        func cursors() -> [WorkoutHRBackfillCursor] {
            requestedBounds
        }
    }

    private actor BlockingSource: WorkoutHRBackfillSourcing {
        private let result: WorkoutHRBackfillPageOutcome
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        init(result: WorkoutHRBackfillPageOutcome) {
            self.result = result
        }

        func page(before _: WorkoutHRBackfillCursor, limit _: Int) async -> WorkoutHRBackfillPageOutcome {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { releaseWaiters.append($0) }
            return result
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private actor BlockingUploader: WorkoutBatchUploading {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func uploadBatch(
            _ workouts: [WorkoutIngestDTO],
            ownerUserID _: String
        ) async throws -> WorkoutBatchResponseDTO {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { releaseWaiters.append($0) }
            return WorkoutBatchResponseDTO(
                processed: workouts.count,
                inserted: workouts.count,
                duplicates: 0,
                entries: workouts.indices.map { .init(index: $0, status: .inserted) }
            )
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private final class LeaseBox: Sendable {
        private let current = Mutex(true)

        var isCurrent: Bool {
            get { current.withLock { $0 } }
            set { current.withLock { $0 = newValue } }
        }
    }

    /// Thread-safe counter for handler-side bookkeeping. The handler closure is
    /// `@Sendable` and runs on the URL-loading queue, so the count is behind a
    /// `Mutex` — checked concurrency, not a hand-written promise the compiler
    /// cannot verify. It is also owned by one session now, so nothing but that
    /// session's own requests can move it.
    private final class Counter: Sendable {
        private let count = Mutex(0)

        func bump() {
            count.withLock { $0 += 1 }
        }

        var value: Int {
            count.withLock { $0 }
        }
    }

    /// Thread-safe capture of the request bodies this test's session saw.
    private final class BodyBox: Sendable {
        private let bodies = Mutex<[Data]>([])

        func append(_ data: Data) {
            bodies.withLock { $0.append(data) }
        }

        var first: Data? {
            bodies.withLock { $0.first }
        }
    }

    /// The transport seam. Both halves come from the caller's retained session,
    /// so every request this client makes is answered by that session's handler
    /// or by nothing at all.
    ///
    /// `baseURL: session.baseURL` is the load-bearing half, and it is not
    /// interchangeable with the configuration. `APIClient.init` assigns
    /// `config.httpAdditionalHeaders` **wholesale** on the configuration object
    /// it is handed, before its `URLSession` exists, so the session token is
    /// gone by the time the first request is built. Keeping a hard-coded host
    /// here while passing `session.configuration` would leave every request
    /// untagged on a host that is not a session host — answered by the legacy
    /// process-global slot, with the nine handlers below installed and never
    /// reached. `MockURLProtocolIsolationTests.aSessionConfigurationAloneDoesNotMigrateAClient`
    /// pins exactly that trap. The address survives the constructor because it
    /// is not configuration at all.
    private static func makeAPI(session: MockURLProtocolSession) -> APIClient {
        let env = AppEnvironment(
            baseURL: session.baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: session.configuration
        )
    }

    private static func makeRepo(session: MockURLProtocolSession) throws -> WorkoutsRepository {
        try WorkoutsRepository(api: makeAPI(session: session), outbox: OutboxQueue(inMemory: true))
    }

    /// Isolated `UserDefaults` suite per test. The NAME is what the sweep's
    /// `defaultsProvider` closure captures — `UserDefaults` itself is not
    /// `Sendable`, so it is re-resolved inside the closure.
    private static func suiteName(_ label: String) -> String {
        "hl.test.hrBackfill.\(label).\(UUID().uuidString)"
    }

    private static func defaults(_ suite: String) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: suite))
    }

    private static let sessionStart = Date(timeIntervalSince1970: 1_700_000_000)

    private static func workout(_ externalId: String, start: Date) -> WorkoutIngestDTO {
        WorkoutIngestDTO(
            sportType: "running",
            startedAt: start,
            endedAt: start.addingTimeInterval(1800),
            avgHeartRate: 142,
            source: "APPLE_HEALTH",
            externalId: externalId,
            samples: [
                .init(t: start, hr: 120),
                .init(t: start.addingTimeInterval(5), hr: 131)
            ]
        )
    }

    private static func page(_ ids: [String], start: Date) -> WorkoutHRBackfillPage {
        let workouts = ids.enumerated().map { offset, id in
            workout(id, start: start.addingTimeInterval(-Double(offset) * 3600))
        }
        return WorkoutHRBackfillPage(
            workouts: workouts,
            oldestStart: workouts.map(\.startedAt).min(),
            oldestStartIdentifiers: Set(workouts.compactMap(\.externalId)),
            fetchedCount: ids.count
        )
    }

    private static func tiedPage(_ ids: [String], start: Date) -> WorkoutHRBackfillPage {
        let workouts = ids.map { workout($0, start: start) }
        return WorkoutHRBackfillPage(
            workouts: workouts,
            oldestStart: start,
            oldestStartIdentifiers: Set(ids),
            fetchedCount: ids.count
        )
    }

    /// URLProtocol moves `httpBody` onto `httpBodyStream`; re-materialize either.
    private static func body(of request: URLRequest) -> Data {
        request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var acc = Data()
            let size = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: size)
                if read <= 0 {
                    break
                }
                acc.append(buf, count: read)
            }
            return acc
        } ?? Data()
    }

    private static func respond(_ req: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
        // swiftlint:disable:next force_unwrapping
        let url = req.url!
        // swiftlint:disable:next force_unwrapping
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data(#"{"data":\#(json),"error":null}"#.utf8))
    }

    // MARK: - No server support (the headline safety property)

    @Test("without server support the sweep does no damage: one probe, no cursor move, then it rests")
    func serverWithoutEnrichmentPathIsHarmless() async throws {
        // A server that has not shipped the enrichment path answers a
        // series-bearing re-post exactly as it answers any re-post: duplicate.
        // Nothing is inserted, nothing is changed (first-write-wins), and our
        // `samples` are simply ignored.
        let suite = Self.suiteName("unsupported")
        let defaults = try Self.defaults(suite)
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try Self.makeRepo(session: session)
        let source = StubSource(pages: [
            Self.page(["w1", "w2"], start: Self.sessionStart),
            Self.page(["w3"], start: Self.sessionStart.addingTimeInterval(-86400))
        ])
        let calls = Counter()
        let bodies = BodyBox()
        session.install { req in
            guard req.targets("/api/workouts/batch", method: "POST") else {
                return Self.respond(req, "{}")
            }
            calls.bump()
            bodies.append(Self.body(of: req))
            return Self.respond(req, #"""
            {"processed":2,"inserted":0,"duplicates":2,
             "entries":[{"index":0,"status":"duplicate"},{"index":1,"status":"duplicate"}]}
            """#)
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sweep = WorkoutHRBackfillSweep(
            source: source,
            repo: repo,
            userID: "u1",
            clock: { now },
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )

        let outcome = await sweep.run()
        #expect(outcome == .serverUnsupported)
        // Exactly ONE probe — it does not keep hammering a server that cannot
        // use what we send, and it does not walk the rest of the history.
        #expect(calls.value == 1)

        let state = WorkoutHRBackfillStore.load(for: "u1", defaults: defaults)
        // Cursor untouched: when support lands, the walk resumes where it was
        // rather than having burned through the history for nothing.
        #expect(state.cursor == nil)
        #expect(!state.isDone)
        #expect(!state.serverSupportsEnrichment)
        #expect(state.lastUnsupportedProbeAt == now)

        // The one request we did make carried the series and left every
        // workout field exactly as the mapper produced it.
        let posted = try #require(bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: posted) as? [String: Any])
        let workouts = try #require(json["workouts"] as? [[String: Any]])
        #expect(workouts.count == 2)
        #expect(workouts[0]["externalId"] as? String == "w1")
        #expect(workouts[0]["avgHeartRate"] as? Int == 142)
        #expect((workouts[0]["samples"] as? [[String: Any]])?.count == 2)
        let samples = try #require(workouts[0]["samples"] as? [[String: Any]])
        #expect(Set(samples[0].keys) == Set(["t", "hr"]))
        #expect(samples[0]["hr"] as? Int == 120)
        #expect(samples[0]["t"] is String)

        // …and it rests: a second run inside the backoff makes no request.
        let second = await sweep.run()
        #expect(second == .notDue)
        #expect(calls.value == 1)
    }

    @Test("after the backoff the sweep probes again — no app update needed")
    func probesAgainAfterBackoff() throws {
        let suite = Self.suiteName("reprobe")
        let defaults = try Self.defaults(suite)
        let probedAt = Date(timeIntervalSince1970: 1_800_000_000)
        WorkoutHRBackfillStore.save(
            WorkoutHRBackfillState(lastUnsupportedProbeAt: probedAt),
            for: "u1",
            defaults: defaults
        )
        let state = WorkoutHRBackfillStore.load(for: "u1", defaults: defaults)
        #expect(!state.isDue(now: probedAt.addingTimeInterval(3600)))
        #expect(!state.isDue(now: probedAt.addingTimeInterval(23 * 3600)))
        #expect(state.isDue(now: probedAt.addingTimeInterval(24 * 3600)))
    }

    // MARK: - With server support

    @Test("`enriched` latches server support, counts progress and advances the cursor")
    func enrichedAdvancesTheWalk() async throws {
        let suite = Self.suiteName("enriched")
        let defaults = try Self.defaults(suite)
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try Self.makeRepo(session: session)
        let firstPage = Self.page(["w1", "w2"], start: Self.sessionStart)
        let source = StubSource(pages: [
            firstPage,
            WorkoutHRBackfillPage(workouts: [], oldestStart: nil, fetchedCount: 0)
        ])
        let calls = Counter()
        session.install { req in
            guard req.targets("/api/workouts/batch", method: "POST") else {
                return Self.respond(req, "{}")
            }
            calls.bump()
            return Self.respond(req, #"""
            {"processed":2,"inserted":0,"duplicates":0,
             "entries":[{"index":0,"status":"enriched"},{"index":1,"status":"enriched"}]}
            """#)
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sweep = WorkoutHRBackfillSweep(
            source: source,
            repo: repo,
            userID: "u2",
            clock: { now },
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )
        let outcome = await sweep.run(maxChunks: 2)
        // Chunk 1 enriched two entries, chunk 2 found no older history → done.
        #expect(outcome == .finished)
        #expect(calls.value == 1)

        let state = WorkoutHRBackfillStore.load(for: "u2", defaults: defaults)
        #expect(state.serverSupportsEnrichment)
        #expect(state.enrichedCount == 2)
        #expect(state.isDone)
        // The second page was requested from BEFORE the oldest workout of the
        // first page — the walk moves into the past.
        let bounds = await source.bounds()
        #expect(bounds.count == 2)
        #expect(bounds[0] == now)
        #expect(bounds[1] == firstPage.oldestStart)
        // Finished means finished: no further run, no further request.
        #expect(await sweep.run() == .notDue)
        #expect(calls.value == 1)
    }

    @Test("an all-duplicate chunk AFTER support was proven is a no-op, not a false 'unsupported'")
    func duplicateAfterSupportKeepsWalking() async throws {
        // Everything in this chunk already had a series server-side. That is a
        // legitimate no-op — the sweep must keep walking rather than conclude
        // the server lost the path.
        let suite = Self.suiteName("dupe-after-support")
        let defaults = try Self.defaults(suite)
        WorkoutHRBackfillStore.save(
            WorkoutHRBackfillState(serverSupportsEnrichment: true, enrichedCount: 7),
            for: "u3",
            defaults: defaults
        )
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try Self.makeRepo(session: session)
        let source = StubSource(pages: [Self.page(["w1"], start: Self.sessionStart)])
        session.install { req in
            guard req.targets("/api/workouts/batch", method: "POST") else {
                return Self.respond(req, "{}")
            }
            return Self.respond(req, #"""
            {"processed":1,"inserted":0,"duplicates":1,
             "entries":[{"index":0,"status":"duplicate"}]}
            """#)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sweep = WorkoutHRBackfillSweep(
            source: source,
            repo: repo,
            userID: "u3",
            clock: { now },
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )
        let outcome = await sweep.run(maxChunks: 1)
        #expect(outcome == .progressed(enriched: 0))
        let state = WorkoutHRBackfillStore.load(for: "u3", defaults: defaults)
        #expect(state.lastUnsupportedProbeAt == nil)
        #expect(state.cursor != nil)
        #expect(state.enrichedCount == 7)
    }

    @Test("a fresh insert is not mistaken for a missing enrichment path")
    func insertedIsNotUnsupported() async throws {
        // A workout the server had never seen lands as `inserted` — and its
        // series lands with it, on the first write. That is success, not the
        // all-duplicate signature of a server without the path.
        let suite = Self.suiteName("inserted")
        let defaults = try Self.defaults(suite)
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try Self.makeRepo(session: session)
        let source = StubSource(pages: [Self.page(["w1"], start: Self.sessionStart)])
        session.install { req in
            guard req.targets("/api/workouts/batch", method: "POST") else {
                return Self.respond(req, "{}")
            }
            return Self.respond(req, #"""
            {"processed":1,"inserted":1,"duplicates":0,
             "entries":[{"index":0,"status":"inserted"}]}
            """#)
        }
        let sweep = WorkoutHRBackfillSweep(
            source: source,
            repo: repo,
            userID: "u4",
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )
        #expect(await sweep.run(maxChunks: 1) == .progressed(enriched: 0))
        let state = WorkoutHRBackfillStore.load(for: "u4", defaults: defaults)
        #expect(state.lastUnsupportedProbeAt == nil)
        #expect(state.cursor != nil)
    }

    // MARK: - Progress + termination

    @Test("cancellation during a HealthKit page cannot recreate cleared old-user state")
    func cancellationDuringQueryCannotPersist() async throws {
        let suite = Self.suiteName("cancel-query")
        let defaults = try Self.defaults(suite)
        let userID = "user-query-A"
        let retained = Self.sessionStart.addingTimeInterval(3600)
        WorkoutHRBackfillStore.save(
            WorkoutHRBackfillState(
                cursor: .init(startDate: retained),
                serverSupportsEnrichment: true
            ),
            for: userID,
            defaults: defaults
        )
        let source = BlockingSource(result: .page(Self.page(["late"], start: retained)))
        let lease = LeaseBox()
        // No handler is installed: this test cancels before any upload, and a
        // request that nevertheless arrived would fail closed on its own
        // session rather than be answered by whatever a parallel suite left in
        // the global slot.
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let sweep = try WorkoutHRBackfillSweep(
            source: source,
            repo: Self.makeRepo(session: session),
            userID: userID,
            leaseIsCurrent: { lease.isCurrent },
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )

        let task = Task { await sweep.run(maxChunks: 1) }
        await source.waitUntilStarted()
        lease.isCurrent = false
        task.cancel()
        WorkoutHRBackfillStore.clear(for: userID, defaults: defaults)
        await source.release()

        #expect(await task.value == .cancelled)
        #expect(WorkoutHRBackfillStore.load(for: userID, defaults: defaults) == WorkoutHRBackfillState())
    }

    @Test("cancellation after upload starts cannot persist a cursor")
    func cancellationDuringUploadCannotPersist() async throws {
        let suite = Self.suiteName("cancel-upload")
        let defaults = try Self.defaults(suite)
        let userID = "user-upload-A"
        let lease = LeaseBox()
        let uploader = BlockingUploader()
        let sweep = WorkoutHRBackfillSweep(
            source: StubSource(pages: [Self.page(["late-upload"], start: Self.sessionStart)]),
            repo: uploader,
            userID: userID,
            leaseIsCurrent: { lease.isCurrent },
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )

        let task = Task { await sweep.run(maxChunks: 1) }
        await uploader.waitUntilStarted()
        lease.isCurrent = false
        task.cancel()
        WorkoutHRBackfillStore.clear(for: userID, defaults: defaults)
        await uploader.release()

        #expect(await task.value == .cancelled)
        #expect(WorkoutHRBackfillStore.load(for: userID, defaults: defaults) == WorkoutHRBackfillState())
    }

    @Test("more than one server page at an identical start timestamp is fully drained")
    func tiedStartBoundaryDrainsAllRows() async throws {
        let suite = Self.suiteName("tied-boundary")
        let defaults = try Self.defaults(suite)
        let tiedStart = Self.sessionStart
        let firstIDs = (0 ..< 100).map { "tie-\($0)" }
        let lastID = "tie-100"
        let source = StubSource(outcomes: [
            .page(Self.tiedPage(firstIDs, start: tiedStart)),
            .page(Self.tiedPage([lastID], start: tiedStart)),
            .exhausted
        ])
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        session.install { req in
            guard let json = try? JSONSerialization.jsonObject(with: Self.body(of: req)) as? [String: Any],
                  let workouts = json["workouts"] as? [[String: Any]] else
            {
                return Self.respond(req, "{}")
            }
            let count = workouts.count
            let entries = (0 ..< count).map {
                #"{"index":\#($0),"status":"inserted"}"#
            }.joined(separator: ",")
            return Self.respond(
                req,
                #"{"processed":\#(count),"inserted":\#(count),"duplicates":0,"entries":[\#(entries)]}"#
            )
        }
        let sweep = try WorkoutHRBackfillSweep(
            source: source,
            repo: Self.makeRepo(session: session),
            userID: "tie-user",
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )

        #expect(await sweep.run(maxChunks: 3) == .finished)
        let cursors = await source.cursors()
        #expect(cursors.count == 3)
        #expect(cursors[1].startDate == tiedStart)
        #expect(cursors[1].excludedIdentifiersAtStart == Set(firstIDs))
        #expect(cursors[2].excludedIdentifiersAtStart == Set(firstIDs + [lastID]))
        #expect(WorkoutHRBackfillStore.load(for: "tie-user", defaults: defaults).isDone)
    }

    @Test("an upload failure keeps the cursor so the next run retries the same chunk")
    func failureKeepsCursor() async throws {
        let suite = Self.suiteName("failure")
        let defaults = try Self.defaults(suite)
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try Self.makeRepo(session: session)
        let source = StubSource(pages: [Self.page(["w1"], start: Self.sessionStart)])
        let calls = Counter()
        session.install { req in
            guard req.targets("/api/workouts/batch", method: "POST") else {
                return Self.respond(req, "{}")
            }
            calls.bump()
            // swiftlint:disable:next force_unwrapping
            let response = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"data":null,"error":"boom"}"#.utf8))
        }
        let sweep = WorkoutHRBackfillSweep(
            source: source,
            repo: repo,
            userID: "u5",
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )
        #expect(await sweep.run(maxChunks: 2) == .failed)
        // `.failed` alone would not distinguish the server's 500 from a request
        // that never reached this session at all — a transport error lands on
        // the same outcome. The count is what makes the routing observable.
        //
        // The bound is `>= 1` on purpose. This endpoint is retriable, so the
        // measured value here is 4 — one attempt plus the batch request's three
        // retries — and that budget belongs to `APIClient`, not to GH #86's
        // sweep semantics. Pinning it in this file would turn a transport
        // policy change into a false failure about heart-rate backfill.
        #expect(calls.value >= 1)
        let state = WorkoutHRBackfillStore.load(for: "u5", defaults: defaults)
        #expect(state.cursor == nil)
        #expect(!state.isDone)
    }

    @Test("a HealthKit page failure retries the same cursor and then continues")
    func pageFailureRetriesSameCursor() async throws {
        let suite = Self.suiteName("page-retry")
        let defaults = try Self.defaults(suite)
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try Self.makeRepo(session: session)
        let first = Self.page(["w1"], start: Self.sessionStart)
        let second = Self.page(["w2"], start: Self.sessionStart.addingTimeInterval(-7200))
        let source = StubSource(outcomes: [
            .page(first),
            .failed(.query),
            .page(second)
        ])
        session.install { req in
            guard req.targets("/api/workouts/batch", method: "POST") else {
                return Self.respond(req, "{}")
            }
            return Self.respond(req, #"""
            {"processed":1,"inserted":0,"duplicates":0,
             "entries":[{"index":0,"status":"enriched"}]}
            """#)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sweep = WorkoutHRBackfillSweep(
            source: source,
            repo: repo,
            userID: "u-page-retry",
            clock: { now },
            maxPageRetries: 1,
            retryBackoff: { _ in },
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )

        #expect(await sweep.run(maxChunks: 2) == .progressed(enriched: 2))
        let bounds = await source.bounds()
        #expect(bounds.count == 3)
        #expect(bounds[1] == first.oldestStart)
        #expect(bounds[2] == first.oldestStart, "the retry must use the identical retained cursor")
        let state = WorkoutHRBackfillStore.load(for: "u-page-retry", defaults: defaults)
        #expect(state.cursor?.startDate == second.oldestStart)
        #expect(!state.isDone)
    }

    @Test("bounded HealthKit page failures leave the existing cursor retryable")
    func repeatedPageFailureKeepsExistingCursor() async throws {
        let suite = Self.suiteName("page-failed")
        let defaults = try Self.defaults(suite)
        let retained = Self.sessionStart
        WorkoutHRBackfillStore.save(
            WorkoutHRBackfillState(
                cursor: .init(startDate: retained),
                serverSupportsEnrichment: true
            ),
            for: "u-page-failed",
            defaults: defaults
        )
        let source = StubSource(outcomes: [.failed(.query), .failed(.query), .failed(.query)])
        // Every page fails, so nothing is ever uploaded; the session exists to
        // own the transport, not to answer anything.
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let sweep = try WorkoutHRBackfillSweep(
            source: source,
            repo: Self.makeRepo(session: session),
            userID: "u-page-failed",
            maxPageRetries: 2,
            retryBackoff: { _ in },
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )

        #expect(await sweep.run(maxChunks: 1) == .failed)
        #expect(await source.bounds() == [retained, retained, retained])
        let state = WorkoutHRBackfillStore.load(for: "u-page-failed", defaults: defaults)
        #expect(state.cursor?.startDate == retained)
        #expect(!state.isDone)
    }

    @Test("authorization pending never marks history exhausted")
    func authorizationPendingDoesNotFinish() async throws {
        let suite = Self.suiteName("auth-pending")
        let defaults = try Self.defaults(suite)
        let source = StubSource(outcomes: [.authorizationPending])
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let sweep = try WorkoutHRBackfillSweep(
            source: source,
            repo: Self.makeRepo(session: session),
            userID: "u-auth-pending",
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )

        #expect(await sweep.run() == .notDue)
        let state = WorkoutHRBackfillStore.load(for: "u-auth-pending", defaults: defaults)
        #expect(state.cursor == nil)
        #expect(!state.isDone)
    }

    @Test("a skipped server entry keeps the HR backfill cursor")
    func skippedEntryKeepsCursor() async throws {
        let suite = Self.suiteName("skipped-entry")
        let defaults = try Self.defaults(suite)
        let source = StubSource(pages: [Self.page(["w1"], start: Self.sessionStart)])
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let calls = Counter()
        session.install { req in
            guard req.targets("/api/workouts/batch", method: "POST") else {
                return Self.respond(req, "{}")
            }
            calls.bump()
            return Self.respond(req, #"""
            {"processed":1,"inserted":0,"duplicates":0,
             "entries":[{"index":0,"status":"skipped","reason":"invalid samples"}]}
            """#)
        }
        let sweep = try WorkoutHRBackfillSweep(
            source: source,
            repo: Self.makeRepo(session: session),
            userID: "u-skipped-entry",
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )

        #expect(await sweep.run(maxChunks: 1) == .failed)
        // As in `failureKeepsCursor`: the asserted `.failed` is the *server's*
        // `skipped` entry, not a request that never arrived. Only the count
        // tells those two apart.
        #expect(calls.value == 1)
        let state = WorkoutHRBackfillStore.load(for: "u-skipped-entry", defaults: defaults)
        #expect(state.cursor == nil)
        #expect(!state.isDone)
    }

    @Test("an empty first page arms a retryable cooldown instead of terminal completion")
    func emptyFirstPageArmsRetryableCooldown() async throws {
        // HealthKit answers an unauthorised query with an empty array and no
        // error (the W-B182 trap). Latching `done` there would bury the
        // backfill for anyone who grants workout read later.
        let suite = Self.suiteName("empty-first")
        let defaults = try Self.defaults(suite)
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try Self.makeRepo(session: session)
        let source = StubSource(pages: [])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sweep = WorkoutHRBackfillSweep(
            source: source,
            repo: repo,
            userID: "u6",
            clock: { now },
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )
        #expect(await sweep.run() == .finished)
        let state = WorkoutHRBackfillStore.load(for: "u6", defaults: defaults)
        #expect(state.isDone)
        #expect(state.nextExhaustionProbeAt == now.addingTimeInterval(WorkoutHRBackfillState.exhaustionProbeBackoff))
        #expect(state.cursor == nil)
        #expect(!state.isDue(now: now))
        #expect(try state.isDue(now: #require(state.nextExhaustionProbeAt)))
    }

    @Test("a page with nothing to enrich still advances — no series, no request")
    func pageWithoutSeriesAdvancesWithoutPosting() async throws {
        let suite = Self.suiteName("no-series")
        let defaults = try Self.defaults(suite)
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try Self.makeRepo(session: session)
        let oldest = Self.sessionStart.addingTimeInterval(-7200)
        let source = StubSource(pages: [
            // HealthKit had workouts here, but none carried a usable HR series
            // (manual entries / no sensor) — nothing to post.
            WorkoutHRBackfillPage(workouts: [], oldestStart: oldest, fetchedCount: 3),
            WorkoutHRBackfillPage(workouts: [], oldestStart: nil, fetchedCount: 0)
        ])
        let calls = Counter()
        session.install { req in
            if req.targets("/api/workouts/batch", method: "POST") {
                calls.bump()
            }
            return Self.respond(req, "{}")
        }
        let sweep = WorkoutHRBackfillSweep(
            source: source,
            repo: repo,
            userID: "u7",
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            // swiftlint:disable:next force_unwrapping
            defaultsProvider: { UserDefaults(suiteName: suite)! }
        )
        #expect(await sweep.run(maxChunks: 2) == .finished)
        // A zero here is a genuine negative — the sweep posts nothing — and it
        // is therefore the one count in this file that cannot double as routing
        // evidence: an unrouted request would also leave it at zero. That
        // property is carried by `aLaterInstallCannotAnswerThisSuite`, which
        // asserts a *positive* count on this suite's own session.
        #expect(calls.value == 0)
        #expect(WorkoutHRBackfillStore.load(for: "u7", defaults: defaults).isDone)
    }

    @Test("authorization-ambiguous empty series retains cursor and arms the shared cooldown")
    func ambiguousEmptySeriesUsesSharedCooldown() async throws {
        let suite = Self.suiteName("ambiguous-empty-series")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cursor = WorkoutHRBackfillCursor(startDate: now.addingTimeInterval(-60))
        WorkoutHRBackfillStore.save(
            WorkoutHRBackfillState(cursor: cursor, serverSupportsEnrichment: true),
            for: "user-empty",
            defaults: defaults
        )
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let sweep = try WorkoutHRBackfillSweep(
            source: StubSource(outcomes: [.seriesEmpty]),
            repo: Self.makeRepo(session: session),
            userID: "user-empty",
            clock: { now },
            defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
        )

        #expect(await sweep.run(maxChunks: 1) == .finished)
        let state = WorkoutHRBackfillStore.load(for: "user-empty", defaults: defaults)
        #expect(state.cursor == cursor)
        #expect(state.isDone)
        #expect(state.nextExhaustionProbeAt == now.addingTimeInterval(WorkoutHRBackfillState.exhaustionProbeBackoff))
    }

    // MARK: - Transport ownership (issue #82 / Plan 09-12)

    @Test("a handler installed after ours cannot answer this suite's request")
    func aLaterInstallCannotAnswerThisSuite() async throws {
        // The failure this migration removes: a suite running in parallel
        // replaces the handler between our install and our request, so our
        // request is answered by a foreign closure, our counter stays at zero
        // and the assertion fails for a reason unrelated to the sweep. Here the
        // foreign install happens *after* ours — deterministically the losing
        // order under one process-global slot — and must still not be reached.
        let suite = Self.suiteName("session-owned")
        let session = MockURLProtocolSession()
        let foreign = MockURLProtocolSession()
        defer {
            session.invalidate()
            foreign.invalidate()
        }
        let mine = Counter()
        let theirs = Counter()
        session.install { req in
            guard req.targets("/api/workouts/batch", method: "POST") else {
                return Self.respond(req, "{}")
            }
            mine.bump()
            return Self.respond(req, #"""
            {"processed":1,"inserted":0,"duplicates":0,
             "entries":[{"index":0,"status":"enriched"}]}
            """#)
        }
        foreign.install { req in
            theirs.bump()
            return Self.respond(req, "{}")
        }

        let sweep = try WorkoutHRBackfillSweep(
            source: StubSource(pages: [Self.page(["w1"], start: Self.sessionStart)]),
            repo: Self.makeRepo(session: session),
            userID: "u-session-owned",
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            defaultsProvider: { UserDefaults(suiteName: suite) ?? .standard }
        )
        _ = await sweep.run(maxChunks: 1)

        #expect(mine.value == 1)
        #expect(theirs.value == 0)
    }
}

/// Pure state / persistence half of the GH #86 backfill: the progression
/// decisions the sweep makes are value-type logic, testable without a server,
/// without HealthKit and without UserDefaults ceremony.
@Suite("Workouts — HR backfill state (GH #86)")
struct WorkoutHRBackfillStateTests {
    private static let sessionStart = Date(timeIntervalSince1970: 1_700_000_000)

    private static func defaults(_ label: String) throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "hl.test.hrBackfillState.\(label).\(UUID().uuidString)"))
    }

    @Test("the composite cursor advances dates and accumulates equal-start ties")
    func cursorIsTieSafe() {
        let cursor = Self.sessionStart
        let older = cursor.addingTimeInterval(-3600)
        let initial = WorkoutHRBackfillCursor(startDate: cursor)
        #expect(
            WorkoutHRBackfillState.nextCursor(
                after: initial,
                oldestStart: older,
                oldestStartIdentifiers: ["older"]
            ) == WorkoutHRBackfillCursor(
                startDate: older,
                excludedIdentifiersAtStart: ["older"]
            )
        )
        #expect(
            WorkoutHRBackfillState.nextCursor(
                after: initial,
                oldestStart: cursor,
                oldestStartIdentifiers: ["tie-a"]
            ) == WorkoutHRBackfillCursor(
                startDate: cursor,
                excludedIdentifiersAtStart: ["tie-a"]
            )
        )
    }

    @Test("state round-trips through UserDefaults and is user-partitioned")
    func statePersistsPerUser() throws {
        let defaults = try Self.defaults("partition")
        let stamp = Date(timeIntervalSince1970: 1_777_000_000)
        WorkoutHRBackfillStore.save(
            WorkoutHRBackfillState(
                cursor: .init(startDate: stamp, excludedIdentifiersAtStart: ["boundary"]),
                serverSupportsEnrichment: true,
                enrichedCount: 12
            ),
            for: "userA",
            defaults: defaults
        )
        let loaded = WorkoutHRBackfillStore.load(for: "userA", defaults: defaults)
        #expect(loaded.cursor?.startDate == stamp)
        #expect(loaded.cursor?.excludedIdentifiersAtStart == ["boundary"])
        #expect(loaded.serverSupportsEnrichment)
        #expect(loaded.enrichedCount == 12)
        // A different account sees a fresh walk, not userA's progress.
        #expect(WorkoutHRBackfillStore.load(for: "userB", defaults: defaults).cursor == nil)
        // Logout clears it.
        WorkoutHRBackfillStore.clear(for: "userA", defaults: defaults)
        #expect(WorkoutHRBackfillStore.load(for: "userA", defaults: defaults).cursor == nil)
    }

    @Test("a corrupt state blob reads as a fresh walk, never as 'finished'")
    func corruptStateIsNotDone() throws {
        let defaults = try Self.defaults("corrupt")
        defaults.set(Data("not-json".utf8), forKey: WorkoutHRBackfillStore.key(for: "u8"))
        let state = WorkoutHRBackfillStore.load(for: "u8", defaults: defaults)
        #expect(!state.isDone)
        #expect(state.cursor == nil)
        #expect(state.isDue(now: Date()))
    }

    @Test("a legacy date-only cursor restarts safely instead of skipping timestamp ties")
    func legacyDateCursorRestarts() throws {
        struct LegacyState: Encodable {
            let cursor: Date
            let isDone: Bool
            let serverSupportsEnrichment: Bool
            let enrichedCount: Int
        }

        let data = try JSONEncoder().encode(LegacyState(
            cursor: Self.sessionStart,
            isDone: true,
            serverSupportsEnrichment: true,
            enrichedCount: 9
        ))
        let state = try JSONDecoder().decode(WorkoutHRBackfillState.self, from: data)

        #expect(state.cursor == nil)
        #expect(!state.isDone)
        #expect(state.serverSupportsEnrichment)
        #expect(state.enrichedCount == 9)
    }

    @Test("an exhaustion candidate sleeps only until its persisted deadline")
    func exhaustionCandidateIsRetryable() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = now.addingTimeInterval(3600)
        let state = WorkoutHRBackfillState(isDone: true, nextExhaustionProbeAt: deadline)
        #expect(!state.isDue(now: now))
        #expect(state.isDue(now: deadline))
        #expect(WorkoutHRBackfillState().isDue(now: Date()))
    }

    @Test("a legacy composite terminal blob restarts newest-first immediately")
    func legacyTerminalRestartsNewestFirst() throws {
        struct LegacyState: Encodable {
            let cursor: WorkoutHRBackfillCursor
            let isDone: Bool
            let serverSupportsEnrichment: Bool
        }

        let data = try JSONEncoder().encode(LegacyState(
            cursor: WorkoutHRBackfillCursor(startDate: Self.sessionStart),
            isDone: true,
            serverSupportsEnrichment: true
        ))
        let state = try JSONDecoder().decode(WorkoutHRBackfillState.self, from: data)
        #expect(state.cursor == nil)
        #expect(!state.isDone)
        #expect(state.nextExhaustionProbeAt == nil)
        #expect(state.isDue(now: Date()))
    }

    @Test("rearm retains an active cursor but resets a cooling walk newest-first")
    func rearmTriggerIsStarvationSafe() throws {
        let defaults = try Self.defaults("rearm")
        let activeCursor = WorkoutHRBackfillCursor(startDate: Self.sessionStart)
        WorkoutHRBackfillStore.save(
            WorkoutHRBackfillState(cursor: activeCursor, serverSupportsEnrichment: true),
            for: "active",
            defaults: defaults
        )
        #expect(WorkoutHRBackfillStore.rearm(
            for: "active",
            trigger: .acceptedSeriesOmission,
            defaults: defaults
        ))
        let active = WorkoutHRBackfillStore.load(for: "active", defaults: defaults)
        #expect(active.cursor == activeCursor)
        #expect(active.restartFromNewestAfterCurrentWalk)

        WorkoutHRBackfillStore.save(
            WorkoutHRBackfillState(
                cursor: activeCursor,
                isDone: true,
                nextExhaustionProbeAt: Date().addingTimeInterval(3600),
                serverSupportsEnrichment: true
            ),
            for: "cooling",
            defaults: defaults
        )
        #expect(WorkoutHRBackfillStore.rearm(
            for: "cooling",
            trigger: .acceptedSeriesOmission,
            defaults: defaults
        ))
        let cooling = WorkoutHRBackfillStore.load(for: "cooling", defaults: defaults)
        #expect(cooling.cursor == nil)
        #expect(!cooling.isDone)
        #expect(!cooling.restartFromNewestAfterCurrentWalk)
    }
}

#if canImport(HealthKit)
    /// Exercises the exact boundary/window helpers used by the live
    /// `HealthKitWorkoutHistorySource`, while replacing only Apple's opaque
    /// query execution. This catches the production `< end` semantics that a
    /// hand-fed `WorkoutHRBackfillSourcing` stub cannot model.
    @Suite("Workouts — HealthKit history source boundary semantics")
    struct HealthKitWorkoutHistorySourceSemanticsTests {
        private struct Row: Sendable, Equatable {
            let id: String
            let startDate: Date
        }

        @Test("101 equal timestamps plus an older row are drained by finite pages")
        func drainsTimestampTieAcrossPages() {
            let tiedStart = Date(timeIntervalSince1970: 1_700_000_000)
            let olderStart = tiedStart.addingTimeInterval(-1)
            let tiedRows = (0 ... 100).map { Row(id: "tie-\($0)", startDate: tiedStart) }
            let rows = tiedRows + [Row(id: "older", startDate: olderStart)]
            var cursor = WorkoutHRBackfillCursor(startDate: tiedStart)
            var seen: Set<String> = []
            var queryLimits: [Int] = []

            for _ in 0 ..< 4 {
                let queryEnd = HealthKitWorkoutHistorySource.inclusiveQueryEnd(for: cursor.startDate)
                let queryLimit = HealthKitWorkoutHistorySource.finiteQueryLimit(
                    pageLimit: 100,
                    excludedCount: cursor.excludedIdentifiersAtStart.count
                )
                queryLimits.append(queryLimit)

                // `strictStartDate` applies an exclusive `< end` bound. Keep
                // this simulator deliberately literal so using `cursor.startDate`
                // as the end would make all 101 boundary rows disappear.
                let healthKitPage = rows
                    .filter { $0.startDate < queryEnd }
                    .sorted {
                        if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
                        return $0.id < $1.id
                    }
                    .prefix(queryLimit)
                let selected = HealthKitWorkoutHistorySource.selectPage(
                    from: Array(healthKitPage),
                    cursor: cursor,
                    limit: 100,
                    startDate: \Row.startDate,
                    identifier: \Row.id
                )
                guard !selected.isEmpty else { break }

                seen.formUnion(selected.map(\.id))
                let oldest = selected.map(\.startDate).min()
                let oldestIDs = Set(selected.compactMap { row in
                    row.startDate == oldest ? row.id : nil
                })
                cursor = WorkoutHRBackfillState.nextCursor(
                    after: cursor,
                    oldestStart: oldest,
                    oldestStartIdentifiers: oldestIDs
                )
            }

            #expect(seen == Set(rows.map(\.id)))
            #expect(Array(queryLimits.prefix(3)) == [100, 200, 101])
            #expect(queryLimits.allSatisfy { $0 > 0 && $0 != HKObjectQueryNoLimit })
        }
    }
#endif
