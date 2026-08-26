import Foundation
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping

/// Drives ``NutrientDailySyncCoordinator`` over the **real** ``APIClient`` +
/// `MockURLProtocol` (per PROJECT_GUIDE.md), covering the GH #48 contract: batch
/// payload shape + Idempotency-Key header, upsert `updated` status, per-entry
/// skip handling, module-disabled 403 → stop, module-off gate, and day-key
/// pass-through / timezone correctness.
///
/// `.serialized` — the suite installs a process-global `MockURLProtocol.handler`.
@Suite("NutrientDailySyncCoordinator — sync + batch contract", .serialized)
struct NutrientDailySyncCoordinatorTests {
    // MARK: - Fixtures

    private func makeClient(token: String? = "bearer-abc") -> (APIClient, InMemoryKeychain) {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        if let token { try? kc.setString(token, forKey: KeychainKey.authToken) }
        try? kc.setString("user-123", forKey: KeychainKey.userID)
        return (APIClient(environment: env, keychain: kc, sessionConfiguration: .mock()), kc)
    }

    private func isolatedDefaults() -> @Sendable () -> UserDefaults {
        let suite = "nutrient.tests.\(UUID().uuidString)"
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        // Capture the Sendable suite name, not the UserDefaults instance; the suite
        // resolves to the same shared store on each call.
        return { UserDefaults(suiteName: suite)! }
    }

    /// Fixed "now" all coordinators in this suite run against.
    private static let fixedNow = Date(timeIntervalSince1970: 1_783_000_000)

    private func makeCoordinator(
        api: APIClientProtocol,
        keychain: InMemoryKeychain,
        rows: FakeNutrientRows,
        moduleEnabled: Bool = true,
        defaultsProvider: (@Sendable () -> UserDefaults)? = nil
    ) -> NutrientDailySyncCoordinator {
        NutrientDailySyncCoordinator(
            statisticsService: rows,
            api: api,
            keychain: keychain,
            isModuleEnabled: { moduleEnabled },
            calendar: .current,
            clock: { Self.fixedNow },
            defaultsProvider: defaultsProvider ?? isolatedDefaults()
        )
    }

    /// Whole days between the queried `from` and the fixed clock — the lookback
    /// window the run actually asked HealthKit for.
    private func lookbackDays(for from: Date) -> Int {
        Calendar.current.dateComponents([.day], from: from, to: Self.fixedNow).day ?? -1
    }

    // MARK: - Payload shape + idempotency

    @Test("POSTs /api/nutrients/batch with { day, nutrient, unit, amount } + Idempotency-Key")
    func batchPayloadShapeAndIdempotency() async throws {
        let (api, kc) = makeClient()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let n = recorder.decodeLastBody()?.entries.count ?? 0
            let entries = (0 ..< n).map { #"{ "index": \#($0), "status": "inserted" }"# }.joined(separator: ",")
            let json = #"{"data":{"processed":\#(n),"inserted":\#(n),"updated":0,"skipped":[],"entries":[\#(entries)]},"error":null}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let rows = FakeNutrientRows(byIdentifier: [
            "HKQuantityTypeIdentifierDietaryVitaminC": [row(day: "2026-07-06", value: 88)],
            "HKQuantityTypeIdentifierDietaryWater": [row(day: "2026-07-06", value: 1500)]
        ])
        let coordinator = makeCoordinator(api: api, keychain: kc, rows: rows)

        let summary = await coordinator.sync()

        #expect(recorder.requestCount == 1)
        #expect(recorder.lastPath == "/api/nutrients/batch")
        let idem = try #require(recorder.lastIdempotencyKey, "POST must carry an Idempotency-Key")
        #expect(!idem.isEmpty)
        let payload = try #require(recorder.decodeLastBody())
        #expect(payload.entries.count == 2)
        let vitC = try #require(payload.entries.first { $0.nutrient == .vitaminC })
        #expect(vitC.day == "2026-07-06")
        #expect(vitC.unit == "mg")
        #expect(vitC.amount == 88)
        let water = try #require(payload.entries.first { $0.nutrient == .water })
        #expect(water.unit == "ml")
        #expect(water.amount == 1500)
        #expect(summary.inserted == 2)
    }

    // MARK: - Upsert / updated

    @Test("Server 'updated' status is tallied (re-post replaces, no duplicate)")
    func updatedStatusTallied() async {
        let (api, kc) = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"processed":1,"inserted":0,"updated":1,"skipped":[],"entries":[{"index":0,"status":"updated"}]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let rows = FakeNutrientRows(byIdentifier: [
            "HKQuantityTypeIdentifierDietaryCalcium": [row(day: "2026-07-06", value: 1000)]
        ])
        let coordinator = makeCoordinator(api: api, keychain: kc, rows: rows)
        let summary = await coordinator.sync()
        #expect(summary.updated == 1)
        #expect(summary.inserted == 0)
        #expect(summary.totalUpserted == 1)
    }

    // MARK: - Skip handling

    @Test("Per-entry skipped rows are tallied + dropped (not retried)")
    func skipHandling() async {
        let (api, kc) = makeClient()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let body = Data(#"""
            {"data":{"processed":2,"inserted":1,"updated":0,
            "skipped":[{"index":1,"reason":"value_out_of_range"}],
            "entries":[{"index":0,"status":"inserted"},
            {"index":1,"status":"skipped","reason":"value_out_of_range"}]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let rows = FakeNutrientRows(byIdentifier: [
            "HKQuantityTypeIdentifierDietaryIron": [row(day: "2026-07-06", value: 8)],
            "HKQuantityTypeIdentifierDietaryZinc": [row(day: "2026-07-06", value: 999_999)]
        ])
        let coordinator = makeCoordinator(api: api, keychain: kc, rows: rows)
        let summary = await coordinator.sync()
        #expect(summary.inserted == 1)
        #expect(summary.skipped == 1)
        #expect(summary.failedBatches == 0)
        // Terminal — a skip does NOT trigger a retry POST.
        #expect(recorder.requestCount == 1)
    }

    // MARK: - Module disabled 403 → stop

    @Test("403 module.disabled stops the sync — no retry, no further chunks")
    func moduleDisabledStops() async {
        let (api, kc) = makeClient()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let body = Data(#"""
            {"data":null,"error":"Nutrients module is disabled","meta":{"errorCode":"module.disabled","module":"nutrients"}}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        // 600 rows on one nutrient → two 500-cap chunks. The 403 on the FIRST
        // chunk must stop the run so the second chunk never fires.
        let manyRows = (0 ..< 600).map { row(day: "2026-\(String(format: "%02d", ($0 % 12) + 1))-01", value: Double($0 + 1)) }
        let rows = FakeNutrientRows(byIdentifier: [
            "HKQuantityTypeIdentifierDietaryVitaminC": manyRows
        ])
        let coordinator = makeCoordinator(api: api, keychain: kc, rows: rows)
        let summary = await coordinator.sync()
        #expect(recorder.requestCount == 1, "must STOP after the 403 — the second chunk must not POST")
        #expect(summary.inserted == 0)
        #expect(summary.updated == 0)
    }

    // MARK: - Gates

    @Test("Module OFF short-circuits before any HK query or POST")
    func moduleOffGate() async {
        let (api, kc) = makeClient()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let rows = FakeNutrientRows(byIdentifier: [
            "HKQuantityTypeIdentifierDietaryVitaminC": [row(day: "2026-07-06", value: 88)]
        ])
        let coordinator = makeCoordinator(api: api, keychain: kc, rows: rows, moduleEnabled: false)
        let summary = await coordinator.sync()
        #expect(summary == .zero)
        #expect(recorder.requestCount == 0)
        #expect(rows.queryCount == 0, "no HK query when the module is off (no read-auth prompt)")
    }

    @Test("No auth token short-circuits (pre-login)")
    func noTokenGate() async {
        let (api, kc) = makeClient(token: nil)
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let rows = FakeNutrientRows(byIdentifier: [
            "HKQuantityTypeIdentifierDietaryVitaminC": [row(day: "2026-07-06", value: 88)]
        ])
        let coordinator = makeCoordinator(api: api, keychain: kc, rows: rows)
        let summary = await coordinator.sync()
        #expect(summary == .zero)
        #expect(recorder.requestCount == 0)
    }

    @Test("day-key from the HK row is passed through unchanged to entry.day")
    func dayKeyPassThrough() async throws {
        let (api, kc) = makeClient()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let body = Data(#"""
            {"data":{"processed":1,"inserted":1,"updated":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let rows = FakeNutrientRows(byIdentifier: [
            "HKQuantityTypeIdentifierDietaryVitaminD": [row(day: "2025-12-31", value: 15)]
        ])
        let coordinator = makeCoordinator(api: api, keychain: kc, rows: rows)
        _ = await coordinator.sync()
        let payload = try #require(recorder.decodeLastBody())
        #expect(payload.entries.first?.day == "2025-12-31")
    }

    // MARK: - First-enable backfill window

    @Test("First enable asks for 30 days; a landed run switches later runs to the incremental window")
    func backfillNarrowsOnlyAfterUpload() async throws {
        let (api, kc) = makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"processed":1,"inserted":1,"updated":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let rows = FakeNutrientRows(byIdentifier: [
            "HKQuantityTypeIdentifierDietaryVitaminC": [row(day: "2026-07-06", value: 88)]
        ])
        let defaults = isolatedDefaults()
        let coordinator = makeCoordinator(api: api, keychain: kc, rows: rows, defaultsProvider: defaults)

        _ = await coordinator.sync()
        let firstWindow = try #require(rows.lastFrom)
        #expect(lookbackDays(for: firstWindow) == 30, "first enable backfills 30 days")

        _ = await coordinator.sync()
        let secondWindow = try #require(rows.lastFrom)
        #expect(lookbackDays(for: secondWindow) == 1, "later runs post current + previous day")
    }

    @Test("An empty window keeps the 30-day backfill armed (no-data and read-denied are indistinguishable)")
    func emptyWindowKeepsBackfillArmed() async throws {
        let (api, kc) = makeClient()
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let body = Data(#"""
            {"data":{"processed":1,"inserted":1,"updated":0,"skipped":[],"entries":[{"index":0,"status":"inserted"}]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let defaults = isolatedDefaults()
        // Run 1 — HealthKit answers empty. That is what a DENIED read looks
        // like too, so the one-shot must not be burned.
        let denied = FakeNutrientRows(byIdentifier: [:])
        _ = await makeCoordinator(api: api, keychain: kc, rows: denied, defaultsProvider: defaults).sync()
        #expect(recorder.requestCount == 0, "nothing to post")
        let deniedWindow = try #require(denied.lastFrom)
        #expect(lookbackDays(for: deniedWindow) == 30)

        // Run 2 — permission granted later in Settings → Health: the full
        // 30-day history must still be asked for and uploaded.
        let granted = FakeNutrientRows(byIdentifier: [
            "HKQuantityTypeIdentifierDietaryVitaminC": [row(day: "2026-06-20", value: 88)]
        ])
        let summary = await makeCoordinator(api: api, keychain: kc, rows: granted, defaultsProvider: defaults).sync()
        let grantedWindow = try #require(granted.lastFrom)
        #expect(lookbackDays(for: grantedWindow) == 30, "backfill was still armed")
        #expect(summary.inserted == 1)
    }

    // MARK: - Helpers

    private func row(day: String, value: Double) -> HealthKitDailyStatRow {
        HealthKitDailyStatRow(
            hkIdentifier: "ignored",
            dayStart: Date(timeIntervalSince1970: 0),
            dayKey: day,
            value: value,
            unit: "ignored"
        )
    }
}

#if canImport(HealthKit)

    /// Locks the user-timezone `yyyy-MM-dd` day-key rule the coordinator relies on
    /// (same rule as the `stats:` measurement keys).
    @Suite("Nutrient day-key timezone correctness")
    struct NutrientDayKeyTests {
        @Test("dayKey uses the calendar's timezone, not UTC (Berlin near midnight)")
        func berlinDayKey() throws {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
            // 2026-07-07 23:30 UTC == 2026-07-08 01:30 Berlin (CEST, +02:00).
            let instant = Date(timeIntervalSince1970: 1_783_467_000)
            #expect(HealthKitStatisticsService.dayKey(for: instant, calendar: cal) == "2026-07-08")

            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = try #require(TimeZone(identifier: "UTC"))
            #expect(HealthKitStatisticsService.dayKey(for: instant, calendar: utc) == "2026-07-07")
        }
    }

#endif

// MARK: - Test doubles

/// Fake ``NutrientDailyRowsProviding`` returning canned rows per HK identifier.
private final class FakeNutrientRows: NutrientDailyRowsProviding, @unchecked Sendable {
    private let byIdentifier: [String: [HealthKitDailyStatRow]]
    private let queryCountLock = OSAllocatedUnfairLock(initialState: 0)
    private let lastFromLock = OSAllocatedUnfairLock<Date?>(initialState: nil)

    var queryCount: Int {
        queryCountLock.withLock { $0 }
    }

    /// Window start the coordinator last asked for — lets a test read back the
    /// lookback span (30-day backfill vs. incremental).
    var lastFrom: Date? {
        lastFromLock.withLock { $0 }
    }

    init(byIdentifier: [String: [HealthKitDailyStatRow]]) {
        self.byIdentifier = byIdentifier
    }

    func dailyRows(
        forNutrientIdentifier identifier: String,
        wireUnit: String,
        from: Date,
        to _: Date
    ) async throws -> [HealthKitDailyStatRow] {
        queryCountLock.withLock { $0 += 1 }
        lastFromLock.withLock { $0 = from }
        // Re-stamp the row's unit to the caller's wire unit so the coordinator's
        // pass-through is exercised with the catalog unit.
        return (byIdentifier[identifier] ?? []).map {
            HealthKitDailyStatRow(
                hkIdentifier: identifier,
                dayStart: $0.dayStart,
                dayKey: $0.dayKey,
                value: $0.value,
                unit: wireUnit
            )
        }
    }
}

/// Records requests seen by `MockURLProtocol` for assertion. `@unchecked
/// Sendable` behind a lock — the handler is a `@Sendable` global closure.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var bodies: [Data] = []

    func record(_ req: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(req)
        bodies.append(Self.body(req) ?? Data())
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var lastPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last?.url?.path
    }

    var lastIdempotencyKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last?.value(forHTTPHeaderField: "Idempotency-Key")
    }

    func decodeLastBody() -> NutrientBatchRequestDTO? {
        lock.lock()
        let data = bodies.last
        lock.unlock()
        guard let data else { return nil }
        return try? JSONDecoder().decode(NutrientBatchRequestDTO.self, from: data)
    }

    /// URLSession moves `httpBody` onto `httpBodyStream` — read either.
    private static func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// swiftlint:enable force_unwrapping
