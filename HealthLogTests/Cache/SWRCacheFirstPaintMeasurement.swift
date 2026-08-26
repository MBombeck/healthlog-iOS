import Foundation
@testable import HealthLog
import SwiftData
import Testing

/// **Phase 21 (21-01) — the measurement.**
///
/// The structural claim behind this phase is strong, and this milestone exists
/// because three plausible claims turned out to be wrong. So the claim gets a
/// number in front of it before a line of the fix is written, and the number is
/// reported whatever it says.
///
/// **Method.** Seed a cache with the surfaces a foreground pass actually opens,
/// at the payload sizes 14-06 benchmarked (a ~864 B small body, a ~77 KB list
/// body), then drive every surface's `SWRCoordinator.observe` **concurrently**
/// — the shape `ForegroundPassPlan` plus the screens' `.task`s produce on
/// launch. Reachability is offline, so the ladder emits `.cached` and finishes
/// without a single network call: what is timed is the cache path and nothing
/// else. For each surface we record wall-clock from `observe` entry to first
/// emission, and — from `SWRSignpost`'s recorder — how much of that was its
/// OWN fetch and its OWN decode. The remainder is queueing: time this surface
/// spent waiting for the serial executor to be free of somebody else's work.
///
/// Both stores are exercised, in-memory and on-disk, because an in-memory
/// SwiftData fetch is not a claim about a device. The on-disk pass is also run
/// with a co-resident sweep, since `.swrCacheSweep` is a member of the same
/// foreground pass and runs on the same executor.
///
/// These cases assert only that every surface emitted. They exist to produce a
/// table, and 21-02 re-runs them unchanged to produce the second column of it.
@Suite("SWRCache — first-paint fan-out measurement", .serialized)
struct SWRCacheFirstPaintMeasurement {
    // MARK: - Payloads

    /// A row with a `Date` in it deliberately: `JSONDecoder.hlDefault` uses a
    /// `.custom` date strategy that walks up to three formatters per value, and
    /// leaving dates out would measure a decode the app never performs.
    struct Row: Codable, Equatable {
        let id: String
        let name: String
        let amount: Double
        let takenAt: Date
        let note: String
    }

    struct ListPayload: Codable, Equatable {
        let rows: [Row]

        static func of(rowCount: Int) -> ListPayload {
            let base = Date(timeIntervalSince1970: 1_780_000_000)
            return ListPayload(rows: (0 ..< rowCount).map { index in
                Row(
                    id: "row-\(index)",
                    name: "Substanz \(index)",
                    amount: Double(index) * 1.5,
                    takenAt: base.addingTimeInterval(Double(index) * 3600),
                    note: "Nachtrag zur Einnahme \(index), unverändert übernommen"
                )
            })
        }
    }

    struct Surface: Sendable {
        let key: CacheKey
        let rows: Int
        let label: String
    }

    /// The surfaces a foreground pass opens, with the size class each carries.
    /// `medicationsList` is the large one — that is the ordering the operator
    /// reports, medications first and everything below it late.
    static let surfaces: [Surface] = [
        Surface(key: .medicationsList, rows: 400, label: "medicationsList (~77 KB)"),
        Surface(key: .medicationsTodayIntakes(day: "2026-08-24"), rows: 12, label: "medicationsTodayIntakes"),
        Surface(key: .medicationsCompliance(days: 30), rows: 30, label: "medicationsCompliance"),
        Surface(key: .dashboardSummary(day: "2026-08-24"), rows: 4, label: "dashboardSummary (~864 B)"),
        Surface(key: .userProfile, rows: 4, label: "userProfile (~864 B)"),
        Surface(key: .measurementAvailability, rows: 10, label: "measurementAvailability"),
        Surface(key: .insightsComprehensive, rows: 40, label: "insightsComprehensive"),
        Surface(key: .labsResults, rows: 60, label: "labsResults")
    ]

    // MARK: - Harness

    struct SurfaceTiming: Sendable {
        let label: String
        let key: String
        let firstPaintMillis: Double
    }

    static func millis(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    /// Seeds every surface, then opens all of them at once and reports when
    /// each one's first emission landed.
    static func driveFanOut(
        cache: SWRCache,
        recorder: SWRSignpost.Recorder,
        sweepCoResident: Bool
    ) async throws -> [SurfaceTiming] {
        for surface in surfaces {
            let payload = try JSONEncoder.hlDefault.encode(ListPayload.of(rowCount: surface.rows))
            try await cache.write(surface.key, payload: payload)
        }
        let coordinator = SWRCoordinator(cache: cache, reachability: OfflineReachability())
        recorder.reset()

        let clock = ContinuousClock()
        let start = clock.now
        var timings: [SurfaceTiming] = []

        await withTaskGroup(of: SurfaceTiming?.self) { group in
            if sweepCoResident {
                // The sweep member of the same pass, entering the executor at
                // the same instant the surfaces do — which is when it enters
                // on a real launch.
                group.addTask {
                    // Production shape: the age sweep drops the day-old filler
                    // and the cap sweep scans and no-ops. The surfaces under
                    // test are written at `now`, so the measurement is never
                    // sweeping away the thing it is measuring.
                    _ = await coordinator.foregroundMaintenanceSweep(
                        maxAge: 3600,
                        maxRows: SWRCoordinator.defaultMaxRows
                    )
                    return nil
                }
            }
            for surface in surfaces {
                group.addTask {
                    let stream = await coordinator.observe(surface.key, decoding: ListPayload.self) {
                        ListPayload.of(rowCount: 0)
                    }
                    for await state in stream {
                        switch state {
                        case .cached, .empty, .fresh, .failed:
                            return SurfaceTiming(
                                label: surface.label,
                                key: surface.key.canonicalString,
                                firstPaintMillis: millis(clock.now - start)
                            )
                        }
                    }
                    return nil
                }
            }
            for await timing in group {
                if let timing { timings.append(timing) }
            }
        }
        return timings.sorted { $0.firstPaintMillis < $1.firstPaintMillis }
    }

    /// Prints the per-surface table plus the two figures the phase turns on:
    /// how much of each first paint was the surface's own work, and whether any
    /// two surfaces' actor work ever overlapped at all.
    static func report(
        title: String,
        timings: [SurfaceTiming],
        recorder: SWRSignpost.Recorder
    ) {
        let fetches = recorder.records(for: .readFetch)
        let decodes = recorder.records(for: .readDecode)
        let sweeps = recorder.records(for: .sweep)

        print("── SWR first-paint fan-out: \(title) ──")
        print("surface | first paint (ms) | own fetch (ms) | own decode (ms) | queued (ms)")
        for timing in timings {
            let ownFetch = fetches.filter { $0.key == timing.key }.map(\.durationMillis).reduce(0, +)
            let ownDecode = decodes.filter { $0.key == timing.key }.map(\.durationMillis).reduce(0, +)
            let queued = max(0, timing.firstPaintMillis - ownFetch - ownDecode)
            print(
                String(
                    format: "%@ | %.2f | %.3f | %.3f | %.2f",
                    timing.label, timing.firstPaintMillis, ownFetch, ownDecode, queued
                )
            )
        }
        let onActor = (fetches + decodes + sweeps).map(\.durationMillis).reduce(0, +)
        print(String(format: "total time ON the actor across all surfaces: %.2f ms", onActor))
        if let last = timings.last {
            print(String(format: "slowest first paint: %.2f ms (%@)", last.firstPaintMillis, last.label))
        }
        for sweep in sweeps {
            print(String(format: "sweep %@: %.2f ms", sweep.key, sweep.durationMillis))
        }

        // The serialization claim, stated as overlap. Any two decodes of
        // DIFFERENT keys that were in flight at the same instant would falsify
        // it; on a serial executor there are none by construction.
        var overlapping = 0
        for (index, first) in decodes.enumerated() {
            for second in decodes[decodes.index(after: index)...] where first.key != second.key {
                if first.overlaps(second) { overlapping += 1 }
            }
        }
        print("distinct-key decode pairs that overlapped in time: \(overlapping) of \(decodes.count) decodes")
        print("── end ──")
    }

    static func makeOnDiskContainer() throws -> (container: ModelContainer, directory: URL) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("swr-measure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: CacheSchemaV1.self)
        let config = ModelConfiguration(
            "HealthLogCache.measure",
            schema: schema,
            url: directory.appendingPathComponent("cache.sqlite"),
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try (ModelContainer(for: schema, migrationPlan: nil, configurations: [config]), directory)
    }

    // MARK: - Cases

    @Test("Foreground fan-out on an in-memory cache")
    func inMemoryFanOut() async throws {
        let recorder = SWRSignpost.Recorder()
        SWRSignpost.installRecorder(recorder)
        defer { SWRSignpost.installRecorder(nil) }

        let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
        let timings = try await Self.driveFanOut(cache: cache, recorder: recorder, sweepCoResident: false)
        Self.report(title: "in-memory, no sweep", timings: timings, recorder: recorder)
        #expect(timings.count == Self.surfaces.count, "every surface must have produced a first emission")
    }

    @Test("Foreground fan-out on an on-disk cache, sweep off and sweep on")
    func onDiskFanOut() async throws {
        let recorder = SWRSignpost.Recorder()
        SWRSignpost.installRecorder(recorder)
        defer { SWRSignpost.installRecorder(nil) }

        let plain = try Self.makeOnDiskContainer()
        defer { try? FileManager.default.removeItem(at: plain.directory) }
        let plainTimings = try await Self.driveFanOut(
            cache: SWRCache(modelContainer: plain.container),
            recorder: recorder,
            sweepCoResident: false
        )
        Self.report(title: "on-disk, no sweep", timings: plainTimings, recorder: recorder)
        #expect(plainTimings.count == Self.surfaces.count, "every surface must have produced a first emission")

        let swept = try Self.makeOnDiskContainer()
        defer { try? FileManager.default.removeItem(at: swept.directory) }
        let sweptCache = SWRCache(modelContainer: swept.container)
        // A cache with real bulk in it, so the sweep's two `fetchCount` scans,
        // batch delete and `save()` cost what they cost on an engaged user's
        // device rather than on an empty one.
        for index in 0 ..< 400 {
            try await sweptCache.write(
                .dashboardSummary(day: "filler-\(index)"),
                payload: JSONEncoder.hlDefault.encode(ListPayload.of(rowCount: 4)),
                at: Date().addingTimeInterval(-86400)
            )
        }
        recorder.reset()
        let sweptTimings = try await Self.driveFanOut(
            cache: sweptCache,
            recorder: recorder,
            sweepCoResident: true
        )
        Self.report(title: "on-disk, sweep co-resident, 400 filler rows", timings: sweptTimings, recorder: recorder)
        #expect(sweptTimings.count == Self.surfaces.count, "every surface must have produced a first emission")
    }
}
