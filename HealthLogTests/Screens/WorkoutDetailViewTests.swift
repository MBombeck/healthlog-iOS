import CoreLocation
import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// Thread-safe counter for handler-side bookkeeping, behind a `Mutex` rather
/// than a hand-written promise the compiler cannot verify. Since Plan 09-11 it
/// is owned by one session, so nothing but that session's own requests can move
/// it.
private final class Counter: Sendable {
    private let count = Mutex(0)

    func bump() {
        count.withLock { $0 += 1 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}

/// File-scope on purpose: the store suite is `@MainActor`, and a `@Sendable`
/// handler closure running on the URL-loading queue cannot call a main-actor
/// member.
private func respond(_ req: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data?) {
    let http = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (http, Data(json.utf8))
}

/// v0.5.4-SP5 — Workout-Detail-Screen contract tests.
///
/// Pins the pure helpers that drive the HR-chart accessibility label
/// + the GeoJSON-LineString → CLLocationCoordinate2D conversion. The
/// SwiftUI body itself is exercised through the store-driven tests
/// further down — the helpers stay testable without a HK store.
@Suite("WorkoutDetailView — HR-chart + route helpers")
@MainActor
struct WorkoutDetailHelperTests {
    @Test("HR a11y label summarises sample count + min/max bpm")
    func hrAccessibilityLabelSummary() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let series: [WorkoutHRSample] = [
            .init(timestamp: base, bpm: 110),
            .init(timestamp: base.addingTimeInterval(10), bpm: 135),
            .init(timestamp: base.addingTimeInterval(20), bpm: 165),
            .init(timestamp: base.addingTimeInterval(30), bpm: 142)
        ]
        let label = WorkoutDetailView.hrAccessibilityLabel(samples: series)
        #expect(label.contains("4 Messpunkte"))
        #expect(label.contains("110"))
        #expect(label.contains("165"))
    }

    @Test("HR a11y label falls back when no samples")
    func hrAccessibilityLabelEmpty() {
        let label = WorkoutDetailView.hrAccessibilityLabel(samples: [])
        #expect(label == "Herzfrequenz nicht verfügbar")
    }

    @Test("Route coords decode LineString swapping GeoJSON lon/lat to CL lat/lon")
    func routeCoordsLineString() throws {
        // GeoJSON stores [lon, lat, alt?] → CoreLocation reads (lat, lon).
        // The boundary swap happens once in the view layer so the rest
        // of the map pipeline (MKPolyline, Region bounds) sees plain
        // CL coordinates.
        let route = WorkoutRouteDTO(
            geometry: .init(type: "LineString", coordinates: [
                [11.0, 49.0],
                [11.01, 49.01],
                [11.02, 49.02, 123.4]
            ]),
            sampleTimestamps: nil
        )
        let coords = try #require(WorkoutDetailView.routeCoordinates(from: route))
        #expect(coords.count == 3)
        #expect(coords[0].latitude == 49.0)
        #expect(coords[0].longitude == 11.0)
        // Altitude (third element) is discarded — MapKit doesn't render
        // it for 2D polylines and the chart wouldn't know what to do
        // with it.
        #expect(coords[2].latitude == 49.02)
    }

    @Test("Route coords accept mixed-case GeoJSON type")
    func routeCoordsCaseInsensitive() {
        // Server emits "LineString"; a future serializer change could
        // emit "lineString". The helper normalises so the map doesn't
        // disappear on a casing regression.
        let route = WorkoutRouteDTO(
            geometry: .init(type: "lineString", coordinates: [[1.0, 2.0], [3.0, 4.0]]),
            sampleTimestamps: nil
        )
        let coords = WorkoutDetailView.routeCoordinates(from: route)
        #expect(coords?.count == 2)
    }

    @Test("Route coords reject unknown geometry types")
    func routeCoordsRejectsUnknown() {
        // Polygon / Point / null-shape geometry must yield nil so the
        // view hides the map rather than crashing the polyline render.
        let route = WorkoutRouteDTO(
            geometry: .init(type: "Polygon", coordinates: [[1.0, 2.0]]),
            sampleTimestamps: nil
        )
        #expect(WorkoutDetailView.routeCoordinates(from: route) == nil)
    }

    @Test("Route coords reject malformed coordinate pairs")
    func routeCoordsRejectsMalformed() {
        // A single-element entry (just lat) is dropped silently — the
        // overall list survives even when one point is bad.
        let route = WorkoutRouteDTO(
            geometry: .init(type: "LineString", coordinates: [
                [11.0],
                [11.01, 49.01]
            ]),
            sampleTimestamps: nil
        )
        let coords = WorkoutDetailView.routeCoordinates(from: route)
        #expect(coords?.count == 1)
    }

    @Test("Route coords returns nil for nil route + empty arrays")
    func routeCoordsHandlesNilAndEmpty() {
        #expect(WorkoutDetailView.routeCoordinates(from: nil) == nil)
        let empty = WorkoutRouteDTO(
            geometry: .init(type: "LineString", coordinates: []),
            sampleTimestamps: nil
        )
        #expect(WorkoutDetailView.routeCoordinates(from: empty) == nil)
    }

    @Test("Route a11y label includes GPS-point count")
    func routeAccessibilityLabelCount() {
        let label = WorkoutDetailView.routeAccessibilityLabel(count: 412)
        #expect(label.contains("412"))
        #expect(label.contains("Streckenkarte"))
    }
}

@Suite("RouteMap — fittedRegion polyline bounds")
@MainActor
struct RouteMapFittedRegionTests {
    @Test("Fitted region centres on midpoint of bounding box")
    func centeredOnMidpoint() {
        let coords = [
            CLLocationCoordinate2D(latitude: 49.0, longitude: 11.0),
            CLLocationCoordinate2D(latitude: 49.2, longitude: 11.4)
        ]
        let region = RouteMap.fittedRegion(for: coords)
        #expect(abs(region.center.latitude - 49.1) < 0.0001)
        #expect(abs(region.center.longitude - 11.2) < 0.0001)
    }

    @Test("Fitted region inflates span by ~40% over raw bounds")
    func inflatedSpan() {
        let coords = [
            CLLocationCoordinate2D(latitude: 49.0, longitude: 11.0),
            CLLocationCoordinate2D(latitude: 49.1, longitude: 11.2)
        ]
        let region = RouteMap.fittedRegion(for: coords)
        // Raw lat span = 0.1; inflate 1.4 → 0.14.
        #expect(region.span.latitudeDelta > 0.10)
        #expect(region.span.latitudeDelta < 0.20)
    }

    @Test("Fitted region applies minimum-span floor for degenerate single point")
    func degenerateMinimumSpan() {
        // Stand-in-one-spot workouts would collapse to a single
        // (lat, lon) — the helper floors the span to 0.002 each axis
        // so the map shows a sensible neighbourhood-scale view.
        let coords = [
            CLLocationCoordinate2D(latitude: 49.0, longitude: 11.0)
        ]
        let region = RouteMap.fittedRegion(for: coords)
        #expect(region.span.latitudeDelta >= 0.002)
        #expect(region.span.longitudeDelta >= 0.002)
    }

    @Test("Fitted region returns world-origin fallback when empty")
    func emptyCoords() {
        let region = RouteMap.fittedRegion(for: [])
        #expect(region.center.latitude == 0)
        #expect(region.center.longitude == 0)
    }
}

/// ## Issue #82 / Plan 09-11 — the transport is session-owned
///
/// Every response handler below is installed on a ``MockURLProtocolSession``
/// that its own test retains, and that session's `baseURL` **and** configuration
/// build that test's `APIClient`. This file assigns the mock's process-global
/// handler slot zero times, so a parallel or later suite cannot
/// replace a handler between our install and our request. That was not
/// hypothetical here: before the migration, `aLaterInstallCannotAnswerThisSuite`
/// was answered by the handler the *previous test in this file* had left in the
/// global slot, and read `w-x` where it asked for `w-session`.
@Suite("WorkoutsStore — loadDetail mirrors repo + HK series", .serialized)
@MainActor
struct WorkoutsStoreLoadDetailTests {
    /// The transport seam (issue #82 / Plan 09-11). Both halves come from the
    /// caller's retained session, so every request this client makes is answered
    /// by that session's handler or by nothing at all.
    ///
    /// `baseURL: session.baseURL` is the load-bearing half. `APIClient.init`
    /// assigns `config.httpAdditionalHeaders` **wholesale** on the configuration
    /// object it is handed, before its `URLSession` exists, so the session token
    /// is gone by the time the first request is built. Keeping the old
    /// hard-coded host while passing `session.configuration` would leave the four
    /// handlers below installed and never reached, answered instead by the legacy
    /// process-global slot —
    /// `MockURLProtocolIsolationTests.aSessionConfigurationAloneDoesNotMigrateAClient`
    /// pins that trap.
    private func makeAPI(session: MockURLProtocolSession) -> APIClient {
        let env = AppEnvironment(
            baseURL: session.baseURL,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.4",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: session.configuration
        )
    }

    @Test("loadDetail — populates detail + HR series when both windows known")
    func loadDetailPopulatesSeries() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try WorkoutsRepository(api: makeAPI(session: session), outbox: OutboxQueue(inMemory: true))
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let fakeHR = FakeHKDetailService(samples: [
            .init(timestamp: base, bpm: 120),
            .init(timestamp: base.addingTimeInterval(10), bpm: 150)
        ])
        let store = WorkoutsStore(repo: repo, hkDetail: fakeHR)
        session.install { req in
            let body = Data(#"""
            {"data":{
              "id":"w-1","sportType":"running",
              "startedAt":"2026-05-15T07:00:00Z","endedAt":"2026-05-15T07:30:00Z",
              "durationSec":1800,"distanceM":5000,"activeEnergyKcal":320,
              "avgHr":145,"maxHr":170,
              "source":"APPLE_HEALTH","externalId":"hk:abc",
              "canonicalId":"w-1","route":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        await store.loadDetail(id: "w-1")
        #expect(store.detail?.id == "w-1")
        #expect(store.detail?.avgHr == 145)
        #expect(store.detailHRSeries?.count == 2)
        #expect(store.detailError == nil)
        #expect(store.detailLoading == false)
    }

    @Test("loadDetail — leaves HR series nil when HK returns empty")
    func loadDetailHRSeriesEmpty() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try WorkoutsRepository(api: makeAPI(session: session), outbox: OutboxQueue(inMemory: true))
        let store = WorkoutsStore(repo: repo, hkDetail: FakeHKDetailService(samples: []))
        session.install { req in
            let body = Data(#"""
            {"data":{
              "id":"w-2","sportType":"yoga",
              "startedAt":"2026-05-15T07:00:00Z","endedAt":"2026-05-15T07:30:00Z",
              "durationSec":1800,"distanceM":null,"activeEnergyKcal":120,
              "avgHr":null,"maxHr":null,
              "source":"MANUAL","externalId":null,
              "canonicalId":"w-2","route":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        await store.loadDetail(id: "w-2")
        #expect(store.detail?.id == "w-2")
        // Empty HK → nil series so the view layer can hide the chart.
        #expect(store.detailHRSeries == nil)
    }

    @Test("loadDetail — skips HK fetch when endedAt missing")
    func loadDetailSkipsHKOnMissingWindow() async throws {
        // A pathological row without endedAt must not fire the HK
        // round-trip — we can't predicate-bound the sample query
        // without an end date.
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try WorkoutsRepository(api: makeAPI(session: session), outbox: OutboxQueue(inMemory: true))
        let fake = FakeHKDetailService(samples: [])
        let store = WorkoutsStore(repo: repo, hkDetail: fake)
        session.install { req in
            let body = Data(#"""
            {"data":{
              "id":"w-3","sportType":"running",
              "startedAt":"2026-05-15T07:00:00Z","endedAt":null,
              "durationSec":null,"distanceM":null,"activeEnergyKcal":null,
              "avgHr":null,"maxHr":null,
              "source":"APPLE_HEALTH","externalId":null,
              "canonicalId":"w-3","route":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        await store.loadDetail(id: "w-3")
        #expect(store.detail?.id == "w-3")
        #expect(fake.callCount == 0, "HK fetch must not fire without a bounded window")
    }

    @Test("clearOnLogout — drops detail + HR series + detailError")
    func clearOnLogoutDropsDetail() async throws {
        let session = MockURLProtocolSession()
        defer { session.invalidate() }
        let repo = try WorkoutsRepository(api: makeAPI(session: session), outbox: OutboxQueue(inMemory: true))
        let store = WorkoutsStore(
            repo: repo,
            hkDetail: FakeHKDetailService(samples: [.init(timestamp: Date(), bpm: 90)])
        )
        session.install { req in
            let body = Data(#"""
            {"data":{
              "id":"w-x","sportType":"running",
              "startedAt":"2026-05-15T07:00:00Z","endedAt":"2026-05-15T07:30:00Z",
              "durationSec":1800,"distanceM":null,"activeEnergyKcal":null,
              "avgHr":null,"maxHr":null,
              "source":"APPLE_HEALTH","externalId":null,
              "canonicalId":"w-x","route":null
            },"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.loadDetail(id: "w-x")
        #expect(store.detail != nil)
        store.clearOnLogout()
        #expect(store.detail == nil)
        #expect(store.detailHRSeries == nil)
        #expect(store.detailError == nil)
    }

    // MARK: - Transport ownership (issue #82 / Plan 09-11)

    @Test("a handler installed after ours cannot answer this suite's request")
    func aLaterInstallCannotAnswerThisSuite() async throws {
        // The failure this migration removes: a suite running in parallel
        // replaces the handler between our install and our request, so our
        // request is answered by a foreign closure and our counter stays at
        // zero. Here the foreign install happens *after* ours — deterministically
        // the losing order under one process-global slot — and must still not be
        // reached.
        let session = MockURLProtocolSession()
        let foreign = MockURLProtocolSession()
        defer {
            session.invalidate()
            foreign.invalidate()
        }
        let mine = Counter()
        let theirs = Counter()
        session.install { req in
            guard req.targets(prefixedBy: "/api/workouts") else { return respond(req, "{}") }
            mine.bump()
            return respond(req, #"""
            {"data":{
              "id":"w-session","sportType":"running",
              "startedAt":"2026-05-15T07:00:00Z","endedAt":"2026-05-15T07:30:00Z",
              "durationSec":1800,"distanceM":null,"activeEnergyKcal":null,
              "avgHr":null,"maxHr":null,
              "source":"APPLE_HEALTH","externalId":null,
              "canonicalId":"w-session","route":null
            },"error":null}
            """#)
        }
        foreign.install { req in
            theirs.bump()
            return respond(req, "{}")
        }

        let repo = try WorkoutsRepository(api: makeAPI(session: session), outbox: OutboxQueue(inMemory: true))
        let store = WorkoutsStore(repo: repo, hkDetail: FakeHKDetailService(samples: []))
        await store.loadDetail(id: "w-session")

        // A positive count is the whole point: `store.detail?.id` is the decoded
        // response, and an unrouted request leaves it `nil` exactly as a 404
        // would. Only the count says the request reached this session.
        #expect(mine.value == 1, "EXPECTED_RED: WorkoutsStoreLoadDetailTests was not routed to its own session")
        #expect(theirs.value == 0)
        #expect(store.detail?.id == "w-session")
    }
}

/// Deterministic stand-in for `HealthKitWorkoutDetailServicing`. Holds a
/// fixed sample set + a call counter so the tests can assert HK was
/// (or wasn't) hit without touching the real `HKHealthStore`.
///
/// The counter was a plain `var` behind an unchecked-`Sendable` conformance
/// (Plan 09-11): it
/// is written from inside an `async` method the store awaits off the main actor
/// and read from a `@MainActor` test body, which is an unsynchronized
/// cross-isolation access the compiler was told to stop checking. It is now
/// `Mutex`-backed, so the read cannot race the write.
private final class FakeHKDetailService: HealthKitWorkoutDetailServicing, Sendable {
    private let samples: [WorkoutHRSample]
    private let calls = Mutex(0)

    var callCount: Int {
        calls.withLock { $0 }
    }

    init(samples: [WorkoutHRSample]) {
        self.samples = samples
    }

    func heartRateSeries(from _: Date, to _: Date) async -> [WorkoutHRSample] {
        calls.withLock { $0 += 1 }
        return samples
    }
}

// swiftlint:enable force_unwrapping
