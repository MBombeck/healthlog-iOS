import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// 7.8 (#67 enrichment + #42/#46 source growth) — the richer
/// `GET /api/workouts/{id}` payload fields the detail surface now consumes:
/// `hrSeries`, `zones`, `splits`, `sportContext`, plus the `GOOGLE_HEALTH`
/// (#42) / `STRAVA` (#46) workout-source labels and the unit-adaptive pace
/// formatter.
///
/// Decode is exercised through the real `JSONDecoder.hlDefault` (the same
/// tolerant ISO-8601 date strategy the repos use) — a Stub decoder here would
/// mask a date-strategy drift the way the PROJECT_GUIDE.md audit warns against.
@Suite("Workout enrichment — tolerant decode of hrSeries / zones / splits / sportContext")
struct WorkoutEnrichmentDecodeTests {
    private func decode(_ json: String) throws -> WorkoutListEntryDTO {
        try JSONDecoder.hlDefault.decode(WorkoutListEntryDTO.self, from: Data(json.utf8))
    }

    // MARK: - All fields present

    @Test("Full detail payload decodes every enrichment field")
    func fullPayloadDecodes() throws {
        let dto = try decode(#"""
        {
          "id":"w-1","sportType":"running",
          "startedAt":"2026-05-15T07:00:00Z","endedAt":"2026-05-15T07:30:00Z",
          "durationSec":1800,"distanceM":5000,"activeEnergyKcal":320,
          "avgHr":145,"maxHr":170,"source":"STRAVA","externalId":"strava:123",
          "hrSeries":{"source":"workout_series","bucketSec":10,"envelope":true,
            "points":[{"tSec":0,"mean":120,"min":110,"max":130},
                      {"tSec":10,"mean":150,"min":140,"max":160}]},
          "zones":{"model":"tanaka","hrMax":185,"zones":[
            {"zone":1,"lowBpm":93,"highBpm":111,"seconds":300},
            {"zone":2,"lowBpm":111,"highBpm":130,"seconds":600},
            {"zone":5,"lowBpm":167,"highBpm":null,"seconds":120}]},
          "splits":[{"km":1,"durationSec":330,"paceSecPerKm":330},
                    {"km":2,"durationSec":345,"paceSecPerKm":345}],
          "sportContext":{"count":12,"avgDurationSec":1700,"avgDistanceM":4800,"avgAvgHr":148}
        }
        """#)

        let hr = try #require(dto.hrSeries)
        #expect(hr.source == "workout_series")
        #expect(hr.bucketSec == 10)
        #expect(hr.envelope == true)
        #expect(hr.points.count == 2)
        #expect(hr.points[1].mean == 150)

        let zones = try #require(dto.zones)
        #expect(zones.model == "tanaka")
        #expect(zones.hrMax == 185)
        #expect(zones.zones.count == 3)
        // The open-ended top zone carries a nil upper bound.
        #expect(zones.zones[2].highBpm == nil)
        #expect(zones.zones[2].seconds == 120)

        let splits = try #require(dto.splits)
        #expect(splits.count == 2)
        #expect(splits[0].km == 1)
        #expect(splits[1].paceSecPerKm == 345)

        let ctx = try #require(dto.sportContext)
        #expect(ctx.count == 12)
        #expect(ctx.avgDurationSec == 1700)
        #expect(ctx.avgDistanceM == 4800)
        #expect(ctx.avgAvgHr == 148)
    }

    // MARK: - Fields absent (the common list-row / older-server case)

    @Test("Payload without enrichment fields decodes to nils, never throws")
    func absentFieldsDecodeToNil() throws {
        let dto = try decode(#"""
        {
          "id":"w-2","sportType":"yoga",
          "startedAt":"2026-05-15T07:00:00Z","endedAt":"2026-05-15T07:30:00Z",
          "durationSec":1800,"source":"APPLE_HEALTH","externalId":null
        }
        """#)
        #expect(dto.hrSeries == nil)
        #expect(dto.zones == nil)
        #expect(dto.splits == nil)
        #expect(dto.sportContext == nil)
    }

    // MARK: - Malformed rows inside the arrays (tolerant skip)

    @Test("A malformed hrSeries point is skipped, the good ones survive")
    func hrSeriesSkipsBadPoint() throws {
        // Middle point is missing `mean` → that single row is dropped, the two
        // well-formed buckets survive rather than blanking the whole curve.
        let dto = try decode(#"""
        {
          "id":"w-3","sportType":"running","source":"APPLE_HEALTH","externalId":null,
          "hrSeries":{"source":"pulse_window","bucketSec":30,"envelope":false,
            "points":[{"tSec":0,"mean":100,"min":95,"max":105},
                      {"tSec":30},
                      {"tSec":60,"mean":140,"min":135,"max":150}]}
        }
        """#)
        let hr = try #require(dto.hrSeries)
        #expect(hr.points.count == 2)
        #expect(hr.points[0].tSec == 0)
        #expect(hr.points[1].tSec == 60)
    }

    @Test("A malformed zone band is skipped, the good ones survive")
    func zonesSkipBadBand() throws {
        // Second band is missing the required `zone` field → dropped; the empty
        // `zones` array on a whoop-model object stays an empty list, not a throw.
        let dto = try decode(#"""
        {
          "id":"w-4","sportType":"cycling","source":"WHOOP","externalId":null,
          "zones":{"model":"whoop","hrMax":null,"zones":[
            {"zone":1,"lowBpm":null,"highBpm":null,"seconds":200},
            {"seconds":400},
            {"zone":3,"lowBpm":null,"highBpm":null,"seconds":600}]}
        }
        """#)
        let zones = try #require(dto.zones)
        #expect(zones.model == "whoop")
        #expect(zones.hrMax == nil)
        #expect(zones.zones.count == 2)
        #expect(zones.zones[1].zone == 3)
    }

    @Test("An hrSeries object with no points array decodes to an empty curve")
    func hrSeriesMissingPointsArray() throws {
        let dto = try decode(#"""
        {
          "id":"w-5","sportType":"running","source":"APPLE_HEALTH","externalId":null,
          "hrSeries":{"source":"workout_series","bucketSec":5,"envelope":false}
        }
        """#)
        let hr = try #require(dto.hrSeries)
        #expect(hr.points.isEmpty)
    }
}

/// #42 / #46 — the workout-source enum grew `GOOGLE_HEALTH` and `STRAVA`; the
/// detail surface must render brand labels, not `.capitalized` fallbacks.
@Suite("Workout source labels — GOOGLE_HEALTH / STRAVA parity")
@MainActor
struct WorkoutSourceLabelEnrichmentTests {
    @Test("Provider sources decode and render their brand spellings")
    func providerSourceLabels() {
        // #42 — Google Health API provider; wire token would otherwise fall
        // through to "Google_health".
        #expect(WorkoutDetailView.sourceLabel("GOOGLE_HEALTH") == "Google Health")
        // #46 — Strava OAuth workout ingest.
        #expect(WorkoutDetailView.sourceLabel("STRAVA") == "Strava")
        #expect(WorkoutDetailView.sourceLabel("OURA") == "Oura")
        #expect(WorkoutDetailView.sourceLabel("POLAR") == "Polar")
        #expect(WorkoutDetailView.sourceLabel("NIGHTSCOUT") == "Nightscout")
    }

    @Test("A GOOGLE_HEALTH-sourced workout row decodes + labels end to end")
    func googleHealthRowDecodesAndLabels() throws {
        let dto = try JSONDecoder.hlDefault.decode(
            WorkoutListEntryDTO.self,
            from: Data(#"""
            {"id":"w-g","sportType":"walking","source":"GOOGLE_HEALTH","externalId":"gh:1"}
            """#.utf8)
        )
        #expect(dto.source == "GOOGLE_HEALTH")
        #expect(WorkoutDetailView.sourceLabel(dto.source) == "Google Health")
    }

    // MARK: - Server zones preferred over the legacy metadata map

    @Test("Server-resolved zones win over the legacy metadata.zoneDurations map")
    func serverZonesPreferred() {
        let dto = WorkoutListEntryDTO(
            id: "w-z", sportType: "running", startedAt: nil, endedAt: nil,
            durationSec: nil, distanceM: nil, activeEnergyKcal: nil,
            avgHr: nil, maxHr: nil, source: "APPLE_HEALTH", externalId: nil,
            metadata: WorkoutMetadataDTO(zoneDurations: ["zone_one_milli": 60000]),
            zones: WorkoutZonesDTO(
                model: "tanaka", hrMax: 185,
                zones: [
                    .init(zone: 1, lowBpm: 93, highBpm: 111, seconds: 120),
                    .init(zone: 4, lowBpm: 148, highBpm: 167, seconds: 240)
                ]
            )
        )
        let resolved = WorkoutDetailView.resolvedZones(from: dto)
        // Two server bands (120 s + 240 s), NOT the single 60 s metadata band.
        #expect(resolved.count == 2)
        #expect(resolved[0].index == 1)
        #expect(resolved[1].index == 4)
        #expect(resolved[1].seconds == 240)
    }

    @Test("Zones fall back to the metadata map when the server sends none")
    func zonesFallBackToMetadata() {
        let dto = WorkoutListEntryDTO(
            id: "w-z2", sportType: "cycling", startedAt: nil, endedAt: nil,
            durationSec: nil, distanceM: nil, activeEnergyKcal: nil,
            avgHr: nil, maxHr: nil, source: "WHOOP", externalId: nil,
            metadata: WorkoutMetadataDTO(zoneDurations: ["zone_two_milli": 90000])
        )
        let resolved = WorkoutDetailView.resolvedZones(from: dto)
        #expect(resolved.count == 1)
        #expect(resolved[0].index == 2)
        #expect(resolved[0].seconds == 90)
    }
}

/// 7.8 — unit-adaptive pace formatter (min/km · min/mi).
@Suite("WorkoutFormatter — pace formatter (metric + imperial)")
struct WorkoutPaceFormatterTests {
    private let metric = Locale(identifier: "de_DE")
    private let imperial = Locale(identifier: "en_US")

    @Test("Metric locale renders min/km")
    func metricPace() {
        #expect(WorkoutFormatter.usesImperialPace(metric) == false)
        // 330 s/km → 5:30 /km.
        #expect(WorkoutFormatter.paceLabel(secondsPerKm: 330, locale: metric) == "5:30 /km")
    }

    @Test("US locale converts to min/mi")
    func imperialPace() {
        #expect(WorkoutFormatter.usesImperialPace(imperial) == true)
        // 330 s/km × 1.609344 = 531.08 s/mi → 8:51 /mi.
        #expect(WorkoutFormatter.paceLabel(secondsPerKm: 330, locale: imperial) == "8:51 /mi")
    }

    @Test("Non-positive pace yields nil rather than 0:00")
    func nonPositivePaceIsNil() {
        #expect(WorkoutFormatter.paceLabel(secondsPerKm: 0) == nil)
        #expect(WorkoutFormatter.paceLabel(secondsPerKm: -5) == nil)
    }

    @Test("Pace-from-totals derives km-pace then formats")
    func paceFromTotals() {
        // 5000 m in 1500 s → 300 s/km → 5:00 /km.
        #expect(WorkoutFormatter.paceLabel(metres: 5000, durationSec: 1500, locale: metric) == "5:00 /km")
        #expect(WorkoutFormatter.paceLabel(metres: 0, durationSec: 1500, locale: metric) == nil)
        #expect(WorkoutFormatter.paceLabel(metres: 5000, durationSec: 0, locale: metric) == nil)
    }
}

/// 7.8 — the server-resolved `hrSeries` fallback mapping into the chart's
/// `WorkoutHRSample` shape (the curve path for provider workouts with no HK
/// origin on this device).
@Suite("WorkoutsStore — server hrSeries fallback mapping")
@MainActor
struct WorkoutHrSeriesFallbackTests {
    @Test("hrSeries points map to elapsed wall-clock timestamps + mean bpm")
    func hrSeriesMapsToSamples() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let series = WorkoutHrSeriesDTO(
            source: "pulse_window", bucketSec: 30,
            points: [
                .init(tSec: 0, mean: 110, min: 100, max: 120),
                .init(tSec: 30, mean: 0, min: 0, max: 0),
                .init(tSec: 60, mean: 150, min: 140, max: 160)
            ],
            envelope: false
        )
        let samples = try #require(WorkoutsStore.hrSeries(from: series, startedAt: start))
        // The zero-mean bucket is dropped (no honest bpm), the two real ones stay.
        #expect(samples.count == 2)
        #expect(samples[0].bpm == 110)
        #expect(samples[0].timestamp == start)
        #expect(samples[1].timestamp == start.addingTimeInterval(60))
    }

    @Test("hrSeries fallback needs a start anchor, else nil")
    func hrSeriesNeedsStart() {
        let series = WorkoutHrSeriesDTO(
            source: "workout_series", bucketSec: 5,
            points: [.init(tSec: 0, mean: 120, min: 110, max: 130)],
            envelope: false
        )
        #expect(WorkoutsStore.hrSeries(from: series, startedAt: nil) == nil)
        #expect(WorkoutsStore.hrSeries(from: nil, startedAt: Date()) == nil)
    }
}

// swiftlint:enable force_unwrapping
