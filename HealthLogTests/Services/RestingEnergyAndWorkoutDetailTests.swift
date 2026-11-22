#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// Two things the server already takes and the app now sends: resting
    /// energy as a day total, and a workout's climb and pauses.
    @Suite("Resting energy and workout details")
    struct RestingEnergyAndWorkoutDetailTests {
        private static func defaults(version: String?) throws -> UserDefaults {
            let defaults = try #require(UserDefaults(suiteName: "hl.tests.basal.\(UUID().uuidString)"))
            if let version {
                HealthKitServerTypeGate.record(ServerVersionInfo(version: version), defaults: defaults)
            }
            return defaults
        }

        // MARK: - Resting energy

        @Test("resting energy is collected from server v1.47.1 on, never before")
        func restingEnergyFollowsTheServer() throws {
            let id = HealthKitBasalEnergy.identifier
            #expect(id == HKQuantityType(.basalEnergyBurned).identifier)
            #expect(!HealthKitAcceptedTypes.deferredIdentifiers.contains(id))
            for version in [nil, "1.44.0", "1.47.0"] as [String?] {
                #expect(
                    try !HealthKitServerTypeGate.serverAccepts(id, defaults: Self.defaults(version: version)),
                    "\(version ?? "unknown")"
                )
            }
            #expect(try HealthKitServerTypeGate.serverAccepts(id, defaults: Self.defaults(version: "1.47.1")))
            #expect(try HealthKitServerTypeGate.serverAccepts(id, defaults: Self.defaults(version: "1.47.6")))
        }

        @Test("a server that lists its accepted types decides on its own")
        func acceptedTypesDecide() throws {
            let defaults = try Self.defaults(version: "1.40.0")
            HealthKitAcceptedTypes.record([HealthKitBasalEnergy.identifier], defaults: defaults)
            #expect(HealthKitServerTypeGate.serverAccepts(HealthKitBasalEnergy.identifier, defaults: defaults))
            HealthKitAcceptedTypes.record(["HKQuantityTypeIdentifierStepCount"], defaults: defaults)
            #expect(!HealthKitServerTypeGate.serverAccepts(HealthKitBasalEnergy.identifier, defaults: defaults))
        }

        @Test("it goes the day-total way in kilocalories, beside active energy and never into it")
        func dayTotalInKilocalories() throws {
            let id = HealthKitBasalEnergy.identifier
            #expect(HealthLogSampleTypeRegistry.knownIdentifiers.contains(id))
            #expect(HealthKitCumulativeTypeConfig.cumulativeIdentifiers.contains(id))
            let config = try #require(HealthKitCumulativeTypeConfig.defaults.first { $0.identifier == id })
            #expect(config.wireUnit == "kcal")
            let active = try #require(HealthKitCumulativeTypeConfig.defaults.first {
                $0.identifier == HKQuantityTypeIdentifier.activeEnergyBurned.rawValue
            })
            #expect(active.wireUnit == "kcal")
            #expect(HealthKitWireConverter.preferredUnit(for: id)?.wireSymbol == "kcal")
            #expect(HKSyncDiagnostics.metricKind(for: id) == .basalEnergy)
            #expect(HealthSampleReplayFloor.serverType[id] == "BASAL_ENERGY_BURNED")
        }

        @Test("it is read only, asked for in the sheet, and named on the permission list")
        func readOnlyAndNamed() {
            let id = HealthKitBasalEnergy.identifier
            #expect(HealthKitService.defaultReadTypes.map(\.identifier).contains(id))
            #expect(!HealthKitService.defaultWriteTypes.map(\.identifier).contains(id))
            #expect(HealthAccessTypeNaming.localizationKey(for: id) != nil)
            #expect(HealthKitBasalEnergy.announcedLateReadIdentifiers.last == id)
            #expect(HealthKitServer144Types.readType(for: id) == HKQuantityType(.basalEnergyBurned))
            // Not woken for: it arrives in steady drips like active energy.
            #expect(!HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: id))
        }

        // MARK: - Workout climb

        @Test("the climb is sent within the server's band and left out beyond it")
        func elevation() {
            #expect(WorkoutHealthKitMapping.elevationMeters(ascended: 412.5) == 412.5)
            #expect(WorkoutHealthKitMapping.elevationMeters(ascended: 0) == 0)
            #expect(WorkoutHealthKitMapping.elevationMeters(ascended: nil) == nil)
            #expect(WorkoutHealthKitMapping.elevationMeters(ascended: 10001) == nil)
            #expect(WorkoutHealthKitMapping.elevationMeters(ascended: .nan) == nil)
        }

        // MARK: - Workout pauses

        private static let start = Date(timeIntervalSince1970: 1_760_000_000)
        private static let end = start.addingTimeInterval(3600)

        private static func at(_ seconds: TimeInterval) -> Date {
            start.addingTimeInterval(seconds)
        }

        @Test("manual and automatic pauses add up between each pause and its resume")
        func pausesAddUp() {
            let events: [(type: HKWorkoutEventType, date: Date)] = [
                (.resume, Self.at(700)),
                (.pause, Self.at(600)),
                (.lap, Self.at(650)),
                (.motionPaused, Self.at(1200)),
                (.motionResumed, Self.at(1230))
            ]
            #expect(WorkoutHealthKitMapping.pauseDurationSeconds(events: events, start: Self.start, end: Self.end) == 130)
        }

        @Test("a pause never resumed runs to the end; a second pause while paused counts once")
        func openPause() {
            let events: [(type: HKWorkoutEventType, date: Date)] = [
                (.pause, Self.at(3000)),
                (.motionPaused, Self.at(3100))
            ]
            #expect(WorkoutHealthKitMapping.pauseDurationSeconds(events: events, start: Self.start, end: Self.end) == 600)
        }

        @Test("no pause event means no claim; events outside the workout are clipped")
        func noPauseAndClipping() {
            #expect(WorkoutHealthKitMapping.pauseDurationSeconds(events: [], start: Self.start, end: Self.end) == nil)
            #expect(WorkoutHealthKitMapping.pauseDurationSeconds(
                events: [(.lap, Self.at(10)), (.resume, Self.at(20))],
                start: Self.start,
                end: Self.end
            ) == nil)
            #expect(WorkoutHealthKitMapping.pauseDurationSeconds(
                events: [(.pause, Self.at(-100)), (.resume, Self.at(60))],
                start: Self.start,
                end: Self.end
            ) == 60)
        }

        @Test("the DTO carries both fields to the wire, and leaves them out when unknown")
        func dtoOnTheWire() throws {
            let full = try #require(WorkoutHealthKitMapping.makeDTO(
                activityType: .hiking,
                start: Self.start,
                end: Self.end,
                energyKcal: 400,
                distanceM: 8000,
                avgHr: 120,
                maxHr: 150,
                minHr: 80,
                steps: 9000,
                elevationM: 512,
                pauseDurationSec: 300,
                externalId: "workout-1"
            ))
            #expect(full.elevationM == 512)
            #expect(full.pauseDurationSec == 300)
            let body = try #require(String(data: JSONEncoder.hlBatch.encode(WorkoutBatchPayload(workouts: [full])), encoding: .utf8))
            #expect(body.contains("\"elevationM\":512"))
            #expect(body.contains("\"pauseDurationSec\":300"))

            let bare = try #require(WorkoutHealthKitMapping.makeDTO(
                activityType: .walking,
                start: Self.start,
                end: Self.end,
                energyKcal: nil,
                distanceM: nil,
                avgHr: nil,
                maxHr: nil,
                minHr: nil,
                steps: nil,
                externalId: "workout-2"
            ))
            let bareBody = try #require(String(data: JSONEncoder.hlBatch.encode(WorkoutBatchPayload(workouts: [bare])), encoding: .utf8))
            #expect(!bareBody.contains("elevationM"))
            #expect(!bareBody.contains("pauseDurationSec"))
            #expect(full.withRoute(nil).pauseDurationSec == 300)
        }

        @Test("update path: a workout page parked in the outbox before 1.7 replays unchanged")
        func parkedPayloadFromAnEarlierBuild() throws {
            let legacy = """
            {"workouts":[{"sportType":"RUNNING","startedAt":"2026-10-01T07:00:00Z","endedAt":"2026-10-01T07:45:00Z",
            "totalEnergyKcal":420,"avgHeartRate":151,"source":"APPLE_HEALTH","externalId":"7E1C"}]}
            """
            let payload = try JSONDecoder.hlDefault.decode(OutboxQueue.Payloads.UploadWorkoutBatch.self, from: Data(legacy.utf8))
            let workout = try #require(payload.workouts.first)
            #expect(workout.pauseDurationSec == nil)
            #expect(workout.elevationM == nil)
            #expect(workout.externalId == "7E1C")
            let resent = try #require(String(
                data: JSONEncoder.hlBatch.encode(WorkoutBatchPayload(workouts: payload.workouts)),
                encoding: .utf8
            ))
            #expect(!resent.contains("pauseDurationSec"))
        }
    }
#endif
