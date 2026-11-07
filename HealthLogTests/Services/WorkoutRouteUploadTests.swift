// App-target symbols (the HealthKit importer); the SPM test build skips the file.
#if !SWIFT_PACKAGE && canImport(HealthKit)

    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// **1.5 ROUTES (#149)** — route reads and the workout upload.
    ///
    /// The acceptance list of the plan, against the real importer page and the
    /// real `WorkoutsRepository` wire path: switch off means no route read and
    /// no `route` in any request; switch on means `route` in the batch; a
    /// server that drops the route (opt-in off there) breaks nothing; a refused
    /// or failing route read lets the workout go without it; the route
    /// permission never belongs to the first sheet.
    @Suite("ROUTES — routes ride the workout upload only after the opt-in", .serialized, .timeLimit(.minutes(2)))
    struct WorkoutRouteUploadTests {
        private static let now = Date()

        private static func fixes(_ count: Int = 5) -> [WorkoutRouteLocation] {
            (0 ..< count).map {
                WorkoutRouteLocation(
                    latitude: 51.48 + Double($0) * 1e-4,
                    longitude: 7.21,
                    altitude: 100,
                    timestamp: now.addingTimeInterval(Double($0)),
                    speed: 3
                )
            }
        }

        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        private static func workout(daysAgo: Double = 0) -> HKWorkout {
            let start = now.addingTimeInterval(-daysAgo * 86400 - 3600)
            return HKWorkout(activityType: .running, start: start, end: start.addingTimeInterval(1800))
        }

        private func importer(
            reader: CountingRouteReader,
            allowed: RouteFlag,
            repo: any WorkoutBatchUploading = RecordingRouteUploader(),
            anchored: (any WorkoutAnchoredQueryFetching)? = nil
        ) -> WorkoutHealthKitImporter {
            WorkoutHealthKitImporter(
                store: HKHealthStore(),
                repo: repo,
                userID: "user-routes",
                defaultsBox: WorkoutDefaultsBox(suiteName: "routes-\(UUID().uuidString)"),
                series: EmptySeries(),
                lifecycleStore: WorkoutSeriesLifecycleStore(),
                anchoredQuerySource: anchored,
                routes: WorkoutRouteAttachment(
                    reader: reader,
                    isAllowed: { allowed.value },
                    now: { Self.now }
                )
            )
        }

        private static func mapped(_ outcome: WorkoutDirectPageMappingOutcome) -> [WorkoutIngestDTO] {
            if case let .page(dtos, _) = outcome { return dtos }
            Issue.record("expected a page, got \(outcome)")
            return []
        }

        @Test("switch off: no route read and no route on the workout")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func offReadsNothing() async {
            let reader = CountingRouteReader(.success(Self.fixes()))
            let sut = importer(reader: reader, allowed: RouteFlag(false))
            let dtos = await Self.mapped(sut.buildDTOs(from: [Self.workout()]))
            #expect(dtos.count == 1)
            #expect(dtos.allSatisfy { $0.route == nil })
            #expect(reader.calls == 0)
        }

        @Test("switch on: a new workout carries its route")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func onAttachesRoute() async {
            let reader = CountingRouteReader(.success(Self.fixes()))
            let sut = importer(reader: reader, allowed: RouteFlag(true))
            let dtos = await Self.mapped(sut.buildDTOs(from: [Self.workout()]))
            #expect(dtos.first?.route?.pointCount == 5)
            #expect(reader.calls == 1)
        }

        @Test("older workouts and big history pages never read a route, even with the switch on")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func oldAndHistoryPagesSkipped() async {
            let reader = CountingRouteReader(.success(Self.fixes()))
            let sut = importer(reader: reader, allowed: RouteFlag(true))
            let old = await Self.mapped(sut.buildDTOs(from: [Self.workout(daysAgo: 30)]))
            #expect(old.first?.route == nil)
            let page = (0 ..< 11).map { _ in Self.workout() }
            let history = await Self.mapped(sut.buildDTOs(from: page))
            #expect(history.count == 11)
            #expect(history.allSatisfy { $0.route == nil })
            #expect(reader.calls == 0)
        }

        @Test("a refused or failing route read lets the workout go without its route")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func refusedPermissionKeepsWorkout() async {
            let denied = HKError(.errorAuthorizationDenied)
            let reader = CountingRouteReader(.failure(denied))
            let sut = importer(reader: reader, allowed: RouteFlag(true))
            let dtos = await Self.mapped(sut.buildDTOs(from: [Self.workout(), Self.workout()]))
            #expect(dtos.count == 2)
            #expect(dtos.allSatisfy { $0.route == nil })
            #expect(reader.calls == 2)

            let empty = CountingRouteReader(.success([]))
            let indoor = await Self.mapped(importer(reader: empty, allowed: RouteFlag(true)).buildDTOs(from: [Self.workout()]))
            #expect(indoor.count == 1)
            #expect(indoor.first?.route == nil)
        }

        @Test("a route read that never answers costs the route, not the page")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func hungReadIsBounded() async throws {
            let reader = CountingRouteReader(.hang)
            var attachment = WorkoutRouteAttachment(reader: reader, isAllowed: { true }, now: { Self.now })
            attachment.readLimit = .milliseconds(200)
            let dto = WorkoutRouteWireTests.dto("hung")
            let result = try await attachment.attach(to: dto, of: Self.workout())
            #expect(result.outcome == .failed)
            #expect(result.dto.route == nil)
        }

        @Test("a switch turned off during the read still wins")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func switchOffDuringRead() async throws {
            let allowed = RouteFlag(true)
            let reader = CountingRouteReader(.success(Self.fixes())) { allowed.value = false }
            let attachment = WorkoutRouteAttachment(reader: reader, isAllowed: { allowed.value }, now: { Self.now })
            let result = try await attachment.attach(to: WorkoutRouteWireTests.dto("x"), of: Self.workout())
            #expect(result.dto.route == nil)
            #expect(result.outcome == .notRequested)
        }

        @Test("end to end, switch off: not one request carries route data")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func endToEndOffSendsNoRoute() async throws {
            let api = RecordingBatchAPI()
            let repo = try WorkoutsRepository(
                api: api,
                outbox: OutboxQueue(inMemory: true),
                routeUploadAllowed: { _ in false }
            )
            let reader = CountingRouteReader(.success(Self.fixes()))
            let sut = importer(
                reader: reader,
                allowed: RouteFlag(false),
                repo: repo,
                anchored: WorkoutSeriesAnchoredSource(workout: Self.workout())
            )
            _ = await sut.runBoundedPage(mode: .incrementalOnly)
            await sut.stop()
            let bodies = api.bodies
            #expect(!bodies.isEmpty)
            #expect(bodies.allSatisfy { !$0.contains("\"route\"") && !$0.contains("LineString") })
            #expect(reader.calls == 0)
        }

        @Test("end to end, switch on: the batch carries route and the server's silent drop breaks nothing")
        @available(iOS, deprecated: 18.0, message: "Synthetic HealthKit fixture")
        func endToEndOnSendsRoute() async throws {
            let api = RecordingBatchAPI()
            let repo = try WorkoutsRepository(
                api: api,
                outbox: OutboxQueue(inMemory: true),
                routeUploadAllowed: { _ in true }
            )
            let sut = importer(
                reader: CountingRouteReader(.success(Self.fixes())),
                allowed: RouteFlag(true),
                repo: repo,
                anchored: WorkoutSeriesAnchoredSource(workout: Self.workout())
            )
            let outcome = await sut.runBoundedPage(mode: .incrementalOnly)
            await sut.stop()
            // The stub answers `inserted` without keeping the route, exactly
            // what a server with the opt-in off does: the page is accepted.
            #expect(outcome.didRun)
            #expect(api.bodies.contains { $0.contains("\"route\"") && $0.contains("LineString") })
        }

        @Test("the wire boundary strips routes when the switch went off after the batch was built, with a fresh key")
        func repositoryStripsWithFreshKey() async throws {
            let api = RecordingBatchAPI()
            let allowed = RouteFlag(true)
            let repo = try WorkoutsRepository(
                api: api,
                outbox: OutboxQueue(inMemory: true),
                routeUploadAllowed: { _ in allowed.value }
            )
            let route = try #require(WorkoutRouteWire.route(from: Self.fixes()).route)
            let batch = [WorkoutRouteWireTests.dto("r-1").withRoute(route)]

            _ = try await repo.replayUploadBatch(batch, idempotencyKey: "persisted-key")
            allowed.value = false
            _ = try await repo.replayUploadBatch(batch, idempotencyKey: "persisted-key")

            let sent = api.requests
            #expect(sent.count == 2)
            #expect(sent[0].body.contains("LineString"))
            #expect(sent[0].key == "persisted-key")
            #expect(!sent[1].body.contains("\"route\""))
            #expect(sent[1].key != "persisted-key")
        }

        @Test("the legacy upload without an owner never sends a route")
        func ownerlessUploadStrips() async throws {
            let api = RecordingBatchAPI()
            let repo = try WorkoutsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            let route = try #require(WorkoutRouteWire.route(from: Self.fixes()).route)
            _ = try await repo.uploadBatch([WorkoutRouteWireTests.dto("r-2").withRoute(route)])
            #expect(api.bodies.allSatisfy { !$0.contains("\"route\"") })
        }

        @Test("the route permission is never part of the first sheet or the write set")
        func notInFirstSheet() {
            let route = HKSeriesType.workoutRoute()
            #expect(!HealthKitService.defaultReadTypes.contains(route))
            #expect(!HealthKitService.defaultWriteTypes.contains { $0 == route })
            #expect(HealthKitService.workoutRouteReadTypes == [route])
        }
    }

    // MARK: - Doubles

    /// A thread-safe switch the route gate closures read.
    final class RouteFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool

        init(_ value: Bool) {
            stored = value
        }

        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Route reader stub: counts calls; can fail, hang or run a side effect.
    final class CountingRouteReader: WorkoutRouteReading, @unchecked Sendable {
        enum Answer {
            case success([WorkoutRouteLocation])
            case failure(any Error)
            case hang
        }

        private let answer: Answer
        private let sideEffect: @Sendable () -> Void
        private let count = Mutex(0)

        init(_ answer: Answer, sideEffect: @escaping @Sendable () -> Void = {}) {
            self.answer = answer
            self.sideEffect = sideEffect
        }

        var calls: Int {
            count.withLock { $0 }
        }

        func locations(for _: HKWorkout) async throws -> [WorkoutRouteLocation] {
            count.withLock { $0 += 1 }
            sideEffect()
            switch answer {
            case let .success(fixes):
                return fixes
            case let .failure(error):
                throw error
            case .hang:
                try await Task.sleep(for: .seconds(60))
                return []
            }
        }
    }

    private struct EmptySeries: WorkoutHeartRateSeriesSyncServicing {
        func heartRateSeriesOutcome(from _: Date, to _: Date) async -> WorkoutHeartRateSeriesOutcome {
            .samples([])
        }
    }

    private actor RecordingRouteUploader: WorkoutBatchUploading {
        func uploadBatch(_ workouts: [WorkoutIngestDTO], ownerUserID _: String) async throws -> WorkoutBatchResponseDTO {
            WorkoutBatchResponseDTO(
                processed: workouts.count,
                inserted: workouts.count,
                duplicates: 0,
                entries: workouts.indices.map { .init(index: $0, status: .inserted) }
            )
        }
    }

    /// Records every workout batch body and its idempotency key, and answers
    /// every entry `inserted` (a server that silently drops a route answers
    /// the same).
    final class RecordingBatchAPI: APIClientProtocol, @unchecked Sendable {
        struct Sent {
            let body: String
            let key: String
        }

        private let log = Mutex<[Sent]>([])

        var requests: [Sent] {
            log.withLock { $0 }
        }

        var bodies: [String] {
            requests.map(\.body)
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            let body = request.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            log.withLock { $0.append(Sent(body: body, key: request.idempotencyKey.raw)) }
            let count = (try? JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
                .flatMap { $0["workouts"] as? [Any] }?.count ?? 0
            let response = WorkoutBatchResponseDTO(
                processed: count,
                inserted: count,
                duplicates: 0,
                entries: (0 ..< count).map { .init(index: $0, status: .inserted) }
            )
            guard let typed = response as? T else { throw HLError.unknown("unexpected request type") }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.canceled
        }
    }

#endif
