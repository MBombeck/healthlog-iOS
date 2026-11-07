#if canImport(HealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// **MIRROR (1.5, public #28)** — the bounded server→Apple-Health mirror in
    /// the background health sync.
    ///
    /// (c) one request, at most 50 readings, a closed window leaves nothing half
    /// written; (d) an older server gets no background request at all.
    @Suite("Server mirror in the background (public #28)", .timeLimit(.minutes(1)))
    struct ServerMirrorBackgroundPassTests {
        private static let now = Date(timeIntervalSince1970: 1_762_250_000)

        // MARK: - Test doubles

        /// Records every request the repository sends and answers with `page`.
        private final class RequestLog: @unchecked Sendable {
            private let lock = NSLock()
            private var _queries: [[(String, String)]] = []
            private var _paths: [String] = []

            var queries: [[(String, String)]] {
                lock.withLock { _queries }
            }

            var paths: [String] {
                lock.withLock { _paths }
            }

            func record(_ path: String, _ query: [(String, String)]) {
                lock.withLock {
                    _paths.append(path)
                    _queries.append(query)
                }
            }
        }

        /// The bounded writer, recorded. Returns `outcome`, or derives one from
        /// the rows it was handed when `outcome` is `nil`.
        private final class RecordingWriter: BoundedServerMirrorWriting, @unchecked Sendable {
            private let lock = NSLock()
            private var _calls: [(rows: [HealthLog.Measurement], rowLimit: Int)] = []
            private var _expiredAtCall: [Bool] = []
            let outcome: ServerMirrorWriteOutcome?

            init(outcome: ServerMirrorWriteOutcome? = nil) {
                self.outcome = outcome
            }

            var calls: [(rows: [HealthLog.Measurement], rowLimit: Int)] {
                lock.withLock { _calls }
            }

            var expiredAtCall: [Bool] {
                lock.withLock { _expiredAtCall }
            }

            func mirrorServerMeasurements(
                _ measurements: [HealthLog.Measurement],
                rowLimit: Int,
                isExpired: @escaping @Sendable () -> Bool
            ) async -> ServerMirrorWriteOutcome {
                let expired = isExpired()
                lock.withLock {
                    _calls.append((measurements, rowLimit))
                    _expiredAtCall.append(expired)
                }
                return outcome ?? ServerMirrorWriteOutcome(written: min(measurements.count, rowLimit))
            }
        }

        private func repo(log: RequestLog, page: MeasurementListWireResponse) async throws -> MeasurementsRepository {
            let api = StubAPIClient()
            await api.setHandler { request in
                if let request = request as? APIRequest<MeasurementListWireResponse> {
                    log.record(request.path, request.query)
                }
                return page
            }
            return try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
        }

        /// Held by the test: the lease reads its registry weakly.
        private let registry = AuthenticatedSessionLeaseRegistry()

        private func lease() throws -> AuthenticatedSessionLease {
            try #require(registry.activate(ownerID: "owner-a"))
        }

        private func environment(
            source: (any ServerMirrorSource)?,
            writer: (any BoundedServerMirrorWriting)?,
            serverIsNew: Bool = true,
            standalone: Bool = false,
            lease: AuthenticatedSessionLease?
        ) -> ServerMirrorBackgroundPass.Environment {
            ServerMirrorBackgroundPass.Environment(
                source: source,
                writer: writer,
                serverIsNewEnough: { serverIsNew },
                isStandalone: { standalone },
                lease: { lease },
                now: { Self.now }
            )
        }

        private func context(_ trigger: HealthSyncTrigger, expired: Bool = false) -> HealthSyncRunContext {
            HealthSyncRunContext(
                trigger: trigger,
                budget: HealthSyncBudget.required(for: trigger),
                observedSource: nil,
                isExpired: { expired }
            )
        }

        private func weightWire(_ index: Int, flag: Bool? = true) -> MeasurementWireDTO {
            var row = MeasurementWireDTO(
                id: "w-\(index)",
                type: .weight,
                value: 80 + Double(index) / 10,
                measuredAt: Self.now.addingTimeInterval(TimeInterval(-index * 600)),
                source: .external
            )
            row.appleHealthMirror = flag
            return row
        }

        // MARK: - (c) One request, a bounded write

        @Test("(c) one App Refresh wake sends exactly one request and writes at most 50 readings")
        func oneRequestAtMostFiftyReadings() async throws {
            let log = RequestLog()
            let page = MeasurementListWireResponse(measurements: (0 ..< 80).map { weightWire($0) })
            let source = try await repo(log: log, page: page)
            let writer = RecordingWriter()

            let result = try await ServerMirrorBackgroundPass.run(
                context(.appRefresh),
                environment: environment(source: source, writer: writer, lease: lease())
            )

            #expect(log.paths == ["/api/measurements"])
            let query = try #require(log.queries.first)
            #expect(query.first { $0.0 == "appleHealthMirror" }?.1 == "true")
            #expect(query.first { $0.0 == "limit" }?.1 == "200")
            #expect(query.first { $0.0 == "from" }?.1
                == ISO8601DateFormatter.plain.string(from: Self.now.addingTimeInterval(-7 * 24 * 3600)))
            #expect(!query.contains { $0.0 == "type" || $0.0 == "sourceEq" || $0.0 == "offset" })
            #expect(writer.calls.count == 1)
            #expect(writer.calls.first?.rowLimit == 50)
            #expect(writer.calls.first?.rows.count == 80)
            #expect(result.disposition == .succeeded)
            #expect(result.itemsSubmitted == 50)
        }

        @Test("(c) the planner stops at 50 readings and names the rest for the next window")
        func plannerCapsTheWrite() async {
            let rows = (0 ..< 60).compactMap { weightWire($0).toDomain() }
            let plan = await HealthKitServerMirrorPlanner.plan(
                rows,
                excluding: [],
                probe: Self.emptyHealth,
                rowLimit: ServerMirrorBackgroundPass.rowLimit
            )
            #expect(plan.rowCount == 50)
            #expect(plan.samples.count == 50)
            #expect(plan.unexamined == 10)
            #expect(!plan.stopped)
            // Newest first: the oldest ten wait.
            #expect(Set(plan.linkageIDs) == Set((0 ..< 50).map { "w-\($0)" }))
        }

        @Test("(c) a window that closes while planning stops before the next reading")
        func plannerStopsAtTheWindow() async {
            let rows = (0 ..< 10).compactMap { weightWire($0).toDomain() }
            let asked = Counter()
            let plan = await HealthKitServerMirrorPlanner.plan(
                rows,
                excluding: [],
                probe: Self.emptyHealth,
                rowLimit: 50,
                shouldStop: { asked.next() > 3 }
            )
            #expect(plan.rowCount == 3)
            #expect(plan.stopped)
            #expect(plan.unexamined == 7)
        }

        @Test("(c) a window that closes before the save writes nothing, a blood pressure lands whole or not at all")
        func budgetEndLeavesNothingHalf() async {
            var reading = HealthLog.Measurement(
                id: "bp-1",
                kind: .bloodPressure,
                recordedAt: Self.now,
                value: .bloodPressure(systolic: 128, diastolic: 82),
                source: .external,
                bloodPressureDiastolicId: "bp-1-dia"
            )
            reading.appleHealthMirror = true
            let plan = await HealthKitServerMirrorPlanner.plan([reading], excluding: [], probe: Self.emptyHealth)
            #expect(plan.objects.count == 1, "the reading is one correlation")

            let saved = SavedObjects()
            let expired = await HealthKitServerMirrorPlanner.commit(
                plan,
                isExpired: { true },
                save: { objects in saved.append(objects) }
            )
            #expect(saved.isEmpty)
            #expect(expired.written == 0)
            #expect(expired.stopped)
            #expect(expired.unexamined == 1)

            let open = await HealthKitServerMirrorPlanner.commit(
                plan,
                isExpired: { false },
                save: { objects in saved.append(objects) }
            )
            #expect(saved.count == 1)
            #expect(open.written == 1)
            let correlation = saved.first as? HKCorrelation
            #expect(correlation?.objects.count == 2)
        }

        @Test("(c) the window is handed to the writer, and a closed window ends the pass as expired")
        func windowReachesTheWriter() async throws {
            let log = RequestLog()
            let source = try await repo(log: log, page: MeasurementListWireResponse(measurements: [weightWire(0)]))
            let writer = RecordingWriter(outcome: ServerMirrorWriteOutcome(unexamined: 1, stopped: true))
            let result = try await ServerMirrorBackgroundPass.run(
                context(.processing),
                environment: environment(source: source, writer: writer, lease: lease())
            )
            #expect(writer.expiredAtCall == [false])
            #expect(result.disposition == .expired)
            #expect(result.itemsHeld == 1)
        }

        @Test("a closed window before the request sends nothing")
        func expiredBeforeTheRequestSendsNothing() async throws {
            let log = RequestLog()
            let source = try await repo(log: log, page: MeasurementListWireResponse(measurements: []))
            let writer = RecordingWriter()
            let result = try await ServerMirrorBackgroundPass.run(
                context(.appRefresh, expired: true),
                environment: environment(source: source, writer: writer, lease: lease())
            )
            #expect(log.paths.isEmpty)
            #expect(writer.calls.isEmpty)
            #expect(result.disposition == .expired)
        }

        @Test("rows left by the limit make the capability owed, not done")
        func remainderIsDeferred() {
            let result = ServerMirrorBackgroundPass.result(for: ServerMirrorWriteOutcome(written: 50, unexamined: 30))
            #expect(result.disposition == .deferred)
            #expect(result.itemsHeld == 30)
            #expect(result.owesWork)
            let unknown = ServerMirrorBackgroundPass.result(for: ServerMirrorWriteOutcome(decided: false))
            #expect(unknown.disposition == .deferred)
            let failed = ServerMirrorBackgroundPass.result(for: ServerMirrorWriteOutcome(unexamined: 4, saveFailed: true))
            #expect(failed.disposition == .failed)
            #expect(failed.failure == .persistence)
        }

        // MARK: - (d) Older server, other wakes, standalone

        @Test("(d) an older or unknown server gets no background request")
        func olderServerGetsNoRequest() async throws {
            let log = RequestLog()
            let source = try await repo(log: log, page: MeasurementListWireResponse(measurements: [weightWire(0)]))
            let writer = RecordingWriter()
            for trigger in [HealthSyncTrigger.appRefresh, .processing] {
                let result = try await ServerMirrorBackgroundPass.run(
                    context(trigger),
                    environment: environment(source: source, writer: writer, serverIsNew: false, lease: lease())
                )
                #expect(result.disposition == .disabled)
            }
            #expect(log.paths.isEmpty)
            #expect(writer.calls.isEmpty)
        }

        @Test("only App Refresh and Processing run it; the app in front mirrors its own page", arguments: [
            HealthSyncTrigger.coldActivation, .postAuthentication, .foreground, .manual, .silentPush, .observer
        ])
        func otherTriggersDoNotRun(trigger: HealthSyncTrigger) async throws {
            let log = RequestLog()
            let source = try await repo(log: log, page: MeasurementListWireResponse(measurements: [weightWire(0)]))
            let writer = RecordingWriter()
            let result = try await ServerMirrorBackgroundPass.run(
                context(trigger),
                environment: environment(source: source, writer: writer, lease: lease())
            )
            #expect(result.disposition == .disabled)
            #expect(!result.owesWork)
            #expect(log.paths.isEmpty)
        }

        @Test("standalone, no HealthKit writer, or no admitted account: no request")
        func noRequestWithoutAServerOrAWriter() async throws {
            let log = RequestLog()
            let source = try await repo(log: log, page: MeasurementListWireResponse(measurements: [weightWire(0)]))
            let standalone = try await ServerMirrorBackgroundPass.run(
                context(.appRefresh),
                environment: environment(source: source, writer: RecordingWriter(), standalone: true, lease: lease())
            )
            #expect(standalone.disposition == .disabled)
            let noWriter = try await ServerMirrorBackgroundPass.run(
                context(.appRefresh),
                environment: environment(source: source, writer: nil, lease: lease())
            )
            #expect(noWriter.disposition == .unsupported)
            let nobody = await ServerMirrorBackgroundPass.run(
                context(.appRefresh),
                environment: environment(source: source, writer: RecordingWriter(), lease: nil)
            )
            #expect(nobody.failure == .notAdmitted)
            #expect(log.paths.isEmpty)
        }

        @Test("a blood-pressure half cut off by the page is dropped, never written as a zero half")
        func halfPairIsDropped() async throws {
            func half(_ id: String, _ type: ServerMeasurementType, at offset: TimeInterval) -> MeasurementWireDTO {
                var row = MeasurementWireDTO(
                    id: id, type: type, value: 120, measuredAt: Self.now.addingTimeInterval(offset), source: .external
                )
                row.appleHealthMirror = true
                return row
            }
            let log = RequestLog()
            let source = try await repo(log: log, page: MeasurementListWireResponse(measurements: [
                half("s-1", .bloodPressureSystolic, at: 0),
                half("d-1", .bloodPressureDiastolic, at: 0),
                half("s-2", .bloodPressureSystolic, at: -3600)
            ]))
            let rows = try await source.rowsForServerMirror(since: Self.now.addingTimeInterval(-86400), limit: 200)
            #expect(rows.map(\.id) == ["s-1"])
        }

        @Test("the capability is planned on App Refresh and Processing, in the independent lane")
        func capabilityIsPlanned() {
            #expect(HealthSyncCompositionPlan.required(for: .appRefresh).contains(.serverMirror))
            #expect(HealthSyncCompositionPlan.required(for: .processing).contains(.serverMirror))
            #expect(HealthSyncCapability.serverMirror.source == .serverMirror)
            #expect(!HealthSyncCapability.serverMirror.requiresExplicitOptIn)
            let registry = HealthSyncCapabilityRegistry.unsupportedEverywhere()
            #expect(registry.adapter(for: .serverMirror).lane == .independent)
        }

        // MARK: - Helpers

        private static var emptyHealth: HealthKitServerMirrorProbe {
            HealthKitServerMirrorProbe(
                isShareAuthorized: { _ in true },
                existsWithExternalIDs: { _, _ in false },
                ownSamplesNear: { _, _ in [] }
            )
        }

        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0

            func next() -> Int {
                lock.withLock {
                    value += 1
                    return value
                }
            }
        }

        private final class SavedObjects: @unchecked Sendable {
            private let lock = NSLock()
            private var objects: [HKObject] = []

            var count: Int {
                lock.withLock { objects.count }
            }

            var isEmpty: Bool {
                lock.withLock { objects.isEmpty }
            }

            var first: HKObject? {
                lock.withLock { objects.first }
            }

            func append(_ new: [HKObject]) {
                lock.withLock { objects += new }
            }
        }
    }
#endif
