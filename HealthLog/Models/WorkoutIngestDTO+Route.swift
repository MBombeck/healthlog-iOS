import Foundation

// MARK: - Workout route on the wire (1.5 ROUTES, #149, server v1.44.0)

/// The GPS track of one workout as `POST /api/workouts/batch` takes it
/// (`createBatchWorkoutSchema.route`, OpenAPI v1.47.0): a GeoJSON LineString of
/// at most ``WorkoutIngestDTO/maxRoutePoints`` `[lon, lat(, alt)]` positions and
/// the parallel `sampleTimestamps` list `[{ t, speedMs? }]`, one entry per
/// position. The server keeps it only while the account's
/// `storeWorkoutRoutes` is on and drops it otherwise with the same per-entry
/// status; the app sends it only after the person switched it on here.
public extension WorkoutIngestDTO {
    struct Route: Codable, Sendable, Equatable {
        public let geometry: Geometry
        /// Parallel to `geometry.coordinates`, same length.
        public let sampleTimestamps: [Point]?

        public struct Geometry: Codable, Sendable, Equatable {
            public let type: String
            /// `[longitude, latitude]` or `[longitude, latitude, altitude]`.
            public let coordinates: [[Double]]

            public init(coordinates: [[Double]]) {
                type = "LineString"
                self.coordinates = coordinates
            }
        }

        /// One `sampleTimestamps` entry. `hr` is never sent: the heart-rate
        /// curve rides in the route-independent `samples` series.
        public struct Point: Codable, Sendable, Equatable {
            public let t: Date
            public let speedMs: Double?

            public init(t: Date, speedMs: Double?) {
                self.t = t
                self.speedMs = speedMs
            }
        }

        public init(geometry: Geometry, sampleTimestamps: [Point]?) {
            self.geometry = geometry
            self.sampleTimestamps = sampleTimestamps
        }

        public var pointCount: Int {
            geometry.coordinates.count
        }
    }

    /// Server cap per route (`MAX_ROUTE_POINTS`, `validations/workout.ts`).
    static let maxRoutePoints = 20000

    /// Route positions per request. The body ceiling is 5 MB; a rounded
    /// position with its timestamp is about 70 bytes, so 20 000 points stay
    /// near 1.4 MB and leave room for ten heart-rate series beside them.
    static let maxRoutePointsPerBatch = 20000

    /// The same workout with a route, or without one.
    func withRoute(_ route: Route?) -> WorkoutIngestDTO {
        WorkoutIngestDTO(
            sportType: sportType,
            startedAt: startedAt,
            endedAt: endedAt,
            totalEnergyKcal: totalEnergyKcal,
            totalDistanceM: totalDistanceM,
            avgHeartRate: avgHeartRate,
            maxHeartRate: maxHeartRate,
            minHeartRate: minHeartRate,
            stepCount: stepCount,
            elevationM: elevationM,
            source: source,
            externalId: externalId,
            samples: samples,
            route: route
        )
    }

    /// Upload chunks for one set of workouts. Without a route the caps stay
    /// as before (100, or 10 when a heart-rate series rides along). With a
    /// route a chunk also closes before its route points would pass
    /// ``maxRoutePointsPerBatch``; a single workout always fits, because
    /// ``WorkoutRouteWire`` thins every route to ``maxRoutePoints``.
    static func uploadChunks(_ dtos: [WorkoutIngestDTO]) -> [[WorkoutIngestDTO]] {
        let cap = dtos.contains { $0.samples != nil || $0.route != nil }
            ? maxWorkoutsPerSeriesBatch
            : maxWorkoutsPerBatch
        var chunks: [[WorkoutIngestDTO]] = []
        var current: [WorkoutIngestDTO] = []
        var points = 0
        for dto in dtos {
            let routePoints = dto.route?.pointCount ?? 0
            if !current.isEmpty, current.count >= cap || points + routePoints > maxRoutePointsPerBatch {
                chunks.append(current)
                current = []
                points = 0
            }
            current.append(dto)
            points += routePoints
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// One GPS fix as HealthKit hands it over, already stripped of everything the
/// wire does not take. Pure value, so the conversion is testable without
/// CoreLocation.
struct WorkoutRouteLocation: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    /// `nil` when the fix had no valid altitude.
    let altitude: Double?
    let timestamp: Date
    /// Metres per second, `nil` when the fix had no valid speed.
    let speed: Double?
}

/// HealthKit fixes to the wire route, by the server's own rules.
enum WorkoutRouteWire {
    struct Result: Equatable {
        let route: WorkoutIngestDTO.Route?
        /// Usable fixes before thinning.
        let usableCount: Int
        /// Whether thinning dropped points (counted in the diagnostics, never
        /// silent).
        var wasThinned: Bool {
            (route?.pointCount ?? 0) < usableCount && route != nil
        }
    }

    /// Valid fixes in time order, thinned evenly to the server cap (first and
    /// last always kept, `thinIndices` in `apple-health/route-import.ts`),
    /// rounded to what GPS can resolve (latitude and longitude to 1e-6 degrees,
    /// about 11 cm, altitude to 0.1 m, speed to 0.01 m/s). Altitude rides only
    /// when every kept fix has one, as the server does for an export. Fewer
    /// than two usable fixes is no route.
    static func route(from locations: [WorkoutRouteLocation]) -> Result {
        let usable = locations
            .filter(isUsable)
            .sorted { $0.timestamp < $1.timestamp }
        let kept = thinIndices(count: usable.count, max: WorkoutIngestDTO.maxRoutePoints).map { usable[$0] }
        guard kept.count >= 2 else { return Result(route: nil, usableCount: usable.count) }
        let withAltitude = kept.allSatisfy { $0.altitude != nil }
        let coordinates = kept.map { fix -> [Double] in
            var position = [round(fix.longitude, 1e6), round(fix.latitude, 1e6)]
            if withAltitude, let altitude = fix.altitude { position.append(round(altitude, 10)) }
            return position
        }
        let points = kept.map { fix in
            WorkoutIngestDTO.Route.Point(t: fix.timestamp, speedMs: fix.speed.flatMap(wireSpeed))
        }
        return Result(
            route: WorkoutIngestDTO.Route(
                geometry: .init(coordinates: coordinates),
                sampleTimestamps: points
            ),
            usableCount: usable.count
        )
    }

    /// Indices that thin `count` points evenly to at most `max`, always
    /// keeping the first and the last (server `thinIndices`).
    static func thinIndices(count: Int, max: Int) -> [Int] {
        guard count > max else { return Array(0 ..< Swift.max(0, count)) }
        guard max > 1 else { return [0] }
        let step = Double(count - 1) / Double(max - 1)
        return (0 ..< max).map { Int((Double($0) * step).rounded()) }
    }

    private static func isUsable(_ fix: WorkoutRouteLocation) -> Bool {
        fix.latitude.isFinite && fix.longitude.isFinite
            && (-90 ... 90).contains(fix.latitude)
            && (-180 ... 180).contains(fix.longitude)
    }

    /// The schema takes 0 to 50 m/s; anything else is left out, not clamped.
    private static func wireSpeed(_ speed: Double) -> Double? {
        guard speed.isFinite, (0 ... 50).contains(speed) else { return nil }
        return round(speed, 100)
    }

    private static func round(_ value: Double, _ scale: Double) -> Double {
        (value * scale).rounded() / scale
    }
}
