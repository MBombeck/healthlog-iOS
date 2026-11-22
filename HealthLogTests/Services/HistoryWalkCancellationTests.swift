#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// W1 and W2 together: the history walk runs
    /// every page through the real `HealthSampleConsumption`, whose W1 rules
    /// decide what a failed POST means.
    ///
    /// A background expiry that cuts off a history page on the wire
    /// (`HLError.canceled`, `.network(.writeCancelled)`) is "stopped", not
    /// "failed": the date cursor holds where it was, nothing goes into the
    /// outbox, and the next pass reads the same page again. A timeout is a
    /// transient transport failure: its rows wait durably in the outbox (W1
    /// resends them on its own), so the history cursor may move past them.
    @Suite("INT-P — a cancelled history page holds its cursor and parks nothing")
    struct HistoryWalkCancellationTests {
        private static let type = CollectorFixture.stepType
        private static let liveStart = SplitFixture.now.addingTimeInterval(-HealthSampleSplitPolicy.liveLookback)

        /// Accepts every row, except that the first POST made only of history
        /// rows (start before `liveStart`) fails once with the armed error.
        final class ExpiringHistoryAPI: APIClientProtocol, @unchecked Sendable {
            private let inner = VerdictBatchAPI { _ in (.inserted, nil) }
            private let armed: Mutex<HLError?>

            init(failingFirstHistoryPageWith error: HLError) {
                armed = Mutex(error)
            }

            var postedValues: [Int] {
                inner.postedBatches.flatMap { $0.map { Int($0.value) } }
            }

            func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
                if let body = request.body,
                   let payload = try? BatchUploadOutcomeTests.batchDecoder().decode(HealthKitBatchPayload.self, from: body),
                   !payload.entries.isEmpty,
                   payload.entries.allSatisfy({ $0.startDate < HistoryWalkCancellationTests.liveStart }),
                   let error = armed.withLock({ value -> HLError? in
                       defer { value = nil }
                       return value
                   })
                {
                    throw error
                }
                return try await inner.send(request)
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.unknown("download not implemented")
            }
        }

        /// The production consumption behind the collector's page seam.
        struct ConsumptionPageConsumer: HealthSamplePageConsuming {
            let consumption: HealthSampleConsumption

            func consume(
                _ samples: [HKSample],
                ofType _: String,
                requiring lease: HealthSyncAuthenticatedLease
            ) async -> HealthSyncPageOutcome {
                await consumption.consume(samples, admitted: lease).outcome
            }
        }

        @Test("a cut-off history page holds the date cursor; a timed-out one waits in the outbox", arguments: [
            (HLError.canceled, true),
            (HLError.network(.writeCancelled), true),
            (HLError.network(.timeout), false)
        ])
        func cancelledHistoryPageHoldsItsCursor(_ error: HLError, holds: Bool) async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let cursors = SplitFixture.cursors(CollectorCursorBacking())
            let key = try await SplitFixture.replayingKey(cursors, type: Self.type, lease: lease)
            // 25 history rows (pages of 10: two full, one short) and 3 live rows.
            let rows = SplitFixture.rows(historyDays: 25, recent: 3)
            let historyAnchors = Set(rows.filter { $0.start < Self.liveStart }.map(\.anchor))
            #expect(historyAnchors.count == 25)
            let store = SimulatedHealthStore(typeIdentifier: Self.type, rows: rows)
            let api = ExpiringHistoryAPI(failingFirstHistoryPageWith: error)
            let retry = HealthSampleCancellationTests.RecordingRetry()
            let consumer = ConsumptionPageConsumer(consumption: HealthSampleConsumption(
                uploader: MeasurementBatchUploader(api: api, throttle: BatchSyncThrottle(jitter: 0 ... 0)),
                gate: HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil),
                retry: retry,
                skipRegister: HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage),
                build: "293"
            ))
            let collector = AnchoredHealthSampleCollector(
                cursors: cursors,
                query: store,
                consumer: consumer,
                history: store,
                pageLimit: 10,
                clock: SplitFixture.clock()
            )

            let first = await collector.collect(
                typeIdentifiers: [Self.type],
                trigger: .manual,
                notBefore: .distantPast,
                requiring: lease
            ).first
            let afterFirst = try #require(await cursors.splitState(for: key))
            #expect(afterFirst.liveCaughtUp, "live ran first and reached the present")

            if holds {
                #expect(first?.history?.disposition == .expired)
                #expect(first?.history?.holdReason == .cancelled)
                #expect(afterFirst.historyEnd == Self.liveStart, "the date cursor did not move")
                #expect(!afterFirst.historyEndInclusive)
                #expect(await retry.rows.isEmpty, "a cancelled page is never parked in the outbox")

                // The next pass reads the same page again and walks to the end.
                let second = await collector.collect(
                    typeIdentifiers: [Self.type],
                    trigger: .manual,
                    notBefore: .distantPast,
                    requiring: lease
                ).first
                #expect(second?.history?.isFinished == true)
                #expect(await retry.rows.isEmpty)
            } else {
                // Transient: the rows wait durably, W1 resends them, the walk goes on.
                #expect(await retry.rows.map(\.count) == [10])
                #expect(first?.history?.disposition == .retryPersisted)
                #expect(first?.history?.isFinished == true)
            }

            let state = try #require(await cursors.splitState(for: key))
            #expect(state.isHistoryComplete(cutoff: .distantPast))
            let parked = await retry.rows.flatMap { $0.map { Int($0.value) } }
            let delivered = Set(api.postedValues).union(parked)
            #expect(historyAnchors.isSubset(of: delivered), "every history row reached the server or the outbox")
        }
    }
#endif
