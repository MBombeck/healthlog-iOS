// App-target symbols (the HealthKit route pass); the SPM test build skips the file.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// **POLISH-B B10 (1.5, #163 B6, server v1.47.1)** — "Send routes of
    /// older workouts".
    ///
    /// From v1.47.1 the workout batch attaches a route to a stored workout
    /// that has none and answers `enriched`. The pass runs only after a tap,
    /// only with the opt-in on, only on a server known to be v1.47.1 or newer,
    /// over the last 12 months and in batches of at most 10 workouts and
    /// 20 000 route points.
    @Suite("POLISH-B B10 — routes for older workouts", .serialized, .timeLimit(.minutes(1)))
    struct WorkoutRouteBackfillTests {
        private static let now = Date(timeIntervalSince1970: 1_793_950_000)

        private static func fixes(_ count: Int) -> [WorkoutRouteLocation] {
            (0 ..< count).map {
                WorkoutRouteLocation(
                    latitude: 51.48 + Double($0) * 1e-5,
                    longitude: 7.21,
                    altitude: nil,
                    timestamp: now.addingTimeInterval(Double($0)),
                    speed: nil
                )
            }
        }

        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        private static func workout(daysAgo: Double) -> HKWorkout {
            let start = now.addingTimeInterval(-daysAgo * 86400)
            return HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(1800))
        }

        /// Records each batch; answers `enriched` for every entry with a route.
        private actor Uploader {
            private(set) var batches: [[WorkoutIngestDTO]] = []
            private let fails: Bool

            init(fails: Bool = false) {
                self.fails = fails
            }

            func upload(_ chunk: [WorkoutIngestDTO]) throws -> WorkoutBatchResponseDTO {
                if fails { throw HLError.offline }
                batches.append(chunk)
                return WorkoutBatchResponseDTO(
                    processed: chunk.count,
                    inserted: 0,
                    duplicates: chunk.count,
                    entries: chunk.indices.map { .init(index: $0, status: chunk[$0].route != nil ? .enriched : .duplicate) }
                )
            }
        }

        private final class Since: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: (Date, Int)?
            func set(_ value: (Date, Int)) {
                lock.withLock { stored = value }
            }

            var value: (Date, Int)? {
                lock.withLock { stored }
            }
        }

        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        private static func pass(
            workouts: [HKWorkout],
            reader: CountingRouteReader,
            allowed: RouteFlag,
            uploader: Uploader,
            since: Since = Since()
        ) -> WorkoutRouteBackfill {
            WorkoutRouteBackfill(
                workouts: { from, limit in
                    since.set((from, limit))
                    return workouts
                },
                routes: WorkoutRouteAttachment(reader: reader, isAllowed: { allowed.value }, now: { Self.now }),
                upload: { try await uploader.upload($0) },
                now: { Self.now }
            )
        }

        @Test("older workouts go out with their route and the server's enriched count comes back")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func olderWorkoutsCarryRoutes() async throws {
            let uploader = Uploader()
            let since = Since()
            let reader = CountingRouteReader(.success(Self.fixes(50)))
            let workouts = [30.0, 120, 300].map { Self.workout(daysAgo: $0) }
            let summary = try await Self.pass(
                workouts: workouts, reader: reader, allowed: RouteFlag(true), uploader: uploader, since: since
            ).run()

            #expect(summary == WorkoutRouteBackfillSummary(checked: 3, sent: 3, attached: 3))
            let batches = await uploader.batches
            #expect(batches.count == 1)
            #expect(batches.flatMap(\.self).allSatisfy { $0.route?.pointCount == 50 })
            #expect(batches.flatMap(\.self).allSatisfy { $0.samples == nil }, "no heart-rate series in this pass")
            let window = try #require(since.value)
            #expect(window.1 == WorkoutRouteBackfill.maxWorkouts)
            let months = Calendar.current.dateComponents([.month], from: window.0, to: Self.now).month
            #expect(months == 12, "the window is the last 12 months")
        }

        @Test("the same externalId as the importer, so the server matches the stored workout")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func sameIdentityAsImporter() async throws {
            let workout = Self.workout(daysAgo: 60)
            let uploader = Uploader()
            _ = try await Self.pass(
                workouts: [workout], reader: CountingRouteReader(.success(Self.fixes(5))),
                allowed: RouteFlag(true), uploader: uploader
            ).run()
            let imported = await WorkoutHealthKitMapping.ingestDisposition(from: workout).dto
            let sent = await uploader.batches.first?.first
            #expect(sent?.externalId == imported?.externalId)
            #expect(sent?.startedAt == imported?.startedAt)
        }

        @Test("batches hold at most 10 workouts and 20 000 route points")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func boundedBatches() async throws {
            let uploader = Uploader()
            let workouts = (0 ..< 25).map { Self.workout(daysAgo: 20 + Double($0)) }
            let summary = try await Self.pass(
                workouts: workouts, reader: CountingRouteReader(.success(Self.fixes(6000))),
                allowed: RouteFlag(true), uploader: uploader
            ).run()
            let batches = await uploader.batches
            #expect(summary.sent == 25)
            #expect(batches.allSatisfy { $0.count <= WorkoutIngestDTO.maxWorkoutsPerSeriesBatch })
            #expect(batches.allSatisfy { $0.compactMap(\.route?.pointCount).reduce(0, +) <= 20000 })
        }

        @Test("switch off: nothing is read and nothing is sent")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func offDoesNothing() async {
            let uploader = Uploader()
            let reader = CountingRouteReader(.success(Self.fixes(5)))
            await #expect(throws: WorkoutRouteBackfillFailure.notAllowed) {
                try await Self.pass(
                    workouts: [Self.workout(daysAgo: 40)], reader: reader, allowed: RouteFlag(false), uploader: uploader
                ).run()
            }
            #expect(reader.calls == 0)
            #expect(await uploader.batches.isEmpty)
        }

        @Test("switched off during the pass: it stops before the next batch")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func offMidway() async {
            let uploader = Uploader()
            let allowed = RouteFlag(true)
            let reader = CountingRouteReader(.success(Self.fixes(5)), sideEffect: { allowed.value = false })
            await #expect(throws: WorkoutRouteBackfillFailure.notAllowed) {
                try await Self.pass(
                    workouts: (0 ..< 3).map { Self.workout(daysAgo: 20 + Double($0)) },
                    reader: reader, allowed: allowed, uploader: uploader
                ).run()
            }
            #expect(await uploader.batches.isEmpty)
        }

        @Test("a workout without a route is skipped; an upload failure is reported")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func noRouteAndFailure() async throws {
            let empty = try await Self.pass(
                workouts: [Self.workout(daysAgo: 50)], reader: CountingRouteReader(.success([])),
                allowed: RouteFlag(true), uploader: Uploader()
            ).run()
            #expect(empty == WorkoutRouteBackfillSummary(checked: 1, sent: 0, attached: 0))

            await #expect(throws: WorkoutRouteBackfillFailure.upload) {
                try await Self.pass(
                    workouts: [Self.workout(daysAgo: 50)], reader: CountingRouteReader(.success(Self.fixes(5))),
                    allowed: RouteFlag(true), uploader: Uploader(fails: true)
                ).run()
            }
        }

        @Test("offered only on a server known to be v1.47.1 or newer", arguments: [
            (nil, false), ("1.47.0", false), ("1.47.1", true), ("1.48.0", true)
        ] as [(String?, Bool)])
        func versionGate(version: String?, expected: Bool) throws {
            let suite = "polish-b-b10-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if let version {
                KnownServerVersion.record(ServerVersionInfo(version: version), defaults: defaults)
            }
            #expect(WorkoutRouteBackfill.serverSupportsBackfill(defaults: defaults) == expected)
        }
    }

    /// The model and the card around the pass.
    @MainActor
    @Suite("POLISH-B B10 — the button under the route switch")
    struct WorkoutRouteBackfillSettingTests {
        private struct Service: WorkoutRoutesSettingServing {
            func fetch() async throws -> WorkoutRoutesSettingDTO {
                WorkoutRoutesSettingDTO(storeWorkoutRoutes: true)
            }

            func update(storeWorkoutRoutes: Bool) async throws -> WorkoutRoutesSettingDTO {
                WorkoutRoutesSettingDTO(storeWorkoutRoutes: storeWorkoutRoutes)
            }
        }

        private static func model(
            on: Bool,
            backfill: (@Sendable () async throws -> WorkoutRouteBackfillSummary)?
        ) throws -> (WorkoutRoutesSettingModel, UserDefaults) {
            let defaults = try #require(UserDefaults(suiteName: "polish-b-b10-model-\(UUID().uuidString)"))
            WorkoutRouteOptIn.set(on, ownerUserID: "user-b10", defaults: defaults)
            let model = WorkoutRoutesSettingModel(
                service: Service(),
                ownerUserID: "user-b10",
                defaults: defaults,
                requestAuthorization: {},
                backfill: backfill
            )
            return (model, defaults)
        }

        @Test("older server: no button, the footer keeps \"new workouts\"")
        func olderServer() async throws {
            let (model, _) = try Self.model(on: true, backfill: nil)
            await model.load()
            #expect(!model.offersBackfill)
            #expect(!model.showsBackfill)
        }

        @Test("v1.47.1 with the switch on: the button, and a tap runs the pass once")
        func tapRunsOnce() async throws {
            let runs = Mutex(0)
            let (model, _) = try Self.model(on: true, backfill: {
                runs.withLock { $0 += 1 }
                return WorkoutRouteBackfillSummary(checked: 8, sent: 4, attached: 3)
            })
            await model.load()
            #expect(model.showsBackfill)
            #expect(runs.withLock { $0 } == 0, "nothing runs before the tap")
            await model.runBackfill()
            #expect(runs.withLock { $0 } == 1)
            #expect(model.backfillPhase == .done(WorkoutRouteBackfillSummary(checked: 8, sent: 4, attached: 3)))
            #expect(WorkoutRoutesCard.backfillLine(model.backfillPhase)
                == String(localized: "settings.applehealth.routes.backfill.done \(3)"))
        }

        @Test("switch off: no button and the pass does not run")
        func offHidesButton() async throws {
            let runs = Mutex(0)
            let (model, _) = try Self.model(on: false, backfill: {
                runs.withLock { $0 += 1 }
                return WorkoutRouteBackfillSummary()
            })
            await model.load()
            #expect(!model.showsBackfill)
            await model.runBackfill()
            #expect(runs.withLock { $0 } == 0)
        }

        @Test("a failed pass says so and can be tapped again; none attached reads as its own line")
        func failureAndNone() async throws {
            let (model, _) = try Self.model(on: true, backfill: { throw WorkoutRouteBackfillFailure.upload })
            await model.load()
            await model.runBackfill()
            #expect(model.backfillPhase == .failed)
            #expect(WorkoutRoutesCard.backfillLine(.failed) == String(localized: "settings.applehealth.routes.backfill.failed"))
            #expect(WorkoutRoutesCard.backfillLine(.done(WorkoutRouteBackfillSummary(checked: 3)))
                == String(localized: "settings.applehealth.routes.backfill.none"))
            #expect(WorkoutRoutesCard.backfillLine(.idle) == nil)
        }

        @Test("the texts exist in German, English and Dutch")
        func catalog() {
            for key in [
                "settings.applehealth.routes.backfill.action",
                "settings.applehealth.routes.backfill.running",
                "settings.applehealth.routes.backfill.done %lld",
                "settings.applehealth.routes.backfill.none",
                "settings.applehealth.routes.backfill.failed",
                "settings.applehealth.routes.footer.backfill"
            ] {
                for language in ["de", "en", "nl"] {
                    let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
                    let text = bundle?.localizedString(forKey: key, value: "\u{0}", table: nil)
                    #expect(text != nil && text != "\u{0}" && text != key, "\(language) \(key)")
                }
            }
        }
    }
#endif
