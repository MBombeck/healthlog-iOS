#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// A2 (1.4) — one page on the wire: what it is called, and what happens
    /// when it cannot go out.
    ///
    /// * R3 S6: offline, or with the uploader in its backoff, a page holds its
    ///   cursor and writes no outbox row. Until 1.3.0 both fell into the
    ///   transport arm and every page of the history walk was parked.
    /// * R-A7 / #138: a page of the history walk is a catch-up, sent as
    ///   `syncTrigger: "backfill"` where the server takes it, so it never
    ///   moves the server's live arrival stamps. The row it leaves in the
    ///   outbox keeps that word for its replay.
    @Suite("One page on the wire: backfill and hold (A2)")
    struct HealthSampleBackfillAndHoldTests {
        /// Answers every batch POST with `inserted` per row, or fails every
        /// POST with `failure`, and keeps every body.
        final class BatchServer: APIClientProtocol, @unchecked Sendable {
            private let failure: Error?
            private let bodies = Mutex<[HealthKitBatchPayload]>([])

            init(failing failure: Error? = nil) {
                self.failure = failure
            }

            var payloads: [HealthKitBatchPayload] {
                bodies.withLock { $0 }
            }

            func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
                guard let body = request.body else { throw HLError.unknown("no body") }
                let payload = try BatchUploadOutcomeTests.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                bodies.withLock { $0.append(payload) }
                if let failure { throw failure }
                let response = HealthKitBatchResponseDTO(
                    processed: payload.entries.count,
                    inserted: payload.entries.count,
                    duplicates: 0,
                    skipped: [],
                    entries: payload.entries.indices.map { .init(index: $0, status: .inserted) }
                )
                guard let typed = response as? T else { throw HLError.unknown("T mismatch") }
                return typed
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.unknown("download not implemented")
            }
        }

        /// Records every durable retry and the trigger it was asked to keep.
        actor RecordingRetry: HealthSyncBatchRetryEnqueuing {
            private(set) var rows: [[HealthKitBatchEntryDTO]] = []
            private(set) var triggers: [SyncTrigger?] = []

            func enqueueHealthKitRetry(
                _ entries: [HealthKitBatchEntryDTO],
                idempotencyKey _: String,
                requiringCurrentOwner _: String
            ) async throws {
                rows.append(entries)
                triggers.append(nil)
            }

            func enqueueHealthKitRetry(
                _ entries: [HealthKitBatchEntryDTO],
                idempotencyKey _: String,
                syncTrigger: SyncTrigger?,
                requiringCurrentOwner _: String
            ) async throws {
                rows.append(entries)
                triggers.append(syncTrigger)
            }
        }

        private struct DailyStatsOn: FeatureFlagsServicing {
            func isEnabled(_ flag: FeatureFlag) -> Bool {
                switch flag {
                case .enableDailyStats: true
                case .enableHRBuckets: false
                default: flag.defaultValue
                }
            }
        }

        /// A trigger context that knows a v1.43 server with `backfill`.
        private static func backfillServer() -> SyncTriggerContext {
            let context = SyncTriggerContext()
            context.noteServerVersion(ServerVersionInfo(version: "1.43.0"))
            context.noteServerFeatures([.syncTriggerBackfill])
            return context
        }

        private static func consumption(
            _ api: APIClientProtocol,
            context: SyncTriggerContext = SyncTriggerContext(),
            retry: RecordingRetry = RecordingRetry()
        ) -> HealthSampleConsumption {
            HealthSampleConsumption(
                uploader: MeasurementBatchUploader(
                    api: api,
                    throttle: BatchSyncThrottle(maxPerWindow: 1000, jitter: 0 ... 0),
                    syncTrigger: context
                ),
                gate: HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil),
                retry: retry,
                skipRegister: HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage),
                build: "300"
            )
        }

        private static var page: HealthSampleMappingResult {
            HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil)
                .map([0.95, 0.96, 0.97].map(SkipFixture.spo2Sample))
        }

        // MARK: - Hold (S6)

        @Test("offline: the page holds, nothing is parked, nothing counted")
        func offlineHolds() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let retry = RecordingRetry()

            let (outcome, tally) = await Self.consumption(BatchServer(failing: HLError.offline), retry: retry)
                .transmitReporting(Self.page, admitted: lease)

            #expect(await retry.rows.isEmpty, "no outbox row")
            #expect(tally == HealthSampleServerTally())
            #expect(outcome.serverUnreachable)
            #expect(HealthSyncCursorPolicy.required.decide(outcome) == .hold(reason: .serverUnreachable))
        }

        @Test("the uploader's backoff: the page holds without touching the wire and nothing is parked")
        func backoffHolds() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let retry = RecordingRetry()
            let api = BatchServer(failing: HLError.server(status: 503, code: nil, message: "unavailable"))
            let consumption = Self.consumption(api, retry: retry)
            // Six failures within a minute open the backoff.
            for index in 0 ..< 6 {
                _ = try? await consumption.uploader.upload([SkipFixture.entry("warm-\(index)")])
            }
            let postsBefore = api.payloads.count

            let (outcome, tally) = await consumption.transmitReporting(Self.page, admitted: lease)

            #expect(api.payloads.count == postsBefore, "the backoff refuses before the wire")
            #expect(await retry.rows.isEmpty, "no outbox row")
            #expect(tally == HealthSampleServerTally())
            #expect(HealthSyncCursorPolicy.required.decide(outcome) == .hold(reason: .serverUnreachable))
        }

        @Test("a server error still parks the page durably, so the cursor may move")
        func serverErrorStillParks() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let retry = RecordingRetry()

            let (outcome, tally) = await Self.consumption(
                BatchServer(failing: HLError.server(status: 503, code: nil, message: "unavailable")),
                retry: retry
            ).transmitReporting(Self.page, admitted: lease)

            #expect(await retry.rows.map(\.count) == [3])
            #expect(tally.parked == 3)
            #expect(!outcome.serverUnreachable)
            #expect(HealthSyncCursorPolicy.required.decide(outcome) == .commit)
        }

        // MARK: - backfill (R-A7)

        @Test("a history page goes out as backfill, a live page under its own trigger")
        func historyPageIsBackfill() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let context = Self.backfillServer()
            let api = BatchServer()
            let consumption = Self.consumption(api, context: context)

            await context.bind(.background) {
                _ = await consumption.transmitReporting(Self.page, admitted: lease, asBackfill: true)
                _ = await consumption.transmitReporting(Self.page, admitted: lease)
            }

            #expect(api.payloads.map(\.syncTrigger) == [.backfill, .background])
        }

        @Test("a server without backfill sees the page under the trigger it would have had")
        func olderServerNeverSeesBackfill() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let context = SyncTriggerContext()
            context.noteServerVersion(ServerVersionInfo(version: "1.42.4"))
            let api = BatchServer()

            await context.bind(.background) {
                _ = await Self.consumption(api, context: context)
                    .transmitReporting(Self.page, admitted: lease, asBackfill: true)
            }

            #expect(api.payloads.map(\.syncTrigger) == [.background])
        }

        @Test("a parked page keeps the trigger it was posted under for its replay")
        func parkedPageKeepsItsTrigger() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let context = Self.backfillServer()
            let retry = RecordingRetry()
            let consumption = Self.consumption(
                BatchServer(failing: HLError.server(status: 502, code: nil, message: "bad gateway")),
                context: context,
                retry: retry
            )

            await context.bind(.background) {
                _ = await consumption.transmitReporting(Self.page, admitted: lease, asBackfill: true)
                _ = await consumption.transmitReporting(Self.page, admitted: lease)
            }

            #expect(await retry.triggers == [.backfill, .background])
        }

        @Test("through the standard: the history page is backfill, the day-total sweep it kicks is not")
        func standardMarksOnlyThePage() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let context = Self.backfillServer()
            let api = BatchServer()
            let kicked = Mutex<[SyncTrigger]>([])
            let standard = HealthLogStandard()
            await standard.attachUploader(
                MeasurementBatchUploader(
                    api: api,
                    throttle: BatchSyncThrottle(maxPerWindow: 1000, jitter: 0 ... 0),
                    syncTrigger: context
                ),
                featureFlags: DailyStatsOn(),
                dailyStatsKick: { _ in kicked.withLock { $0.append(context.wireValue) } }
            )
            let steps = HKQuantitySample(
                type: HKQuantityType(.stepCount),
                quantity: HKQuantity(unit: .count(), doubleValue: 120),
                start: Date(timeIntervalSince1970: 1_726_300_000),
                end: Date(timeIntervalSince1970: 1_726_300_600)
            )

            _ = await standard.consumePage(
                [steps, SkipFixture.spo2Sample(0.97)],
                ofType: SkipFixture.spo2,
                admitted: lease,
                backfill: true
            )

            #expect(api.payloads.map(\.syncTrigger) == [.backfill])
            #expect(kicked.withLock { $0 }.count == 1)
            #expect(!kicked.withLock { $0 }.contains(.backfill), "the kicked sweep keeps its own trigger")
        }
    }
#endif
