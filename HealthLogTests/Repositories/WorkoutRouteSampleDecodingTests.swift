import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// 1.5 FIX-DATA (#151) — `route.sampleTimestamps` holds a bare ISO instant
/// per point (older tracks) or `{ t, speedMs?, hr? }` (the workout batch and the
/// Apple Health export since server 1.46). Until 1.5 the field was `[Date]`, and
/// one imported track made `GET /api/workouts/{id}` fail as a whole.
///
/// Decoded through the real `APIClient` (its date strategy), via the repository.
@Suite("Workout route — sample points decode per entry", .serialized, .mockURLSession)
struct WorkoutRouteSampleDecodingTests {
    private func detail(route: String, extra: String = "") async throws -> WorkoutListEntryDTO {
        let body = """
        {"data":{
          "id":"w-1","sportType":"running",
          "startedAt":"2026-10-30T07:00:00Z","endedAt":"2026-10-30T07:30:00Z",
          "durationSec":1800,"source":"IMPORT","externalId":null,"canonicalId":"w-1",
          "route":\(route)\(extra)
        },"error":null}
        """
        MockURLProtocol.install { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let api = APIClient(
            environment: AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.5.0",
                buildNumber: "1"
            ),
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
        let repo = try WorkoutsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        return try await repo.workout(id: "w-1")
    }

    private static let threePoints = #"{"type":"LineString","coordinates":[[7.2,51.48],[7.21,51.481,80],[7.22,51.482]]}"#

    @Test("(c) a track from a 1.46 import (object points) decodes completely")
    func objectPointsDecode() async throws {
        let route = """
        {"geometry":\(Self.threePoints),"sampleTimestamps":[
          {"t":"2026-10-30T07:00:00Z","speedMs":2.9,"hr":131},
          {"t":"2026-10-30T07:00:05Z","speedMs":3.1},
          {"t":"2026-10-30T07:00:10.250Z","hr":140}
        ]}
        """
        let entry = try await detail(route: route)
        let decoded = try #require(entry.route)
        let samples = try #require(decoded.samples)
        #expect(decoded.geometry.coordinates.count == 3)
        #expect(samples.count == 3)
        #expect(samples[0].speedMs == 2.9)
        #expect(samples[0].hr == 131)
        #expect(samples[1].hr == nil)
        #expect(samples[2].speedMs == nil)
        #expect(decoded.sampleTimestamps?.first == ISO8601DateFormatter().date(from: "2026-10-30T07:00:00Z"))
    }

    @Test("(c) a mixed list keeps every readable point; a broken one costs only itself")
    func mixedListDecodes() async throws {
        let route = """
        {"geometry":\(Self.threePoints),"sampleTimestamps":[
          "2026-10-30T07:00:00Z",
          {"t":"2026-10-30T07:00:05Z","speedMs":3.1,"hr":140},
          {"speedMs":3.0},
          null,
          42,
          "not a date",
          {"t":"2026-10-30T07:00:15Z","hr":"high"}
        ]}
        """
        let entry = try await detail(route: route)
        let samples = try #require(entry.route?.samples)
        #expect(samples.count == 3)
        #expect(samples[1].hr == 140)
        #expect(samples[2].hr == nil, "an unreadable heart rate drops the value, not the point")
    }

    @Test("a broken coordinate costs only that coordinate")
    func brokenCoordinateIsDropped() async throws {
        let route = """
        {"geometry":{"type":"LineString","coordinates":[[7.2,51.48],null,[7.21],["x","y"],[7.22,51.482,90]]},
         "sampleTimestamps":null}
        """
        let entry = try await detail(route: route)
        let decoded = try #require(entry.route)
        #expect(decoded.geometry.coordinates == [[7.2, 51.48], [7.22, 51.482, 90]])
        #expect(decoded.samples == nil)
        #expect(decoded.sampleTimestamps == nil)
    }

    @Test("(e) the 1.4.1 shape (bare instants) still decodes")
    func legacyShapeDecodes() async throws {
        let route = """
        {"geometry":\(Self.threePoints),"sampleTimestamps":["2026-10-30T07:00:00Z","2026-10-30T07:00:05Z","2026-10-30T07:00:10Z"]}
        """
        let entry = try await detail(route: route)
        #expect(entry.route?.sampleTimestamps?.count == 3)
        #expect(entry.route?.samples?.allSatisfy { $0.speedMs == nil && $0.hr == nil } == true)
    }

    @Test("a sample series with a bare string row skips the row and still ends")
    func sampleSeriesSkipsBareRow() async throws {
        let entry = try await detail(
            route: "null",
            extra: #","samples":{"sampleCount":3,"samples":["oops",{"t":"2026-10-30T07:00:00Z","hr":120},7]}"#
        )
        #expect(entry.route == nil)
        #expect(entry.samples?.samples.count == 1)
    }

    @Test("the memberwise init keeps the timestamps")
    func memberwiseInit() {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let route = WorkoutRouteDTO(
            geometry: .init(type: "LineString", coordinates: [[7.2, 51.48]]),
            sampleTimestamps: [date]
        )
        #expect(route.sampleTimestamps == [date])
        #expect(route.samples == [WorkoutRoutePoint(t: date)])
    }
}

// swiftlint:enable force_unwrapping
