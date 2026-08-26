import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Coverage für `MeasurementCategoriesRepository` (CAT-1, `v1.4.30.1`).
///
/// Drei Achsen:
///   1. **Wire-Decoding:** Server liefert das `{data, error}`-Envelope; der
///      Repository entpackt die innere `CategoryAssignmentMap` korrekt.
///   2. **Cache-TTL:** Erfolgreiche Antwort wird für `cacheTTL` Sekunden
///      gehalten — Hit innerhalb des Fensters macht keinen Netz-Roundtrip.
///   3. **Fallback-Disziplin:** Bei Netz-/Decoding-Fehler liefert das
///      Repo den letzten Snapshot zurück (stale-while-revalidate) oder,
///      wenn nie online gewesen, den hartcodierten `bundledFallback`.
@Suite("MeasurementCategoriesRepository — Server-overlay consumption", .serialized)
struct MeasurementCategoriesRepositoryTests {
    // MARK: - Helpers

    private func makeRepo(
        cacheTTL: TimeInterval = 600,
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> (MeasurementCategoriesRepository, ClockBox) {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let clock = ClockBox(now: now)
        let repo = MeasurementCategoriesRepository(
            api: api,
            cacheTTL: cacheTTL,
            clock: { clock.now }
        )
        return (repo, clock)
    }

    /// Test-Clock — kann zwischen den Schritten gemovet werden. Class
    /// (statt struct) damit die `@Sendable` clock-closure denselben Box
    /// referenziert, den der Test mutiert.
    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(now: Date) {
            _now = now
        }

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return _now
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            _now = _now.addingTimeInterval(interval)
        }
    }

    /// Wire-Payload, wie der Server-Route-Handler ihn emittiert (siehe
    /// `src/app/api/measurement-categories/route.ts`). Schmales Subset,
    /// reicht für den Picker-Drive — die Tests pinnen `vitals` + `activity`
    /// inkl der CAT-1-Additions.
    private static let sampleCategoriesJSON: Data = .init("""
    {
      "data": {
        "version": 1,
        "categories": [
          { "id": "vitals", "labelKey": "categories.vitals", "order": 0 },
          { "id": "body", "labelKey": "categories.body", "order": 1 },
          { "id": "activity", "labelKey": "categories.activity", "order": 2 },
          { "id": "hearing", "labelKey": "categories.hearing", "order": 4 }
        ],
        "assignments": {
          "BLOOD_PRESSURE_SYS": "vitals",
          "BLOOD_PRESSURE_DIA": "vitals",
          "PULSE": "vitals",
          "WEIGHT": "body",
          "WALKING_STEADINESS": "activity",
          "AUDIO_EXPOSURE_EVENT": "hearing"
        }
      },
      "error": null
    }
    """.utf8)

    private func okResponse(for req: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    // MARK: - Cases

    @Test("First call hits server and returns assignments from the envelope")
    func firstCallFetchesFromServer() async {
        let (repo, _) = makeRepo()
        let hits = Counter()
        MockURLProtocol.handler = { [hits] req in
            hits.increment()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.sampleCategoriesJSON
            )
        }
        let map = await repo.categoryMap()
        #expect(hits.value == 1)
        #expect(map.version == 1)
        #expect(map.categoryId(forRawType: "WALKING_STEADINESS") == "activity")
        #expect(map.categoryId(forRawType: "AUDIO_EXPOSURE_EVENT") == "hearing")
        #expect(map.categoryId(forRawType: "WEIGHT") == "body")
    }

    @Test("Second call within TTL is served from cache (no extra HTTP hit)")
    func cacheServedWithinTTL() async {
        let (repo, clock) = makeRepo(cacheTTL: 600)
        let hits = Counter()
        MockURLProtocol.handler = { [hits] req in
            hits.increment()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.sampleCategoriesJSON
            )
        }
        _ = await repo.categoryMap()
        clock.advance(by: 300) // halfway through TTL
        _ = await repo.categoryMap()
        #expect(hits.value == 1, "Cache should suppress the second roundtrip within TTL")
    }

    @Test("Call after TTL refreshes from server")
    func cacheRefreshAfterTTL() async {
        let (repo, clock) = makeRepo(cacheTTL: 600)
        let hits = Counter()
        MockURLProtocol.handler = { [hits] req in
            hits.increment()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.sampleCategoriesJSON
            )
        }
        _ = await repo.categoryMap()
        clock.advance(by: 601) // just past TTL
        _ = await repo.categoryMap()
        #expect(hits.value == 2, "Past-TTL access must refetch")
    }

    @Test("Network failure on first call returns bundled fallback (no throw)")
    func networkFailureFallsBack() async {
        let (repo, _) = makeRepo()
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let map = await repo.categoryMap()
        #expect(map.version == CategoryAssignmentMap.bundledFallback.version)
        #expect(map.categoryId(forRawType: "WALKING_STEADINESS") == "activity")
        #expect(map.categoryId(forRawType: "AUDIO_EXPOSURE_EVENT") == "hearing")
    }

    @Test("After successful fetch, network failure returns stale snapshot (SWR)")
    func staleWhileRevalidate() async {
        let (repo, clock) = makeRepo(cacheTTL: 600)
        let hits = Counter()
        MockURLProtocol.handler = { [hits] req in
            let phase = hits.value
            hits.increment()
            if phase == 0 {
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.sampleCategoriesJSON
                )
            } else {
                throw URLError(.timedOut)
            }
        }
        let first = await repo.categoryMap()
        clock.advance(by: 700) // past TTL → triggers refetch which fails
        let second = await repo.categoryMap()
        #expect(first == second, "Stale snapshot must survive a failed refresh")
        #expect(second.categoryId(forRawType: "WEIGHT") == "body")
    }

    @Test("invalidateCache forces a refetch on next call")
    func explicitInvalidationRefetches() async {
        let (repo, _) = makeRepo(cacheTTL: 600)
        let hits = Counter()
        MockURLProtocol.handler = { [hits] req in
            hits.increment()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Self.sampleCategoriesJSON
            )
        }
        _ = await repo.categoryMap()
        await repo.invalidateCache()
        _ = await repo.categoryMap()
        #expect(hits.value == 2)
    }

    @Test("bundledFallback covers the two CAT-1 wire values (R10 / per-sample)")
    func bundledFallbackHasCAT1Values() {
        let fb = CategoryAssignmentMap.bundledFallback
        #expect(fb.categoryId(forRawType: "WALKING_STEADINESS") == "activity")
        #expect(fb.categoryId(forRawType: "AUDIO_EXPOSURE_EVENT") == "hearing")
        // Sanity: covers the existing ServerMeasurementType raw values too.
        for type in ServerMeasurementType.allCases {
            #expect(fb.categoryId(forRawType: type.rawValue) != nil, "Fallback must cover wire value \(type.rawValue)")
        }
    }

    @Test("orderedCategories sorts by `order`")
    func orderedCategoriesAreSorted() {
        let map = CategoryAssignmentMap(
            version: 1,
            categories: [
                .init(id: "b", labelKey: "k.b", order: 5),
                .init(id: "a", labelKey: "k.a", order: 0),
                .init(id: "c", labelKey: "k.c", order: 1)
            ],
            assignments: [:]
        )
        let ordered = map.orderedCategories.map(\.id)
        #expect(ordered == ["a", "c", "b"])
    }

    @Test("rawTypes returns deterministic alphabetical list within a category")
    func rawTypesAreSorted() {
        let map = CategoryAssignmentMap(
            version: 1,
            categories: [.init(id: "vitals", labelKey: "k", order: 0)],
            assignments: [
                "PULSE": "vitals",
                "BLOOD_PRESSURE_SYS": "vitals",
                "WEIGHT": "body"
            ]
        )
        let types = map.rawTypes(in: "vitals")
        #expect(types == ["BLOOD_PRESSURE_SYS", "PULSE"])
    }
}

// MARK: - Thread-safe Counter

/// Atomic Int-Counter für MockURLProtocol-Handler — Strict-Concurrency
/// erlaubt kein `var hits = 0` capture-by-ref mehr.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}
