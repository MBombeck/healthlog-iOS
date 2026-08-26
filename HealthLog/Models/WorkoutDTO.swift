import Foundation

/// Wire-form mirror of `GET /api/workouts` rows + `GET /api/workouts/{id}`
/// (server v1.4.32, route at `src/app/api/workouts/route.ts`).
///
/// The list endpoint runs the cross-source canonical-row picker
/// (`pickCanonicalWorkoutRows()`, v1.4.30) over the filtered set
/// before paginating — duplicate twin workouts (Apple Watch + Withings
/// publishing the same session) collapse to a single row per cluster.
///
/// **Field shape:** server emits `distanceM`, `activeEnergyKcal`,
/// `avgHr`, `maxHr` — iOS mirrors verbatim. `sportType` is the raw
/// HKWorkoutActivityType identifier as a String (the server stores it
/// per-row from the iOS batch ingest). `source` is the upper-case
/// `APPLE_HEALTH` / `WITHINGS` / `MANUAL` / `IMPORT` enum value.
public struct WorkoutListEntryDTO: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sportType: String?
    public let startedAt: Date?
    public let endedAt: Date?
    public let durationSec: Int?
    public let distanceM: Double?
    public let activeEnergyKcal: Double?
    public let avgHr: Double?
    public let maxHr: Double?
    /// Optional — only emitted by `GET /api/workouts/{id}` (list endpoint
    /// drops it to keep the row payload light). Present when the workout's
    /// source ships a per-second minimum HR.
    public let minHr: Double?
    /// Optional — `GET /api/workouts/{id}` only. Apple-Health-sourced
    /// workouts include a step total; Withings rows are typically nil.
    public let stepCount: Int?
    /// Optional — `GET /api/workouts/{id}` only. Elevation gain in metres.
    public let elevationM: Double?
    /// Optional — `GET /api/workouts/{id}` only. Pause time inside the
    /// workout (Apple Watch auto-pause).
    public let pauseDurationSec: Int?
    public let source: String
    public let externalId: String?
    /// Optional — `GET /api/workouts/{id}` only. Identifies the canonical
    /// twin for cross-source-dedup. `canonicalId == id` when the requested
    /// row is the cluster winner; otherwise points at the winner.
    public let canonicalId: String?
    /// Optional — `GET /api/workouts/{id}` only. GeoJSON LineString +
    /// optional per-sample timestamps. nil for sources without GPS
    /// (Withings, manual entries) or when the user denied location
    /// recording on the Watch.
    public let route: WorkoutRouteDTO?
    /// **W-B182** — Optional, `GET /api/workouts/{id}` only. Free-form provider
    /// metadata the server stores per row. WHOOP populates strain / HR-zone
    /// durations / percent-recorded / altitude here (server
    /// `src/lib/whoop/sync-workout.ts`). Decoded permissively so unknown keys
    /// never break the round-trip.
    public let metadata: WorkoutMetadataDTO?
    /// **W-B182** — Optional, `GET /api/workouts/{id}` only. Per-sample HR (and
    /// optional speed / power / cadence) series. Preferred over the local HK
    /// fetch because it works for WHOOP / imported sources that have no HK
    /// origin on this device.
    public let samples: WorkoutSamplesDTO?

    /// **7.8 (#67 enrichment)** — Optional, `GET /api/workouts/{id}` only.
    /// Server-resolved per-workout HR curve with explicit provenance
    /// (`workout_series` stored samples, or `pulse_window` reconstruction).
    /// Consumed as the last fallback for the detail HR chart when neither the
    /// raw `samples` blob nor the local HK fetch yields a curve — it is the only
    /// path that paints a curve for provider workouts (WHOOP / Strava / Fitbit)
    /// on a device that never saw the session in HealthKit.
    public let hrSeries: WorkoutHrSeriesDTO?
    /// **7.8 (#67 enrichment)** — Optional, `GET /api/workouts/{id}` only.
    /// Server-resolved effort-zone distribution (WHOOP device durations, or a
    /// %HRmax fold from the series). Preferred over the raw
    /// `metadata.zoneDurations` WHOOP map because it also covers the computed
    /// (`tanaka`) path for non-WHOOP workouts.
    public let zones: WorkoutZonesDTO?
    /// **7.8 (#67 enrichment)** — Optional, `GET /api/workouts/{id}` only.
    /// Server-computed whole-kilometre splits (distance sports with aligned
    /// route timestamps). nil / empty for indoor or route-less workouts.
    public let splits: [WorkoutSplitDTO]?
    /// **7.8 (#67 enrichment)** — Optional, `GET /api/workouts/{id}` only. The
    /// user's own last-180-days average for this sport (cross-source-collapsed),
    /// rendered as a muted comparison line. Comparison is to the user's own
    /// history only — never a population band (non-diagnostic standard).
    public let sportContext: WorkoutSportContextDTO?

    public init(
        id: String,
        sportType: String?,
        startedAt: Date?,
        endedAt: Date?,
        durationSec: Int?,
        distanceM: Double?,
        activeEnergyKcal: Double?,
        avgHr: Double?,
        maxHr: Double?,
        minHr: Double? = nil,
        stepCount: Int? = nil,
        elevationM: Double? = nil,
        pauseDurationSec: Int? = nil,
        source: String,
        externalId: String?,
        canonicalId: String? = nil,
        route: WorkoutRouteDTO? = nil,
        metadata: WorkoutMetadataDTO? = nil,
        samples: WorkoutSamplesDTO? = nil,
        hrSeries: WorkoutHrSeriesDTO? = nil,
        zones: WorkoutZonesDTO? = nil,
        splits: [WorkoutSplitDTO]? = nil,
        sportContext: WorkoutSportContextDTO? = nil
    ) {
        self.id = id
        self.sportType = sportType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSec = durationSec
        self.distanceM = distanceM
        self.activeEnergyKcal = activeEnergyKcal
        self.avgHr = avgHr
        self.maxHr = maxHr
        self.minHr = minHr
        self.stepCount = stepCount
        self.elevationM = elevationM
        self.pauseDurationSec = pauseDurationSec
        self.source = source
        self.externalId = externalId
        self.canonicalId = canonicalId
        self.route = route
        self.metadata = metadata
        self.samples = samples
        self.hrSeries = hrSeries
        self.zones = zones
        self.splits = splits
        self.sportContext = sportContext
    }
}

// MARK: - Workout metadata (W-B182)

/// Typed view over the server `Workout.metadata` JSON blob (`GET
/// /api/workouts/{id}`). Populated mainly by WHOOP ingest
/// (`src/lib/whoop/sync-workout.ts`). All fields optional + decoded
/// defensively — a row without metadata, or with extra keys we don't model,
/// decodes cleanly to nils.
public struct WorkoutMetadataDTO: Decodable, Sendable, Equatable {
    /// WHOOP strain score (0–21 scale).
    public let whoopWorkoutStrain: Double?
    /// Fraction of the workout WHOOP actually recorded (0–1 or 0–100 depending
    /// on provider; rendered as a percentage).
    public let percentRecorded: Double?
    /// Altitude gained over the workout, metres.
    public let altitudeGainMeter: Double?
    /// Net altitude change, metres.
    public let altitudeChangeMeter: Double?
    /// HR-zone durations keyed by the provider's zone identifier (WHOOP ships
    /// `zone_zero_milli` … `zone_five_milli`, values in milliseconds). Kept as a
    /// raw map so we render whatever zones the provider sends without pinning a
    /// fixed key set.
    public let zoneDurations: [String: Double]?

    public init(
        whoopWorkoutStrain: Double? = nil,
        percentRecorded: Double? = nil,
        altitudeGainMeter: Double? = nil,
        altitudeChangeMeter: Double? = nil,
        zoneDurations: [String: Double]? = nil
    ) {
        self.whoopWorkoutStrain = whoopWorkoutStrain
        self.percentRecorded = percentRecorded
        self.altitudeGainMeter = altitudeGainMeter
        self.altitudeChangeMeter = altitudeChangeMeter
        self.zoneDurations = zoneDurations
    }
}

// MARK: - Workout samples (W-B182)

/// Typed view over the server `WorkoutSamples` blob (`GET /api/workouts/{id}`).
/// JSONB array of `{ t: ISO string, hr?: int, speedMs?, power?, cadence? }`,
/// ordered ascending by `t`. Preferred over the local HK HR fetch because it is
/// source-agnostic (works for WHOOP / imported workouts with no HK origin).
public struct WorkoutSamplesDTO: Decodable, Sendable, Equatable {
    public let sampleCount: Int?
    public let samples: [Sample]

    public struct Sample: Decodable, Sendable, Equatable {
        /// Sample timestamp.
        public let t: Date
        /// Heart rate, beats/min.
        public let hr: Double?
        /// Speed, metres/second.
        public let speedMs: Double?
        /// Power, watts.
        public let power: Double?
        /// Cadence (rpm / spm depending on sport).
        public let cadence: Double?

        public init(t: Date, hr: Double? = nil, speedMs: Double? = nil, power: Double? = nil, cadence: Double? = nil) {
            self.t = t
            self.hr = hr
            self.speedMs = speedMs
            self.power = power
            self.cadence = cadence
        }
    }

    public init(sampleCount: Int?, samples: [Sample]) {
        self.sampleCount = sampleCount
        self.samples = samples
    }

    private enum CodingKeys: String, CodingKey {
        case sampleCount, samples
    }

    /// **M-2.** Tolerant decode: a single malformed sample row (missing/non-ISO
    /// `t`) must NOT abort the whole `GET /api/workouts/{id}` decode and blank the
    /// detail screen. `samples` defaults to `[]` when absent, and bad rows are
    /// skipped while the good ones survive.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sampleCount = try c.decodeIfPresent(Int.self, forKey: .sampleCount)
        guard c.contains(.samples) else {
            samples = []
            return
        }
        var arrayContainer = try c.nestedUnkeyedContainer(forKey: .samples)
        var collected: [Sample] = []
        if let count = arrayContainer.count {
            collected.reserveCapacity(count)
        }
        while !arrayContainer.isAtEnd {
            // Decode each row into a throwing box; skip the row on failure rather
            // than letting one bad sample take out the whole array.
            if let sample = try? arrayContainer.decode(Sample.self) {
                collected.append(sample)
            } else {
                // Advance past the unparseable element so the loop terminates.
                _ = try? arrayContainer.decode(AnyDecodableSkip.self)
            }
        }
        samples = collected
    }
}

/// Consumes one element of an unkeyed container without modelling it — used to
/// advance past a sample row that failed to decode (M-2 tolerant decode).
private struct AnyDecodableSkip: Decodable {}

// MARK: - Workout enrichment (7.8 / #67 — hrSeries · zones · splits · sportContext)

/// Server-resolved per-workout HR curve (`GET /api/workouts/{id}` →
/// `hrSeries`). One code path server-side with explicit provenance: the
/// session's own stored samples (`workout_series`) or a pulse-window
/// reconstruction (`pulse_window`). Points are bucketed at `bucketSec`
/// grain; `tSec` is elapsed seconds from the workout start (not a wall
/// clock), `mean`/`min`/`max` the bpm fold within the bucket.
///
/// Tolerant: `points` defaults to `[]` when absent and skips any bucket
/// that fails to decode, so one malformed row never blanks the detail.
public struct WorkoutHrSeriesDTO: Decodable, Sendable, Equatable {
    /// `"workout_series"` (stored sensor stream) or `"pulse_window"`
    /// (reconstructed from raw PULSE rows around the session).
    public let source: String
    /// Bucket width in seconds (adaptive server-side, 5…60).
    public let bucketSec: Int
    public let points: [Point]
    /// True when per-bucket density supports a min→max envelope band.
    public let envelope: Bool

    public struct Point: Decodable, Sendable, Equatable {
        /// Elapsed seconds from the workout start (bucket left edge).
        public let tSec: Int
        public let mean: Double
        public let min: Double
        public let max: Double

        public init(tSec: Int, mean: Double, min: Double, max: Double) {
            self.tSec = tSec
            self.mean = mean
            self.min = min
            self.max = max
        }
    }

    public init(source: String, bucketSec: Int, points: [Point], envelope: Bool) {
        self.source = source
        self.bucketSec = bucketSec
        self.points = points
        self.envelope = envelope
    }

    private enum CodingKeys: String, CodingKey {
        case source, bucketSec, points, envelope
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        bucketSec = try c.decodeIfPresent(Int.self, forKey: .bucketSec) ?? 0
        envelope = try c.decodeIfPresent(Bool.self, forKey: .envelope) ?? false
        points = Self.decodeTolerantArray(c, forKey: .points)
    }

    /// Decode `points` skipping any bucket that fails to parse (tolerant).
    private static func decodeTolerantArray(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [Point] {
        guard container.contains(key),
              var array = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var collected: [Point] = []
        while !array.isAtEnd {
            if let point = try? array.decode(Point.self) {
                collected.append(point)
            } else {
                _ = try? array.decode(AnyDecodableSkip.self)
            }
        }
        return collected
    }
}

/// Server-resolved effort-zone distribution (`GET /api/workouts/{id}` →
/// `zones`). `model` is `"whoop"` (device-authoritative durations) or
/// `"tanaka"` (%HRmax fold from the series). Each band carries its bpm
/// bounds (nil for the WHOOP-only path and the open-ended top zone) and
/// the time spent, in seconds.
///
/// Tolerant: `zones` defaults to `[]` and skips malformed bands.
public struct WorkoutZonesDTO: Decodable, Sendable, Equatable {
    public let model: String
    /// HRmax used for the band edges; nil on the WHOOP-only path.
    public let hrMax: Double?
    public let zones: [Band]

    public struct Band: Decodable, Sendable, Equatable {
        /// 1…5.
        public let zone: Int
        public let lowBpm: Double?
        public let highBpm: Double?
        public let seconds: Double

        public init(zone: Int, lowBpm: Double?, highBpm: Double?, seconds: Double) {
            self.zone = zone
            self.lowBpm = lowBpm
            self.highBpm = highBpm
            self.seconds = seconds
        }
    }

    public init(model: String, hrMax: Double?, zones: [Band]) {
        self.model = model
        self.hrMax = hrMax
        self.zones = zones
    }

    private enum CodingKeys: String, CodingKey {
        case model, hrMax, zones
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        hrMax = try c.decodeIfPresent(Double.self, forKey: .hrMax)
        guard c.contains(.zones),
              var array = try? c.nestedUnkeyedContainer(forKey: .zones) else
        {
            zones = []
            return
        }
        var collected: [Band] = []
        while !array.isAtEnd {
            if let band = try? array.decode(Band.self) {
                collected.append(band)
            } else {
                _ = try? array.decode(AnyDecodableSkip.self)
            }
        }
        zones = collected
    }
}

/// One whole-kilometre split (`GET /api/workouts/{id}` → `splits[]`).
/// `paceSecPerKm == durationSec` for a whole-km split; both are kept so a
/// caller can render duration and pace without re-deriving.
public struct WorkoutSplitDTO: Decodable, Sendable, Equatable, Identifiable {
    /// 1-based kilometre index — also the `Identifiable` id.
    public let km: Int
    public let durationSec: Int
    public let paceSecPerKm: Int

    public var id: Int {
        km
    }

    public init(km: Int, durationSec: Int, paceSecPerKm: Int) {
        self.km = km
        self.durationSec = durationSec
        self.paceSecPerKm = paceSecPerKm
    }
}

/// The user's own recent average for a sport (`GET /api/workouts/{id}` →
/// `sportContext`). Cross-source twins are collapsed server-side so a run
/// recorded by two paired watches counts once. Comparison is to the user's
/// own history only (non-diagnostic standard).
public struct WorkoutSportContextDTO: Decodable, Sendable, Equatable {
    /// Number of canonical sessions in the 180-day lookback.
    public let count: Int
    public let avgDurationSec: Int
    public let avgDistanceM: Double?
    public let avgAvgHr: Double?

    public init(count: Int, avgDurationSec: Int, avgDistanceM: Double?, avgAvgHr: Double?) {
        self.count = count
        self.avgDurationSec = avgDurationSec
        self.avgDistanceM = avgDistanceM
        self.avgAvgHr = avgAvgHr
    }
}

/// GeoJSON LineString wrapper as emitted by `GET /api/workouts/{id}`.
///
/// **Wire shape** (verbatim from `WorkoutRoute` in `prisma/schema.prisma`):
/// ```
/// {
///   "geometry": { "type": "LineString", "coordinates": [[lon, lat, alt?], ...] },
///   "sampleTimestamps": ["2026-05-15T07:00:00Z", ...]   // optional, may be null
/// }
/// ```
///
/// We decode the geometry permissively — accept any GeoJSON-shaped JSON,
/// but expose `coordinates` as `[[Double]]` so the consumer can render a
/// MapKit polyline directly without re-parsing.
public struct WorkoutRouteDTO: Decodable, Sendable, Equatable {
    public let geometry: Geometry
    /// Per-coordinate timestamps when the source ships them (Apple Health),
    /// otherwise nil (Withings GPX, manual). Decoded via the shared
    /// `APIClient`-level ISO-8601 strategy.
    public let sampleTimestamps: [Date]?

    public struct Geometry: Decodable, Sendable, Equatable {
        public let type: String
        /// `[[lon, lat, alt?], ...]` — GeoJSON LineString format. The
        /// third element (altitude) is optional; consumers must check
        /// `count >= 2` before dereferencing.
        public let coordinates: [[Double]]

        public init(type: String, coordinates: [[Double]]) {
            self.type = type
            self.coordinates = coordinates
        }
    }

    public init(geometry: Geometry, sampleTimestamps: [Date]?) {
        self.geometry = geometry
        self.sampleTimestamps = sampleTimestamps
    }
}

/// Top-level response shape of `GET /api/workouts`. Server emits a
/// `meta` block alongside the rows so the consumer learns the canonical
/// count + how many duplicates the picker dropped this round.
public struct WorkoutListResponseDTO: Decodable, Sendable, Equatable {
    public let workouts: [WorkoutListEntryDTO]
    public let meta: Meta

    public struct Meta: Decodable, Sendable, Equatable {
        public let total: Int
        public let limit: Int
        public let offset: Int
        public let droppedDuplicates: Int

        public init(total: Int, limit: Int, offset: Int, droppedDuplicates: Int) {
            self.total = total
            self.limit = limit
            self.offset = offset
            self.droppedDuplicates = droppedDuplicates
        }
    }

    public init(workouts: [WorkoutListEntryDTO], meta: Meta) {
        self.workouts = workouts
        self.meta = meta
    }
}
