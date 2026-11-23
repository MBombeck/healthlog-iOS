import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    enum WorkoutHealthKitMappingDisposition: Sendable, Equatable {
        case notRequested(WorkoutIngestDTO)
        case attached(WorkoutIngestDTO)
        case empty(WorkoutIngestDTO)
        case failed(WorkoutHeartRateSeriesFailure)
        case cancelled
        case skipped

        var dto: WorkoutIngestDTO? {
            switch self {
            case let .notRequested(dto), let .attached(dto), let .empty(dto):
                dto
            case .failed, .cancelled, .skipped:
                nil
            }
        }
    }

    /// **v1.15 W-WORKOUT — pure `HKWorkout` → ``WorkoutIngestDTO`` mapping.**
    ///
    /// Split out of ``WorkoutHealthKitImporter`` so the activity-type folding
    /// and the heart-rate / energy / distance extraction are hermetically
    /// testable without booting a real `HKHealthStore` (which simulators
    /// auth-deny by default). The importer owns the observer / anchor / upload
    /// lifecycle; this enum owns the wire shape.
    ///
    /// **Sport-type folding.** Maps `HKWorkoutActivityType` onto the locked
    /// server sport-type enum (`workoutSportTypeEnum` in
    /// `src/lib/validations/workout.ts`). The server's roster covers ≥98 % of
    /// typical workouts; anything outside it folds to `"other"` (the server's
    /// own long-tail bucket) so a niche activity still ingests rather than
    /// failing the Zod gate.
    ///
    /// **Anti-duplicate.** The importer applies the echo guard
    /// (`HKMetadataKeyExternalUUID`) before calling
    /// ``ingestDisposition(from:series:)`` — this mapper is unconditional, so
    /// unit tests can assert the guard separately via ``isOwnEcho(_:)``.
    enum WorkoutHealthKitMapping {
        /// Lookup table from `HKWorkoutActivityType` to the server's sport-type
        /// enum string. A dictionary (rather than a giant `switch`) keeps the
        /// fold below the cyclomatic-complexity gate and makes the long tail
        /// trivially extensible. Anything not present folds to `"other"`.
        private static let sportTypeByActivity: [HKWorkoutActivityType: String] = [
            .walking: "walking",
            .running: "running",
            .cycling: "cycling",
            .hiking: "hiking",
            .swimming: "swimming",
            .swimBikeRun: "swimming",
            .waterFitness: "swimming",
            .rowing: "rowing",
            .elliptical: "elliptical",
            .stairClimbing: "stairClimber",
            .stairs: "stairClimber",
            .stepTraining: "stairClimber",
            .yoga: "yoga",
            .mindAndBody: "mindAndBody",
            .pilates: "mindAndBody",
            .barre: "mindAndBody",
            .flexibility: "mindAndBody",
            .traditionalStrengthTraining: "strength",
            .functionalStrengthTraining: "strength",
            .highIntensityIntervalTraining: "hiit",
            .cardioDance: "dance",
            .socialDance: "dance",
            .golf: "golf",
            .tennis: "tennis",
            .basketball: "basketball",
            .soccer: "soccer",
            .crossTraining: "crossTraining",
            .mixedCardio: "mixedCardio",
            // Types that had a server bucket but folded to "other".
            // `badminton` is a literal of the server enum since v1.32.8 (the
            // list already titles it); the rest fold onto the bucket whose
            // activity they are, never onto a guess.
            .badminton: "badminton",
            .coreTraining: "strength",
            .cooldown: "mindAndBody",
            .preparationAndRecovery: "mindAndBody",
            .taiChi: "mindAndBody",
            .handCycling: "cycling",
            .wheelchairWalkPace: "walking",
            .wheelchairRunPace: "running",
            .jumpRope: "mixedCardio"
        ]

        /// Every sport-type string the server accepts (`workoutSportTypeEnum`
        /// in `src/lib/validations/workout.ts`, `release/v1.42.0`). The fold
        /// never emits anything outside this set: a table entry pointing at an
        /// unknown token would 422 the whole batch, so it degrades to "other".
        static let serverSportTypes: Set<String> = [
            "walking", "running", "cycling", "hiking", "swimming", "rowing", "elliptical",
            "stairClimber", "yoga", "mindAndBody", "strength", "hiit", "dance", "golf",
            "badminton", "tennis", "basketball", "soccer", "crossTraining", "mixedCardio", "other"
        ]

        /// Fold an `HKWorkoutActivityType` to the server's sport-type string.
        /// Unknown / niche types land as `"other"` (the server's own long-tail
        /// bucket) so a workout always ingests rather than failing the Zod gate.
        static func sportType(for activityType: HKWorkoutActivityType) -> String {
            guard let mapped = sportTypeByActivity[activityType], serverSportTypes.contains(mapped) else {
                return "other"
            }
            return mapped
        }

        /// The table itself, for the test that walks every entry.
        static var mappedActivityTypes: [HKWorkoutActivityType: String] {
            sportTypeByActivity
        }

        /// `true` when the workout is OUR own write echoing back — it carries
        /// our `HKMetadataKeyExternalUUID` marker AND was authored by this
        /// app's own HK source. The importer skips these to honour the
        /// PROJECT_GUIDE.md anti-duplicate rule.
        ///
        /// Routes through ``HealthKitSampleOwnership`` so
        /// a third-party workout that happens to carry an externalUUID is no
        /// longer silently dropped (different source ⇒ imported).
        static func isOwnEcho(_ workout: HKWorkout) -> Bool {
            HealthKitSampleOwnership.isOwnEcho(workout)
        }

        /// Map an `HKWorkout` to the wire DTO. Returns `nil` for a degenerate
        /// window (`endDate <= startDate`) so the server's strict
        /// `endedAt > startedAt` superRefine never rejects the whole batch on
        /// one bogus sample.
        ///
        /// - `totalEnergyKcal` / `totalDistanceM`: prefer the workout's own
        ///   summary quantities; both are optional on `HKWorkout` and absent
        ///   for many indoor / imported sessions.
        /// - avg / max / min HR: read from the per-workout `statistics(for:)`
        ///   HR aggregate when the source attached it (Apple Watch sessions
        ///   do; phone-only / imported workouts may not). Rounded to the int
        ///   beats/min the server schema requires; clamped to the server's
        ///   `[20, 300]` accepted band so an out-of-range sensor glitch can't
        ///   fail the Zod gate.
        /// - `stepCount`: from the step-count statistics aggregate when present.
        /// - `source`: always `"APPLE_HEALTH"` (the exact `MeasurementSource`
        ///   spelling — not "HEALTHKIT").
        /// - `externalId`: the `HKWorkout` `uuid.uuidString`, the server's
        ///   dedup key.
        /// - `samples`: when a `series` source is handed in, the
        ///   per-session HR curve for `[startDate, endDate]` is fetched and
        ///   attached; `nil` keeps the call series-free (and query-free). See
        ///   ``WorkoutHealthKitImporter/shouldAttachSeries(workoutCount:)`` for
        ///   when we spend that query and when the backfill sweep takes over.
        ///   That fetch is the ONLY reason this function is `async`.
        static func ingestDisposition(
            from workout: HKWorkout,
            series: (any WorkoutHeartRateSeriesSyncServicing)? = nil
        ) async -> WorkoutHealthKitMappingDisposition {
            let kcalUnit = HKUnit.kilocalorie()
            let meterUnit = HKUnit.meter()
            let hrUnit = HKUnit.count().unitDivided(by: .minute())
            let hrStats = workout.statistics(for: HKQuantityType(.heartRate))
            let stepStats = workout.statistics(for: HKQuantityType(.stepCount))

            // iOS 18 deprecated `HKWorkout.totalEnergyBurned` / `.totalDistance`
            // in favour of the per-workout `statistics(for:)` aggregates. Active
            // energy is the canonical "kcal burned during the session"; distance
            // is activity-dependent (walk/run vs cycle vs swim), so we sum the
            // first distance channel the workout carries.
            let energyKcal = workout
                .statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?
                .doubleValue(for: kcalUnit)
            let distanceM = distanceMeters(from: workout, meterUnit: meterUnit)
            let ascended = (workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity)?
                .doubleValue(for: meterUnit)

            return await ingestDisposition(
                activityType: workout.workoutActivityType,
                start: workout.startDate,
                end: workout.endDate,
                energyKcal: energyKcal,
                distanceM: distanceM,
                avgHr: hrStats?.averageQuantity()?.doubleValue(for: hrUnit),
                maxHr: hrStats?.maximumQuantity()?.doubleValue(for: hrUnit),
                minHr: hrStats?.minimumQuantity()?.doubleValue(for: hrUnit),
                steps: stepStats?.sumQuantity()?.doubleValue(for: .count()),
                elevationM: elevationMeters(ascended: ascended),
                pauseDurationSec: pauseDurationSeconds(
                    events: (workout.workoutEvents ?? []).map { ($0.type, $0.dateInterval.start) },
                    start: workout.startDate,
                    end: workout.endDate
                ),
                externalId: workout.uuid.uuidString,
                series: series
            )
        }

        /// The server's band for `elevationM` (`createWorkoutSchema`: −500…10 000 m).
        /// A value outside it would fail the whole batch, so it is left out.
        static func elevationMeters(ascended: Double?) -> Double? {
            guard let ascended, ascended.isFinite, (-500 ... 10000).contains(ascended) else { return nil }
            return ascended
        }

        /// Seconds between each pause and the resume after it, manual and
        /// automatic alike, clipped to the workout. A pause never resumed runs
        /// to the end. `nil` when the workout has no pause event at all, so a
        /// workout without the data is not claimed to have had no pause.
        static func pauseDurationSeconds(
            events: [(type: HKWorkoutEventType, date: Date)],
            start: Date,
            end: Date
        ) -> Int? {
            guard end > start else { return nil }
            let ordered = events.sorted { $0.date < $1.date }
            guard ordered.contains(where: { $0.type == .pause || $0.type == .motionPaused }) else { return nil }
            var total: TimeInterval = 0
            var pausedAt: Date?
            for event in ordered {
                let date = min(max(event.date, start), end)
                switch event.type {
                case .pause, .motionPaused:
                    if pausedAt == nil { pausedAt = date }
                case .resume, .motionResumed:
                    if let since = pausedAt {
                        total += date.timeIntervalSince(since)
                        pausedAt = nil
                    }
                default:
                    break
                }
            }
            if let since = pausedAt {
                total += end.timeIntervalSince(since)
            }
            let seconds = Int(total.rounded())
            // The server takes 0…86 400; a longer workout cannot pause longer
            // than it lasted, so the cap only guards against bad event data.
            return min(max(seconds, 0), 86400)
        }

        static func ingestDisposition(
            activityType: HKWorkoutActivityType,
            start: Date,
            end: Date,
            energyKcal: Double? = nil,
            distanceM: Double? = nil,
            avgHr: Double? = nil,
            maxHr: Double? = nil,
            minHr: Double? = nil,
            steps: Double? = nil,
            elevationM: Double? = nil,
            pauseDurationSec: Int? = nil,
            externalId: String?,
            series: (any WorkoutHeartRateSeriesSyncServicing)? = nil
        ) async -> WorkoutHealthKitMappingDisposition {
            guard let base = makeDTO(
                activityType: activityType,
                start: start,
                end: end,
                energyKcal: energyKcal,
                distanceM: distanceM,
                avgHr: avgHr,
                maxHr: maxHr,
                minHr: minHr,
                steps: steps,
                elevationM: elevationM,
                pauseDurationSec: pauseDurationSec,
                externalId: externalId
            ) else {
                return .skipped
            }
            guard let series else { return .notRequested(base) }

            switch await series.heartRateSeriesOutcome(from: start, to: end) {
            case let .samples(samples):
                guard let rows = hrSamples(from: samples) else { return .empty(base) }
                guard let dto = makeDTO(
                    activityType: activityType,
                    start: start,
                    end: end,
                    energyKcal: energyKcal,
                    distanceM: distanceM,
                    avgHr: avgHr,
                    maxHr: maxHr,
                    minHr: minHr,
                    steps: steps,
                    elevationM: elevationM,
                    pauseDurationSec: pauseDurationSec,
                    externalId: externalId,
                    samples: rows
                ) else {
                    return .skipped
                }
                return .attached(dto)
            case let .failed(failure):
                return .failed(failure)
            case .cancelled:
                return .cancelled
            }
        }

        /// Fold the HK HR series into the server's `samples` wire
        /// rows. Pure: no smoothing, no interpolation, no bucketing — we pass
        /// on exactly what HealthKit measured, one row per sample, in the order
        /// the query returned them.
        ///
        /// The only transforms are the two the Zod schema forces: `hr` must be
        /// an INT in `[20, 300]` (``clampHr(_:)``, shared with the aggregates),
        /// and a reading outside that band drops its row rather than the whole
        /// batch. Returns `nil` — meaning "omit the field" — when nothing
        /// usable survives: the schema is `.min(1)`, so `samples: []` would 422
        /// the entire batch, and "no series" is honestly said by absence.
        static func hrSamples(from series: [WorkoutHRSample]) -> [WorkoutIngestDTO.Sample]? {
            let rows = series.compactMap { sample -> WorkoutIngestDTO.Sample? in
                guard let bpm = clampHr(sample.bpm) else { return nil }
                return WorkoutIngestDTO.Sample(t: sample.timestamp, hr: bpm)
            }
            guard !rows.isEmpty else { return nil }
            guard rows.count > WorkoutIngestDTO.maxSamplesPerWorkout else { return rows }
            // Operator-grade constant (a compile-time cap), no health data.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.warning(
                "workout HR series over the server cap — truncating to \(WorkoutIngestDTO.maxSamplesPerWorkout, privacy: .public) points"
            )
            return Array(rows.prefix(WorkoutIngestDTO.maxSamplesPerWorkout))
        }

        /// The distance quantity type depends on the activity (walking/running,
        /// cycling, swimming, wheelchair, downhill snow sports). Probe the
        /// common channels in priority order and return the first summed
        /// distance the workout carries, in metres.
        private static func distanceMeters(from workout: HKWorkout, meterUnit: HKUnit) -> Double? {
            let distanceIdentifiers: [HKQuantityTypeIdentifier] = [
                .distanceWalkingRunning,
                .distanceCycling,
                .distanceSwimming,
                .distanceWheelchair,
                .distanceDownhillSnowSports
            ]
            for identifier in distanceIdentifiers {
                if let sum = workout
                    .statistics(for: HKQuantityType(identifier))?
                    .sumQuantity()?
                    .doubleValue(for: meterUnit)
                {
                    return sum
                }
            }
            return nil
        }

        /// Pure DTO builder — the testable core of
        /// ``ingestDisposition(from:series:)``. Takes the already-extracted
        /// primitive values so it can be exercised without
        /// constructing a live `HKWorkout` (which requires a store / builder).
        /// Applies the same invariants the server's Zod schema enforces:
        /// rejects a degenerate window (`end <= start`), clamps HR to `[20, 300]`,
        /// drops negative energy / distance / step values.
        static func makeDTO(
            activityType: HKWorkoutActivityType,
            start: Date,
            end: Date,
            energyKcal: Double?,
            distanceM: Double?,
            avgHr: Double?,
            maxHr: Double?,
            minHr: Double?,
            steps: Double?,
            elevationM: Double? = nil,
            pauseDurationSec: Int? = nil,
            externalId: String?,
            samples: [WorkoutIngestDTO.Sample]? = nil
        ) -> WorkoutIngestDTO? {
            guard end > start else { return nil }
            let stepInt: Int? = {
                guard let steps, steps.isFinite, steps >= 0 else { return nil }
                return Int(steps.rounded())
            }()
            return WorkoutIngestDTO(
                sportType: sportType(for: activityType),
                startedAt: start,
                endedAt: end,
                totalEnergyKcal: nonNegative(energyKcal),
                totalDistanceM: nonNegative(distanceM),
                avgHeartRate: clampHr(avgHr),
                maxHeartRate: clampHr(maxHr),
                minHeartRate: clampHr(minHr),
                stepCount: stepInt,
                elevationM: elevationMeters(ascended: elevationM),
                pauseDurationSec: pauseDurationSec.map { min(max($0, 0), 86400) },
                source: "APPLE_HEALTH",
                externalId: externalId,
                samples: samples
            )
        }

        /// Round a HR double to the server-required int and clamp to the
        /// schema's accepted `[20, 300]` band. Returns `nil` for a missing /
        /// out-of-range reading so the optional field is simply omitted.
        static func clampHr(_ value: Double?) -> Int? {
            guard let value, value.isFinite else { return nil }
            let rounded = Int(value.rounded())
            guard rounded >= 20, rounded <= 300 else { return nil }
            return rounded
        }

        /// Drop a negative / non-finite scalar so a sensor glitch can't fail the
        /// server's `min(0)` Zod bound.
        private static func nonNegative(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
    }

#endif
