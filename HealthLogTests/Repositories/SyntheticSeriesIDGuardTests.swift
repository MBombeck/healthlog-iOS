import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// #115 R3 — series point ids `day:` / `hour:` (pulse and glucose today, HRV and
/// SpO2 from server v1.39.7), the day-collapsed list key `day:<TYPE>:<day>` and
/// the sleep keys are **not** measurement rows. The app synthesises
/// `Measurement`s from such points (`ChartDetailStore.measurementsFromSeriesPoints`,
/// which also feeds the per-kind list's empty-page fallback with source `.manual`,
/// and the cumulative `recent(kind:)` path with `.appleHealth`). On 286 those
/// rows were swipe-editable and -deletable, and a delete sent
/// `DELETE /api/measurements/hour:…`, which the server answers with 404.
///
/// Pinned here: the point shape the server sends decodes (the extra
/// `valueMin` / `valueMax` band is tolerated), every synthetic row is
/// read-only, the repository refuses them before the wire, and a real row is
/// untouched by the guard.
@Suite("R3 — synthetic series ids are never treated as measurement ids", .mockURLSession)
struct SyntheticSeriesIDGuardTests {
    /// `GET /api/measurements/series?kind=pulse` at server v1.39.5+ for a dense
    /// 30-day window: hour buckets with the hour's mean and its low/high band.
    static let hourBucketedPulse = """
    { "kind": "pulse", "unit": "bpm",
      "points": [
        { "id": "hour:2026-09-27T06:00:00.000Z", "at": "2026-09-27T06:00:00.000Z",
          "value": 61.42, "secondary": null, "valueMin": 54, "valueMax": 77 },
        { "id": "hour:2026-09-27T07:00:00.000Z", "at": "2026-09-27T07:00:00.000Z",
          "value": 88.1, "secondary": null, "valueMin": 70, "valueMax": 131 }
      ],
      "stats": { "mean": 72.3, "min": 48, "max": 131, "stdDev": 11.2, "count": 43012 } }
    """

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local"),
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "286"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    // MARK: - Decode + synthesis

    @Test("hour: points decode with their band; the stats still cover every reading")
    func hourPointsDecode() throws {
        let series = try JSONDecoder.hlDefault.decode(MeasurementSeries.self, from: Data(Self.hourBucketedPulse.utf8))
        #expect(series.points.map(\.id) == ["hour:2026-09-27T06:00:00.000Z", "hour:2026-09-27T07:00:00.000Z"])
        // The chart plots the hour's mean; min/max come from the server's
        // statistics over every reading, not from the plotted means.
        #expect(series.points.map(\.value) == [61.42, 88.1])
        #expect(series.stats.min == 48)
        #expect(series.stats.max == 131)
        #expect(series.stats.count == 43012)
    }

    @Test("Rows synthesised from hour: points are read-only and flagged synthetic")
    func synthesisedRowsAreReadOnly() throws {
        let series = try JSONDecoder.hlDefault.decode(MeasurementSeries.self, from: Data(Self.hourBucketedPulse.utf8))
        let rows = ChartDetailStore.measurementsFromSeriesPoints(series.points, kind: .pulse)
        #expect(rows.count == 2)
        for row in rows {
            // Source `.manual` would be editable on its own — the id decides.
            #expect(row.source == .manual)
            #expect(row.isSyntheticServerRow)
            #expect(row.isServerDerivedReadOnly, "\(row.id) must not offer Edit/Delete")
            #expect(MeasurementChronoModel.ChronoEntry.single(row).editableMeasurement == nil)
        }
    }

    @Test("Every synthetic key the server hands out is recognised", arguments: [
        "hour:2026-09-27T06:00:00.000Z",
        "day:2026-06-01",
        "day:ACTIVE_ENERGY_BURNED:2026-09-30",
        "sleep:2026-09-30",
        "sleep-seg:2026-09-30:2"
    ])
    func syntheticKeys(id: String) {
        let row = Measurement(id: id, kind: .pulse, recordedAt: .now, value: .scalar(60), source: .appleHealth)
        #expect(Measurement.isSyntheticServerRowID(id))
        #expect(row.isServerDerivedReadOnly)
    }

    @Test("Real ids stay editable: a cuid, a local optimistic id, a standalone id")
    func realIDsUntouched() {
        for id in ["cmg1x2y3z0000abcd1234efgh", "local-6F1C", "hk-pulse-ABC", "today-steps"] {
            let row = Measurement(id: id, kind: .pulse, recordedAt: .now, value: .scalar(60), source: .manual)
            #expect(!row.isSyntheticServerRow, "\(id)")
            #expect(!row.isServerDerivedReadOnly, "\(id)")
        }
    }

    // MARK: - Repository refuses before the wire

    @Test("delete(id: hour:…) never reaches the server and is not queued")
    func deleteRefusedBeforeWire() async throws {
        let requests = RequestCounter()
        MockURLProtocol.install { req in
            requests.bump(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, nil)
        }
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: makeAPI(), outbox: outbox)
        await #expect(throws: HLError.self) {
            try await repo.delete(id: "hour:2026-09-27T06:00:00.000Z")
        }
        #expect(requests.paths.isEmpty, "sent: \(requests.paths)")
        #expect(await outbox.snapshot.isEmpty)
    }

    @Test("update(id: day:…) never reaches the server")
    func updateRefusedBeforeWire() async throws {
        let requests = RequestCounter()
        MockURLProtocol.install { req in
            requests.bump(req)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let repo = try MeasurementsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        await #expect(throws: HLError.self) {
            _ = try await repo.update(id: "day:2026-06-01", patch: MeasurementPatch(value: 70), kind: .pulse)
        }
        #expect(requests.paths.isEmpty, "sent: \(requests.paths)")
    }

    @Test("bulkDelete drops synthetic keys and sends only the real ids")
    func bulkDeleteFiltersSynthetic() async throws {
        let requests = RequestCounter()
        MockURLProtocol.install { req in
            requests.bump(req)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"deleted":1}}"#.utf8)
            )
        }
        let repo = try MeasurementsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
        let deleted = try await repo.bulkDelete(ids: ["hour:2026-09-27T06:00:00.000Z", "real-row-1", "day:2026-06-01"])
        #expect(deleted == 1)
        #expect(requests.bodies.count == 1)
        let body = try #require(requests.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["ids"] as? [String] == ["real-row-1"])

        // Only synthetic keys → nothing at all goes out.
        let none = try await repo.bulkDelete(ids: ["sleep:2026-09-30"])
        #expect(none == 0)
        #expect(requests.bodies.count == 1)
    }
}

/// Thread-safe request log for the handlers above.
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    private var _bodies: [Data] = []

    func bump(_ req: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        _paths.append("\(req.httpMethod ?? "?") \(req.url?.path ?? "")")
        if let body = req.httpBody ?? req.httpBodyStream.flatMap(Self.read(_:)) {
            _bodies.append(body)
        }
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _paths
    }

    var bodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _bodies
    }

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var buf = Data()
        var raw = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&raw, maxLength: 4096)
            guard count > 0 else { break }
            buf.append(raw, count: count)
        }
        return buf.isEmpty ? nil : buf
    }
}

// swiftlint:enable force_unwrapping
