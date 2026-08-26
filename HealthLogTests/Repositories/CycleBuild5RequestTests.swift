import Foundation
@testable import HealthLog
import Testing

@Suite("Cycle Build 5 request paths", .serialized)
struct CycleBuild5RequestTests {
    @Test("Day log GET uses the date query and accepts a null row")
    func dayLogByDate() async throws {
        nonisolated(unsafe) var path: String?
        nonisolated(unsafe) var query: String?
        MockURLProtocol.handler = { request in
            // CU-07: the handler is process-global — record only OUR route so a
            // parallel suite's request cannot overwrite what we assert on.
            if request.targets("/api/cycle/day-logs") {
                path = request.url?.path
                query = request.url?.query
            }
            return try Self.response(request, status: 200, body: #"{"data":null,"error":null}"#)
        }
        let repository = try makeRepository()
        let result = try await repository.dayLog(date: "2026-07-20")
        #expect(result == nil)
        #expect(path == "/api/cycle/day-logs")
        #expect(query == "date=2026-07-20")
    }

    @Test("Day log PATCH sends explicit clears to the row path")
    func updateDayLogPatch() async throws {
        nonisolated(unsafe) var path: String?
        nonisolated(unsafe) var method: String?
        nonisolated(unsafe) var body: Data?
        MockURLProtocol.handler = { request in
            if request.targets("/api/cycle/day-logs/row-1") {
                path = request.url?.path
                method = request.httpMethod
                body = request.requestBodyData()
            }
            return try Self.response(
                request,
                status: 200,
                body: Self.dayLogResponse
            )
        }
        let repository = try makeRepository()
        let result = try await repository.updateDayLog(
            id: "row-1",
            patch: CycleDayLogPatch(
                flow: .clear,
                basalBodyTempC: .clear,
                protectedSex: .clear,
                contraceptive: .set(.none),
                symptoms: .set([]),
                note: .clear
            )
        )
        #expect(result.id == "row-1")
        #expect(path == "/api/cycle/day-logs/row-1")
        #expect(method == "PATCH")
        let object = try #require(body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(object["flow"] is NSNull)
        #expect((object["symptoms"] as? [Any])?.isEmpty == true)
        #expect(object["contraceptive"] as? String == "NONE")
    }

    @Test("Retriable day log PATCH queues the exact tri-state edit")
    func updateDayLogQueuesPatch() async throws {
        MockURLProtocol.handler = { request in
            try Self.response(
                request,
                status: 500,
                body: #"{"data":null,"error":"temporary"}"#
            )
        }
        let outbox = try OutboxQueue(inMemory: true)
        let repository = try makeRepository(outbox: outbox)
        let patch = CycleDayLogPatch(
            flow: .clear,
            protectedSex: .clear,
            symptoms: .set([]),
            note: .clear
        )

        await #expect(throws: HLError.self) {
            _ = try await repository.updateDayLog(id: "row-1", patch: patch)
        }

        let operation = try #require(await outbox.snapshot.first)
        #expect(operation.kind == .updateCycleDayLog)
        let payload = try JSONDecoder.hlDefault.decode(
            OutboxQueue.Payloads.UpdateCycleDayLog.self,
            from: operation.payload
        )
        #expect(payload.id == "row-1")
        #expect(payload.patch == patch)
    }

    @Test("Settings PATCH sends all nine visible fields, omits enabled, and accepts merged response")
    func settingsRoundTrip() async throws {
        nonisolated(unsafe) var path: String?
        nonisolated(unsafe) var body: Data?
        MockURLProtocol.handler = { request in
            if request.targets("/api/auth/me/cycle-prefs") {
                path = request.url?.path
                body = request.requestBodyData()
            }
            return try Self.response(
                request,
                status: 200,
                body: Self.settingsResponse
            )
        }
        let repository = try makeRepository()
        let merged = try await repository.updatePrefs(CyclePrefsPatch(
            goal: .perimenopause,
            rawChartMode: true,
            typicalCycleLength: .clear,
            typicalPeriodLength: .set(6),
            lutealPhaseLength: .set(12),
            predictionEnabled: false,
            discreetNotifications: true,
            sensitiveCategoryEncryption: true,
            secondarySymptom: .cervix
        ))
        #expect(path == "/api/auth/me/cycle-prefs")
        #expect(merged.typicalCycleLength == nil)
        #expect(merged.typicalPeriodLength == 6)
        let object = try #require(body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(object["enabled"] == nil)
        #expect(object["typicalCycleLength"] is NSNull)
        #expect(object.count == 9)
    }

    @Test("Custom symptom list, create, update, and soft-delete use exact routes")
    func customCRUD() async throws {
        nonisolated(unsafe) var calls: [(String, String, String?)] = []
        MockURLProtocol.handler = { request in
            // CU-07: only the custom-symptom routes drive this request log (and
            // therefore the response phase) — foreign requests are ignored.
            if request.targets(prefixedBy: "/api/cycle/symptoms/custom") {
                calls.append((request.httpMethod ?? "", request.url?.path ?? "", request.url?.query))
            }
            switch calls.count {
            case 1:
                return try Self.response(request, status: 200, body: #"{"data":{"symptoms":[]},"error":null}"#)
            case 2:
                return try Self.response(
                    request,
                    status: 201,
                    body: #"{"data":{"key":"custom:abc","label":"Aura","icon":null,"custom":true},"error":null}"#
                )
            case 3:
                return try Self.response(
                    request,
                    status: 200,
                    body: #"{"data":{"key":"custom:abc","label":"Migräne","icon":"Brain","isActive":true,"custom":true},"error":null}"#
                )
            default:
                return try Self.response(
                    request,
                    status: 200,
                    body: #"{"data":{"key":"custom:abc","purged":false},"error":null}"#
                )
            }
        }
        let repository = try makeRepository()
        #expect(try await repository.customSymptoms().isEmpty)
        let created = try await repository.createCustomSymptom(.init(label: "Aura"))
        #expect(created.key == "custom:abc")
        let updated = try await repository.updateCustomSymptom(
            key: created.key,
            patch: .init(label: "Migräne", icon: .set("Brain"))
        )
        #expect(updated.label == "Migräne")
        let deleted = try await repository.softDeleteCustomSymptom(key: created.key)
        #expect(!deleted.purged)
        #expect(calls.map(\.0) == ["GET", "POST", "PATCH", "DELETE"])
        #expect(calls.map(\.1) == [
            "/api/cycle/symptoms/custom",
            "/api/cycle/symptoms/custom",
            "/api/cycle/symptoms/custom/custom:abc",
            "/api/cycle/symptoms/custom/custom:abc"
        ])
        #expect(calls.last?.2 == nil, "soft delete must not send purge=true")
    }

    @Test("Insights uses the single compute endpoint")
    func insightsPath() async throws {
        nonisolated(unsafe) var hits = 0
        nonisolated(unsafe) var path: String?
        MockURLProtocol.handler = { request in
            if request.targets("/api/cycle/insights") {
                hits += 1
                path = request.url?.path
            }
            return try Self.response(
                request,
                status: 200,
                body: Self.emptyInsightsResponse
            )
        }
        let repository = try makeRepository()
        let result = try await repository.insights()
        #expect(result.isLearning)
        #expect(path == "/api/cycle/insights")
        #expect(hits == 1)
    }

    @Test("Insights failures are not cached and a later retry succeeds")
    func insightsRetry() async throws {
        MockURLProtocol.handler = { request in
            try Self.response(
                request,
                status: 500,
                body: #"{"data":null,"error":"temporary"}"#
            )
        }
        let repository = try makeRepository()
        await #expect(throws: HLError.self) {
            _ = try await repository.insights()
        }

        MockURLProtocol.handler = { request in
            try Self.response(
                request,
                status: 200,
                body: Self.emptyInsightsResponse
            )
        }
        #expect(try await repository.insights().isLearning)
    }

    private func makeRepository(outbox: OutboxQueue? = nil) throws -> CycleRepository {
        let baseURL = try #require(URL(string: "https://test.healthlog.local"))
        let environment = AppEnvironment(
            baseURL: baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.8",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try keychain.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: environment, keychain: keychain, sessionConfiguration: .mock())
        let queue = try outbox ?? OutboxQueue(inMemory: true)
        return CycleRepository(api: api, outbox: queue)
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) throws -> (HTTPURLResponse, Data) {
        let url = try #require(request.url)
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        )
        return (response, Data(body.utf8))
    }

    private static let dayLogResponse = #"""
    {"data":{
      "id":"row-1","date":"2026-07-20","flow":null,
      "intermenstrualBleeding":false,"basalBodyTempC":null,
      "temperatureExcluded":false,"sexualActivity":false,
      "protectedSex":null,"pregnancyTest":null,"progesteroneTest":null,
      "contraceptive":"NONE","symptoms":[],"note":null,"source":"MANUAL",
      "syncVersion":2,"updatedAt":null,"deletedAt":null
    },"error":null}
    """#

    private static let settingsResponse = #"""
    {"data":{
      "goal":"PERIMENOPAUSE","cycleTrackingEnabled":true,"rawChartMode":true,
      "predictionEnabled":false,"discreetNotifications":true,
      "sensitiveCategoryEncryption":true,"typicalCycleLength":null,
      "typicalPeriodLength":6,"lutealPhaseLength":12,
      "secondarySymptom":"CERVIX","updatedAt":null
    },"error":null}
    """#

    private static let emptyInsightsResponse = #"""
    {"data":{
      "rows":[],"headline":null,
      "lagged":{"discovered":[],"pairsTested":0,"fdrQ":0.1,"minPairs":8},
      "symptomPatterns":[],"contrast":{"high":"LUTEAL","low":"FOLLICULAR"},
      "windowDays":365,"cyclesObserved":0
    },"error":null}
    """#
}

private extension URLRequest {
    func requestBodyData() -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
