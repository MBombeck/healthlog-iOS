import Foundation

/// **1.3 (#128) — where an upgraded partition's history walk may stop.**
///
/// A 1.2.0 installation already delivered part of each type through its
/// forward cursor. The server says how far per type and source
/// (`GET /api/integrations/healthkit`, `metricFreshness[].lastSeenAt`, the
/// newest stored `measuredAt` of the Apple Health rows; HealthLog v1.42.x,
/// `src/lib/integrations/metric-freshness.ts`). The history walk of an upgraded
/// partition stops at that point minus seven days instead of walking years of
/// rows the server already holds; the partition's legacy leg finishes the
/// dates below it, so a misleading `lastSeenAt` (a type the server also fills
/// from day totals or pulse buckets) costs time, never a reading.
///
/// A fresh partition has no legacy leg and therefore never takes the
/// shortcut: without the forward cursor nothing would cover the dates below.
enum HealthSampleReplayFloor {
    /// HealthKit identifier → server `MeasurementType`, for the registry's
    /// types. Read off `APPLE_HEALTH_TYPE_MAP` in
    /// `src/lib/measurements/apple-health-mapping.ts` at HealthLog `v1.42.4`.
    /// A type missing here simply gets no shortcut.
    static let serverType: [String: String] = [
        "HKQuantityTypeIdentifierBodyMass": "WEIGHT",
        "HKQuantityTypeIdentifierBodyFatPercentage": "BODY_FAT",
        "HKQuantityTypeIdentifierBodyTemperature": "BODY_TEMPERATURE",
        "HKQuantityTypeIdentifierWaistCircumference": "WAIST_CIRCUMFERENCE",
        "HKQuantityTypeIdentifierBloodPressureSystolic": "BLOOD_PRESSURE_SYS",
        "HKQuantityTypeIdentifierBloodPressureDiastolic": "BLOOD_PRESSURE_DIA",
        "HKQuantityTypeIdentifierBloodGlucose": "BLOOD_GLUCOSE",
        "HKQuantityTypeIdentifierOxygenSaturation": "OXYGEN_SATURATION",
        "HKQuantityTypeIdentifierHeartRate": "PULSE",
        "HKQuantityTypeIdentifierRestingHeartRate": "RESTING_HEART_RATE",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": "HEART_RATE_VARIABILITY",
        "HKQuantityTypeIdentifierHeartRateVariabilityRMSSD": "HRV_RMSSD",
        "HKQuantityTypeIdentifierRespiratoryRate": "RESPIRATORY_RATE",
        "HKQuantityTypeIdentifierVO2Max": "VO2_MAX",
        "HKQuantityTypeIdentifierStepCount": "ACTIVITY_STEPS",
        "HKQuantityTypeIdentifierActiveEnergyBurned": "ACTIVE_ENERGY_BURNED",
        "HKQuantityTypeIdentifierFlightsClimbed": "FLIGHTS_CLIMBED",
        "HKQuantityTypeIdentifierDistanceWalkingRunning": "WALKING_RUNNING_DISTANCE",
        "HKQuantityTypeIdentifierWalkingSpeed": "WALKING_SPEED",
        "HKQuantityTypeIdentifierWalkingAsymmetryPercentage": "WALKING_ASYMMETRY",
        "HKQuantityTypeIdentifierWalkingStepLength": "WALKING_STEP_LENGTH",
        "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage": "WALKING_DOUBLE_SUPPORT",
        "HKQuantityTypeIdentifierAppleWalkingSteadiness": "WALKING_STEADINESS",
        "HKQuantityTypeIdentifierBodyMassIndex": "BODY_MASS_INDEX",
        "HKCategoryTypeIdentifierSleepAnalysis": "SLEEP_DURATION",
        "HKQuantityTypeIdentifierEnvironmentalAudioExposure": "AUDIO_EXPOSURE_ENV",
        "HKQuantityTypeIdentifierHeadphoneAudioExposure": "AUDIO_EXPOSURE_HEADPHONE",
        "HKQuantityTypeIdentifierWalkingHeartRateAverage": "WALKING_HEART_RATE_AVERAGE",
        "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute": "CARDIO_RECOVERY",
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature": "WRIST_TEMPERATURE",
        "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances": "BREATHING_DISTURBANCES",
        "HKQuantityTypeIdentifierLeanBodyMass": "LEAN_BODY_MASS",
        "HKQuantityTypeIdentifierSixMinuteWalkTestDistance": "SIX_MINUTE_WALK_DISTANCE",
        "HKQuantityTypeIdentifierStairAscentSpeed": "STAIR_ASCENT_SPEED",
        "HKQuantityTypeIdentifierStairDescentSpeed": "STAIR_DESCENT_SPEED",
        "HKQuantityTypeIdentifierNumberOfTimesFallen": "FALL_COUNT",
        "HKQuantityTypeIdentifierTimeInDaylight": "TIME_IN_DAYLIGHT",
        // HK-NEW (1.5) — server v1.44.
        "HKQuantityTypeIdentifierAppleExerciseTime": "EXERCISE_MINUTES",
        "HKQuantityTypeIdentifierAppleStandTime": "STAND_MINUTES",
        "HKCategoryTypeIdentifierAppleStandHour": "STAND_HOURS",
        "HKCategoryTypeIdentifierMindfulSession": "MINDFUL_MINUTES",
        "HKDataTypeStateOfMind": "STATE_OF_MIND_VALENCE",
        "HKQuantityTypeIdentifierAtrialFibrillationBurden": "AFIB_BURDEN"
    ]

    /// The replay floor for one type from the server's freshness list, or
    /// `nil` when the server has nothing for it (the walk then goes to the
    /// chosen window).
    static func floor(for typeIdentifier: String, freshness: [MetricFreshness]) -> Date? {
        guard let server = serverType[typeIdentifier] else { return nil }
        let lastSeen = freshness.first { $0.type == server }?.lastSeenAt
        return HealthSampleSplitPolicy.replayFloor(lastSeenAt: lastSeen)
    }

    /// Reads the server's answer for ``resolvePending``. `nil` means "ask
    /// again next pass" (offline, timeout, 5xx, rate limit, a session that is
    /// changing); any answer the server gave, including a refusal it will
    /// repeat (an old server, a 4xx, a body this build cannot read, no server
    /// at all), resolves without a shortcut: the walk then goes to the chosen
    /// window, which is slower but never loses a reading.
    static func freshnessAnswer(
        _ fetch: () async throws -> [MetricFreshness]?
    ) async -> [MetricFreshness]? {
        do {
            return try await fetch() ?? []
        } catch let error as HLError {
            switch error {
            case .network, .offline, .canceled, .rateLimited, .unauthorized, .idempotencyReplayInFlight:
                return nil
            case let .server(status, _, _) where status >= 500:
                return nil
            default:
                return []
            }
        } catch is CancellationError {
            return nil
        } catch {
            return []
        }
    }

    /// Resolves every upgraded partition in `typeIdentifiers` that still
    /// waits for its floor. `freshness` is `nil` when the server could not be
    /// asked; nothing is resolved then and the next pass asks again (live
    /// never waits for this). Returns how many partitions were resolved.
    @discardableResult
    static func resolvePending(
        typeIdentifiers: [String],
        cursors: DurableHealthCursorStore,
        lease: HealthSyncAuthenticatedLease,
        fetch: () async -> [MetricFreshness]?
    ) async -> Int {
        var pending: [HealthSyncCursorKey] = []
        for typeIdentifier in typeIdentifiers {
            guard let key = lease.cursorKey(typeIdentifier: typeIdentifier),
                  let state = await cursors.splitState(for: key),
                  !state.replayFloorResolved else { continue }
            pending.append(key)
        }
        guard !pending.isEmpty, let freshness = await fetch(), lease.isCurrent else { return 0 }

        var resolved = 0
        for key in pending {
            let floor = floor(for: key.typeIdentifier, freshness: freshness)
            let written = await cursors.updateSplit(for: key, requiring: lease) { state in
                state.replayFloor = floor
                state.replayFloorResolved = true
            }
            if written { resolved += 1 }
        }
        // A count only: no type, no date, no owner.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.healthKit.info("history replay floor resolved for \(resolved, privacy: .public) partition(s)")
        return resolved
    }
}
