import Foundation
@testable import HealthLog
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **v1.15 W-WORKOUT** — pins the pure `HKWorkout` → ``WorkoutIngestDTO``
    /// mapping: sport-type folding (incl. the `"other"` long-tail fallback),
    /// the server-contract field invariants (HR clamp to `[20, 300]`,
    /// negative-value drop, degenerate-window rejection), the `APPLE_HEALTH`
    /// source spelling, and the externalId-as-dedup-key pass-through. The
    /// transform is pure (no `HKHealthStore`, no network) so it needs no auth.
    @Suite("Workouts — HealthKit mapping")
    struct WorkoutHealthKitMappingTests {
        private struct SeriesSource: WorkoutHeartRateSeriesSyncServicing {
            let outcome: WorkoutHeartRateSeriesOutcome

            func heartRateSeriesOutcome(
                from _: Date,
                to _: Date
            ) async -> WorkoutHeartRateSeriesOutcome {
                outcome
            }
        }

        private let start = Date(timeIntervalSince1970: 1_700_000_000)
        private var end: Date {
            start.addingTimeInterval(3600)
        }

        @Test("sport-type folds known activity types onto the server enum")
        func sportTypeFolding() {
            #expect(WorkoutHealthKitMapping.sportType(for: .running) == "running")
            #expect(WorkoutHealthKitMapping.sportType(for: .cycling) == "cycling")
            #expect(WorkoutHealthKitMapping.sportType(for: .walking) == "walking")
            #expect(WorkoutHealthKitMapping.sportType(for: .traditionalStrengthTraining) == "strength")
            #expect(WorkoutHealthKitMapping.sportType(for: .functionalStrengthTraining) == "strength")
            #expect(WorkoutHealthKitMapping.sportType(for: .highIntensityIntervalTraining) == "hiit")
            #expect(WorkoutHealthKitMapping.sportType(for: .yoga) == "yoga")
            #expect(WorkoutHealthKitMapping.sportType(for: .pilates) == "mindAndBody")
        }

        @Test("niche / unmapped activity types fall back to 'other'")
        func sportTypeFallback() {
            // Archery has no first-class server enum member → must fold to the
            // server's own long-tail bucket so the workout still ingests.
            #expect(WorkoutHealthKitMapping.sportType(for: .archery) == "other")
            #expect(WorkoutHealthKitMapping.sportType(for: .fishing) == "other")
        }

        @Test("makeDTO maps the full happy path with APPLE_HEALTH source + externalId")
        func makeDTOHappyPath() throws {
            let dto = try #require(WorkoutHealthKitMapping.makeDTO(
                activityType: .running,
                start: start,
                end: end,
                energyKcal: 420.5,
                distanceM: 8000,
                avgHr: 145.4,
                maxHr: 178.6,
                minHr: 92.1,
                steps: 9123.7,
                externalId: "ABCDEF01-2345-6789-ABCD-EF0123456789"
            ))
            #expect(dto.sportType == "running")
            #expect(dto.startedAt == start)
            #expect(dto.endedAt == end)
            #expect(dto.totalEnergyKcal == 420.5)
            #expect(dto.totalDistanceM == 8000)
            #expect(dto.avgHeartRate == 145) // rounded
            #expect(dto.maxHeartRate == 179) // rounded
            #expect(dto.minHeartRate == 92) // rounded
            #expect(dto.stepCount == 9124) // rounded
            #expect(dto.source == "APPLE_HEALTH")
            #expect(dto.externalId == "ABCDEF01-2345-6789-ABCD-EF0123456789")
        }

        @Test("degenerate window (end <= start) is rejected so the batch never trips the Zod gate")
        func degenerateWindowRejected() {
            #expect(WorkoutHealthKitMapping.makeDTO(
                activityType: .running, start: start, end: start, // equal
                energyKcal: nil, distanceM: nil, avgHr: nil, maxHr: nil, minHr: nil, steps: nil,
                externalId: "x"
            ) == nil)
            #expect(WorkoutHealthKitMapping.makeDTO(
                activityType: .running, start: end, end: start, // inverted
                energyKcal: nil, distanceM: nil, avgHr: nil, maxHr: nil, minHr: nil, steps: nil,
                externalId: "x"
            ) == nil)
        }

        @Test("out-of-band HR is clamped to nil so a sensor glitch can't fail ingest")
        func hrClamp() {
            #expect(WorkoutHealthKitMapping.clampHr(0) == nil) // below the 20-bpm floor
            #expect(WorkoutHealthKitMapping.clampHr(19) == nil)
            #expect(WorkoutHealthKitMapping.clampHr(20) == 20)
            #expect(WorkoutHealthKitMapping.clampHr(300) == 300)
            #expect(WorkoutHealthKitMapping.clampHr(301) == nil) // above the 300-bpm ceiling
            #expect(WorkoutHealthKitMapping.clampHr(Double.nan) == nil)
            #expect(WorkoutHealthKitMapping.clampHr(nil) == nil)
        }

        @Test("negative energy / distance / steps are dropped (server min(0) bound)")
        func negativeValuesDropped() throws {
            let dto = try #require(WorkoutHealthKitMapping.makeDTO(
                activityType: .cycling,
                start: start,
                end: end,
                energyKcal: -5,
                distanceM: -100,
                avgHr: nil,
                maxHr: nil,
                minHr: nil,
                steps: -10,
                externalId: nil
            ))
            #expect(dto.totalEnergyKcal == nil)
            #expect(dto.totalDistanceM == nil)
            #expect(dto.stepCount == nil)
            // externalId is allowed to be nil (manual-style); the source still
            // pins APPLE_HEALTH for the HK path.
            #expect(dto.externalId == nil)
            #expect(dto.source == "APPLE_HEALTH")
        }

        @Test("ingest DTO encodes to the server batch wire shape with offset timestamps")
        func encodesToWireShape() throws {
            let dto = try #require(WorkoutHealthKitMapping.makeDTO(
                activityType: .running, start: start, end: end,
                energyKcal: 100, distanceM: nil, avgHr: 150, maxHr: nil, minHr: nil, steps: nil,
                externalId: "uuid-1"
            ))
            let data = try JSONEncoder.hlBatch.encode(WorkoutBatchPayload(workouts: [dto]))
            let json = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let workouts = try #require(json["workouts"] as? [[String: Any]])
            #expect(workouts.count == 1)
            let first = try #require(workouts.first)
            #expect(first["sportType"] as? String == "running")
            #expect(first["source"] as? String == "APPLE_HEALTH")
            #expect(first["externalId"] as? String == "uuid-1")
            #expect(first["avgHeartRate"] as? Int == 150)
            // ISO-8601 with offset (the `.hlBatch` `.iso8601` strategy).
            let started = try #require(first["startedAt"] as? String)
            #expect(started.contains("T"))
            #expect(started.hasSuffix("Z") || started.contains("+"))
            // Distance was nil → must be omitted, not encoded as null.
            #expect(first["totalDistanceM"] == nil)
            // GH #86 — no series passed → the field is absent, never `[]`.
            #expect(first["samples"] == nil)
        }

        // MARK: - GH #86 — the per-session HR series

        @Test("hrSamples passes HealthKit through verbatim, only rounding to the schema's int bpm")
        func hrSamplesPassThrough() throws {
            let series = [
                WorkoutHRSample(timestamp: start, bpm: 121.4),
                WorkoutHRSample(timestamp: start.addingTimeInterval(5), bpm: 122.6),
                WorkoutHRSample(timestamp: start.addingTimeInterval(10), bpm: 130)
            ]
            let rows = try #require(WorkoutHealthKitMapping.hrSamples(from: series))
            // Same count, same order, same instants — no smoothing, no
            // bucketing, no interpolation.
            #expect(rows.count == 3)
            #expect(rows.map(\.t) == series.map(\.timestamp))
            #expect(rows.map(\.hr) == [121, 123, 130])
        }

        @Test("out-of-band readings drop their row, not the batch")
        func hrSamplesClampBand() throws {
            let series = [
                WorkoutHRSample(timestamp: start, bpm: 5), // sensor glitch, below 20
                WorkoutHRSample(timestamp: start.addingTimeInterval(5), bpm: 140),
                WorkoutHRSample(timestamp: start.addingTimeInterval(10), bpm: 400) // above 300
            ]
            let rows = try #require(WorkoutHealthKitMapping.hrSamples(from: series))
            #expect(rows.count == 1)
            #expect(rows.first?.hr == 140)
        }

        @Test("a workout without usable HR OMITS samples — an empty array would 422 the batch")
        func hrSamplesEmptyMeansOmitted() throws {
            // The server schema is `.min(1, "samples requires at least 1 point")`,
            // so `samples: []` fails the WHOLE batch. Absence is also the honest
            // statement: "we have nothing to add", not "measured, zero points".
            #expect(WorkoutHealthKitMapping.hrSamples(from: []) == nil)
            #expect(WorkoutHealthKitMapping.hrSamples(
                from: [WorkoutHRSample(timestamp: start, bpm: 0)]
            ) == nil)

            let dto = try #require(WorkoutHealthKitMapping.makeDTO(
                activityType: .yoga, start: start, end: end,
                energyKcal: nil, distanceM: nil, avgHr: nil, maxHr: nil, minHr: nil, steps: nil,
                externalId: "no-hr", samples: nil
            ))
            #expect(dto.samples == nil)
            let data = try JSONEncoder.hlBatch.encode(WorkoutBatchPayload(workouts: [dto]))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let first = try #require((json["workouts"] as? [[String: Any]])?.first)
            #expect(first["samples"] == nil)
        }

        @Test("samples encode to the server's `{ t, hr }` wire rows with offset timestamps")
        func samplesEncodeToWireShape() throws {
            let rows = try #require(WorkoutHealthKitMapping.hrSamples(from: [
                WorkoutHRSample(timestamp: start, bpm: 118.2),
                WorkoutHRSample(timestamp: start.addingTimeInterval(5), bpm: 124.9)
            ]))
            let dto = try #require(WorkoutHealthKitMapping.makeDTO(
                activityType: .running, start: start, end: end,
                energyKcal: nil, distanceM: nil, avgHr: 121, maxHr: nil, minHr: nil, steps: nil,
                externalId: "uuid-hr", samples: rows
            ))
            let data = try JSONEncoder.hlBatch.encode(WorkoutBatchPayload(workouts: [dto]))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let first = try #require((json["workouts"] as? [[String: Any]])?.first)
            let samples = try #require(first["samples"] as? [[String: Any]])
            #expect(samples.count == 2)
            #expect(Set(samples[0].keys) == Set(["t", "hr"]))
            #expect(Set(samples[1].keys) == Set(["t", "hr"]))
            // `t`: same ISO-8601 strategy the already-accepted `startedAt` uses
            // (`z.iso.datetime({ offset: true })` takes the `Z` form).
            let stamp = try #require(samples.first?["t"] as? String)
            #expect(stamp.contains("T"))
            #expect(stamp.hasSuffix("Z") || stamp.contains("+"))
            // `hr`: the schema demands an INT, not a double.
            #expect(samples.first?["hr"] as? Int == 118)
            #expect(samples.last?["hr"] as? Int == 125)
        }

        @Test("series ride along on small batches; a bulk backfill leaves them to the sweep")
        func seriesAttachPolicy() {
            #expect(WorkoutHealthKitImporter.shouldAttachSeries(workoutCount: 1))
            #expect(WorkoutHealthKitImporter.shouldAttachSeries(
                workoutCount: WorkoutIngestDTO.maxWorkoutsPerSeriesBatch
            ))
            // One over the series batch cap: a bulk page would mean hundreds of
            // HK queries and a body against the route's 5 MB ceiling.
            #expect(!WorkoutHealthKitImporter.shouldAttachSeries(
                workoutCount: WorkoutIngestDTO.maxWorkoutsPerSeriesBatch + 1
            ))
            #expect(!WorkoutHealthKitImporter.shouldAttachSeries(workoutCount: 400))
        }

        @Test("sync mapper preserves every series disposition")
        func typedSeriesDispositions() async {
            let notRequested = await WorkoutHealthKitMapping.ingestDisposition(
                activityType: .running,
                start: start,
                end: end,
                externalId: "fixture"
            )
            guard case let .notRequested(dto) = notRequested else {
                Issue.record("expected notRequested mapping")
                return
            }
            #expect(dto.samples == nil)

            let samples = [
                WorkoutHRSample(timestamp: start, bpm: 121.4),
                WorkoutHRSample(timestamp: start.addingTimeInterval(5), bpm: 122.6)
            ]
            let attached = await WorkoutHealthKitMapping.ingestDisposition(
                activityType: .running,
                start: start,
                end: end,
                externalId: "fixture",
                series: SeriesSource(outcome: .samples(samples))
            )
            guard case let .attached(dto) = attached else {
                Issue.record("expected attached mapping")
                return
            }
            #expect(dto.samples?.map(\.t) == samples.map(\.timestamp))
            #expect(dto.samples?.map(\.hr) == [121, 123])

            let empty = await WorkoutHealthKitMapping.ingestDisposition(
                activityType: .running,
                start: start,
                end: end,
                externalId: "fixture",
                series: SeriesSource(outcome: .samples([]))
            )
            guard case let .empty(dto) = empty else {
                Issue.record("expected successful empty mapping")
                return
            }
            #expect(dto.samples == nil)

            #expect(await WorkoutHealthKitMapping.ingestDisposition(
                activityType: .running,
                start: start,
                end: end,
                externalId: "fixture",
                series: SeriesSource(outcome: .failed(.query))
            ) == .failed(.query))
            #expect(await WorkoutHealthKitMapping.ingestDisposition(
                activityType: .running,
                start: start,
                end: end,
                externalId: "fixture",
                series: SeriesSource(outcome: .cancelled)
            ) == .cancelled)
        }

        @Test("structurally invalid workout skips without querying series")
        func invalidWorkoutSkipsBeforeSeriesQuery() async {
            #expect(await WorkoutHealthKitMapping.ingestDisposition(
                activityType: .running,
                start: start,
                end: start,
                externalId: "fixture",
                series: SeriesSource(outcome: .failed(.query))
            ) == .skipped)
        }
    }

#endif
