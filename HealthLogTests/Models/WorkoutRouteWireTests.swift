import Foundation
@testable import HealthLog
import Testing

/// **1.5 ROUTES (#149)** — the route on the wire: the server's thinning
/// rule, the schema bounds, the chunking under the 5 MB body ceiling, the
/// round trip into the workout detail, and an outbox payload of 1.4.1.
@Suite("ROUTES — workout route wire format")
struct WorkoutRouteWireTests {
    private static let start = Date(timeIntervalSince1970: 1_762_340_000)

    private static func fix(
        _ index: Int,
        lat: Double = 51.481_234_567_8,
        lon: Double = 7.216_543_21,
        altitude: Double? = 112.345,
        speed: Double? = 3.456_7
    ) -> WorkoutRouteLocation {
        WorkoutRouteLocation(
            latitude: lat + Double(index) * 1e-5,
            longitude: lon,
            altitude: altitude,
            timestamp: start.addingTimeInterval(Double(index)),
            speed: speed
        )
    }

    @Test("thins evenly to the server cap of 20 000 and keeps first and last, with a counter")
    func thinsToServerCap() throws {
        let fixes = (0 ..< 25000).map { Self.fix($0) }
        let result = WorkoutRouteWire.route(from: fixes)
        let route = try #require(result.route)
        #expect(route.pointCount == 20000)
        #expect(route.sampleTimestamps?.count == 20000)
        #expect(route.sampleTimestamps?.first?.t == Self.start)
        #expect(route.sampleTimestamps?.last?.t == Self.start.addingTimeInterval(24999))
        #expect(result.usableCount == 25000)
        #expect(result.wasThinned)
    }

    @Test("the index rule is the server's thinIndices")
    func thinIndicesMatchServer() {
        #expect(WorkoutRouteWire.thinIndices(count: 5, max: 10) == [0, 1, 2, 3, 4])
        // (count - 1) / (max - 1) = 2.25 → round(i * 2.25)
        #expect(WorkoutRouteWire.thinIndices(count: 10, max: 5) == [0, 2, 5, 7, 9])
    }

    @Test("a short route is not thinned and says so")
    func shortRouteUntouched() throws {
        let result = WorkoutRouteWire.route(from: (0 ..< 3).map { Self.fix($0) })
        #expect(try #require(result.route).pointCount == 3)
        #expect(!result.wasThinned)
    }

    @Test("positions are rounded, ordered by time, altitude only when every fix has one")
    func roundingAndAltitude() throws {
        let fixes = [Self.fix(1), Self.fix(0)]
        let route = try #require(WorkoutRouteWire.route(from: fixes).route)
        #expect(route.geometry.type == "LineString")
        #expect(route.geometry.coordinates[0] == [7.216543, 51.481235, 112.3])
        #expect(route.sampleTimestamps?.first?.t == Self.start)
        #expect(route.sampleTimestamps?.first?.speedMs == 3.46)

        let mixed = [Self.fix(0), Self.fix(1, altitude: nil)]
        let flat = try #require(WorkoutRouteWire.route(from: mixed).route)
        #expect(flat.geometry.coordinates.allSatisfy { $0.count == 2 })
    }

    @Test("invalid fixes drop out, speed outside 0 to 50 is left out, fewer than two fixes is no route")
    func schemaBounds() throws {
        let fixes = [
            Self.fix(0, speed: 60),
            Self.fix(1, lat: 95),
            Self.fix(2, lon: .nan),
            Self.fix(3, speed: nil)
        ]
        let route = try #require(WorkoutRouteWire.route(from: fixes).route)
        #expect(route.pointCount == 2)
        #expect(route.sampleTimestamps?.allSatisfy { $0.speedMs == nil } == true)

        #expect(WorkoutRouteWire.route(from: [Self.fix(0)]).route == nil)
        #expect(WorkoutRouteWire.route(from: []).route == nil)
    }

    @Test("the body has the schema's shape: geometry, parallel sampleTimestamps, no hr")
    func encodesSchemaShape() throws {
        let route = try #require(WorkoutRouteWire.route(from: [Self.fix(0), Self.fix(1, speed: nil)]).route)
        let dto = Self.dto("w-1").withRoute(route)
        let data = try JSONEncoder.hlBatch.encode(WorkoutBatchPayload(workouts: [dto]))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let workout = try #require((json["workouts"] as? [[String: Any]])?.first)
        let wire = try #require(workout["route"] as? [String: Any])
        let geometry = try #require(wire["geometry"] as? [String: Any])
        #expect(geometry["type"] as? String == "LineString")
        #expect((geometry["coordinates"] as? [[Double]])?.count == 2)
        let points = try #require(wire["sampleTimestamps"] as? [[String: Any]])
        #expect(points.count == 2)
        #expect(points[0]["t"] as? String == "2025-11-05T10:53:20Z")
        #expect(points[0]["speedMs"] as? Double == 3.46)
        #expect(points[1]["speedMs"] == nil)
        #expect(points.allSatisfy { $0["hr"] == nil })
    }

    @Test("without a route the key is absent, exactly as in 1.4")
    func noRouteNoKey() throws {
        let data = try JSONEncoder.hlBatch.encode(WorkoutBatchPayload(workouts: [Self.dto("w-1")]))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("route"))
    }

    @Test("a sent route reads back on the workout detail (WorkoutRouteDTO)")
    func roundTripIntoDetail() throws {
        let route = try #require(WorkoutRouteWire.route(from: (0 ..< 4).map { Self.fix($0) }).route)
        let data = try JSONEncoder.hlBatch.encode(route)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detail = try decoder.decode(WorkoutRouteDTO.self, from: data)
        #expect(detail.geometry.coordinates == route.geometry.coordinates)
        #expect(detail.sampleTimestamps?.count == 4)
        #expect(detail.samples?.first?.speedMs == 3.46)
    }

    @Test("update path: an outbox payload written by 1.4.1 (no route key) still decodes")
    func outboxPayloadFrom141() throws {
        let legacy = Data(#"""
        {"workouts":[{"sportType":"running","startedAt":"2026-10-01T07:00:00Z",
          "endedAt":"2026-10-01T07:30:00Z","source":"APPLE_HEALTH","externalId":"hk-1",
          "samples":[{"t":"2026-10-01T07:00:00Z","hr":120}]}]}
        """#.utf8)
        let payload = try JSONDecoder.hlDefault.decode(OutboxQueue.Payloads.UploadWorkoutBatch.self, from: legacy)
        #expect(payload.workouts.count == 1)
        #expect(payload.workouts[0].route == nil)
        #expect(payload.workouts[0].samples?.count == 1)
    }

    @Test("chunks close at the route point budget, a long route goes alone, caps stay without routes")
    func chunking() throws {
        let long = try #require(WorkoutRouteWire.route(from: (0 ..< 20000).map { Self.fix($0) }).route)
        let short = try #require(WorkoutRouteWire.route(from: (0 ..< 100).map { Self.fix($0) }).route)
        let dtos = [
            Self.dto("a").withRoute(short),
            Self.dto("b").withRoute(long),
            Self.dto("c"),
            Self.dto("d").withRoute(short)
        ]
        let chunks = WorkoutIngestDTO.uploadChunks(dtos)
        #expect(chunks.map { $0.map(\.externalId) } == [["a"], ["b", "c"], ["d"]])
        for chunk in chunks {
            #expect(chunk.reduce(0) { $0 + ($1.route?.pointCount ?? 0) } <= WorkoutIngestDTO.maxRoutePointsPerBatch)
        }

        let plain = (0 ..< 150).map { Self.dto("p\($0)") }
        #expect(WorkoutIngestDTO.uploadChunks(plain).map(\.count) == [100, 50])
        let routed = (0 ..< 12).map { Self.dto("r\($0)").withRoute(short) }
        #expect(WorkoutIngestDTO.uploadChunks(routed).map(\.count) == [10, 2])
    }

    static func dto(_ id: String) -> WorkoutIngestDTO {
        WorkoutIngestDTO(
            sportType: "running",
            startedAt: start,
            endedAt: start.addingTimeInterval(1800),
            externalId: id
        )
    }
}

/// **1.5 ROUTES** — the gate: routes only with a known server of v1.44.0 or
/// newer and the person's switch on, and the wire boundary strips the rest.
@Suite("ROUTES — the route opt-in gate")
struct WorkoutRouteOptInTests {
    private func defaults(version: String?, optInFor owner: String? = nil) throws -> UserDefaults {
        let suite = "routes-optin-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        if let version { KnownServerVersion.record(ServerVersionInfo(version: version), defaults: defaults) }
        if let owner { WorkoutRouteOptIn.set(true, ownerUserID: owner, defaults: defaults) }
        return defaults
    }

    @Test(
        "allows only server >= 1.44.0 with the switch on for this owner",
        arguments: [
            (nil as String?, true, false),
            ("1.43.9", true, false),
            ("1.44.0", false, false),
            ("1.44.0", true, true),
            ("1.47.0", true, true)
        ]
    )
    func truthTable(version: String?, switchedOn: Bool, expected: Bool) throws {
        let defaults = try defaults(version: version, optInFor: switchedOn ? "user-A" : nil)
        #expect(WorkoutRouteOptIn.allowsUpload(ownerUserID: "user-A", defaults: defaults) == expected)
        #expect(!WorkoutRouteOptIn.allowsUpload(ownerUserID: "user-B", defaults: defaults))
        #expect(!WorkoutRouteOptIn.allowsUpload(ownerUserID: " ", defaults: defaults))
        #expect(!WorkoutRouteOptIn.allowsUpload(ownerUserID: nil, defaults: defaults))
    }

    @Test("switching off removes the mark")
    func switchOff() throws {
        let defaults = try defaults(version: "1.47.0", optInFor: "user-A")
        WorkoutRouteOptIn.set(false, ownerUserID: "user-A", defaults: defaults)
        #expect(!WorkoutRouteOptIn.isOn(ownerUserID: "user-A", defaults: defaults))
        #expect(defaults.object(forKey: WorkoutRouteOptIn.key(ownerUserID: "user-A")) == nil)
    }

    @Test("the wire boundary strips every route when not allowed and leaves the rest")
    func enforceStrips() throws {
        let route = try #require(
            WorkoutRouteWire.route(from: [
                WorkoutRouteLocation(latitude: 1, longitude: 2, altitude: nil, timestamp: .distantPast, speed: nil),
                WorkoutRouteLocation(latitude: 1.1, longitude: 2, altitude: nil, timestamp: .now, speed: nil)
            ]).route
        )
        let batch = [WorkoutRouteWireTests.dto("a").withRoute(route), WorkoutRouteWireTests.dto("b")]
        let denied = WorkoutRouteOptIn.enforce(batch, allowed: false)
        #expect(denied.stripped)
        #expect(denied.workouts.allSatisfy { $0.route == nil })
        #expect(denied.workouts.map(\.externalId) == ["a", "b"])

        let allowed = WorkoutRouteOptIn.enforce(batch, allowed: true)
        #expect(!allowed.stripped)
        #expect(allowed.workouts == batch)

        let none = WorkoutRouteOptIn.enforce([WorkoutRouteWireTests.dto("c")], allowed: false)
        #expect(!none.stripped)
    }
}
