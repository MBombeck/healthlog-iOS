import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Drives ``NutrientReadRepository`` over the **real** ``APIClient`` +
/// `MockURLProtocol` (per PROJECT_GUIDE.md — no mock server), covering the GH #48 read
/// contract: `GET /api/nutrients` window read, `GET /api/nutrients/daily` series
/// read, the `POST /api/nutrients/water` body + Idempotency-Key, and the
/// outbox-durability path (a retriable failure queues the water quick-add for
/// replay under the same key).
///
/// `.serialized` — the suite installs a process-global `MockURLProtocol.handler`.
@Suite("NutrientReadRepository — read + water quick-add contract", .serialized)
struct NutrientReadRepositoryTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("bearer-abc", forKey: KeychainKey.authToken)
        try? kc.setString("user-123", forKey: KeychainKey.userID)
        return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
    }

    private func makeRepo(api: APIClientProtocol) throws -> (NutrientReadRepository, OutboxQueue) {
        let outbox = try OutboxQueue(inMemory: true)
        return (NutrientReadRepository(api: api, outbox: outbox), outbox)
    }

    private nonisolated static func ok(_ dataJSON: String, url: URL) -> (HTTPURLResponse, Data?) {
        let body = #"{"data":\#(dataJSON),"error":null}"#
        return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    // MARK: - Reads

    @Test("overview() GETs /api/nutrients with the days window")
    func overviewRead() async throws {
        let api = makeClient()
        let (repo, _) = try makeRepo(api: api)
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let rows = #"{"nutrient":"water","unit":"ml","latestDay":"2026-07-06","latestAmount":1500,"daysWithData":3}"#
            return Self.ok(#"{"windowDays":14,"nutrients":[\#(rows)]}"#, url: req.url!)
        }

        let overview = try await repo.overview(days: 14)

        #expect(recorder.lastPath == "/api/nutrients")
        #expect(recorder.lastQuery?.contains("days=14") == true)
        #expect(overview.windowDays == 14)
        #expect(overview.nutrients.first?.nutrient == .water)
        #expect(overview.nutrients.first?.latestAmount == 1500)
    }

    @Test("dailySeries() GETs /api/nutrients/daily with nutrient + days")
    func dailyRead() async throws {
        let api = makeClient()
        let (repo, _) = try makeRepo(api: api)
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            let days = #"[{"day":"2026-07-05","amount":0},{"day":"2026-07-06","amount":88}]"#
            let ref = #"{"kind":"PRI","direction":"target","value":95,"source":"EFSA DRV 2013 (adults)"}"#
            return Self.ok(#"{"nutrient":"vitamin_c","unit":"mg","windowDays":7,"days":\#(days),"reference":\#(ref)}"#, url: req.url!)
        }

        let series = try await repo.dailySeries(nutrient: .vitaminC, days: 7)

        #expect(recorder.lastPath == "/api/nutrients/daily")
        #expect(recorder.lastQuery?.contains("nutrient=vitamin_c") == true)
        #expect(recorder.lastQuery?.contains("days=7") == true)
        #expect(series.reference?.value == 95)
        #expect(series.latestNonEmptyDay?.amount == 88)
    }

    // MARK: - Water quick-add

    @Test("quickAddWater POSTs /api/nutrients/water with add body + Idempotency-Key")
    func waterAddBody() async throws {
        let api = makeClient()
        let (repo, _) = try makeRepo(api: api)
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return Self.ok(
                #"{"day":"2026-07-06","nutrient":"water","source":"MANUAL","amount":300,"unit":"ml"}"#,
                url: req.url!
            )
        }

        let row = try await repo.quickAddWater(amountMl: 300, mode: .add)

        #expect(recorder.requestCount == 1)
        #expect(recorder.lastPath == "/api/nutrients/water")
        #expect(recorder.lastMethod == "POST")
        let idem = try #require(recorder.lastIdempotencyKey, "POST must carry an Idempotency-Key")
        #expect(!idem.isEmpty)
        let body = try #require(recorder.decodeLastWaterBody())
        #expect(body.amountMl == 300)
        #expect(body.mode == .add)
        #expect(body.day == nil)
        #expect(row.source == "MANUAL")
    }

    @Test("A retriable failure queues the water quick-add to the outbox and re-throws")
    func waterFailureQueues() async throws {
        let api = makeClient()
        let (repo, outbox) = try makeRepo(api: api)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }

        await #expect(throws: (any Error).self) {
            _ = try await repo.quickAddWater(amountMl: 500, mode: .add)
        }

        let queued = await outbox.snapshot
        let waterOps = queued.filter { $0.kind == .logNutrientWater }
        #expect(waterOps.count == 1, "the failed quick-add is durably queued")
        let op = try #require(waterOps.first)
        let payload = try JSONDecoder.hlDefault.decode(OutboxQueue.Payloads.LogNutrientWater.self, from: op.payload)
        #expect(payload.body.amountMl == 500)
        #expect(payload.body.mode == .add)
    }

    @Test("replayWaterQuickAdd re-issues the POST under the persisted idempotency key")
    func waterReplayReusesKey() async throws {
        let api = makeClient()
        let (repo, _) = try makeRepo(api: api)
        let recorder = RequestRecorder()
        MockURLProtocol.handler = { req in
            recorder.record(req)
            return Self.ok(
                #"{"day":"2026-07-06","nutrient":"water","source":"MANUAL","amount":700,"unit":"ml"}"#,
                url: req.url!
            )
        }

        let body = NutrientWaterWriteRequestDTO(amountMl: 200, mode: .add, day: "2026-07-06")
        _ = try await repo.replayWaterQuickAdd(body, idempotencyKey: "persisted-key-xyz")

        #expect(recorder.lastPath == "/api/nutrients/water")
        #expect(recorder.lastIdempotencyKey == "persisted-key-xyz", "replay reuses the persisted key")
    }
}

/// Records requests + bodies off the `@Sendable` handler (thread-safe).
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

    var lastQuery: String? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last?.url?.query
    }

    var lastMethod: String? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last?.httpMethod
    }

    var lastIdempotencyKey: String? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last?.value(forHTTPHeaderField: "Idempotency-Key")
    }

    func decodeLastWaterBody() -> NutrientWaterWriteRequestDTO? {
        lock.lock()
        let data = bodies.last
        lock.unlock()
        guard let data else { return nil }
        return try? JSONDecoder.hlDefault.decode(NutrientWaterWriteRequestDTO.self, from: data)
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
