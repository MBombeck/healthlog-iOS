#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// SYNC-TRIG (1.5, #138 rest from 17.10.) — the history mark belongs to
    /// one upload call, not to the task.
    ///
    /// Until 1.5 the history walk marked its page with a task-local around the
    /// upload. Everything started from inside that call inherited it: a sweep
    /// kicked from the success stamp, any `Task { }` created there. A heart
    /// rate sweep a history page set off would then have posted live hours as
    /// `backfill`, and the server would have stopped moving their live stamps.
    /// The mark is now an argument of `MeasurementBatchUploader.upload`.
    @Suite("History pages: the backfill mark stays on its own upload (SYNC-TRIG)", .timeLimit(.minutes(1)))
    struct HistoryBackfillUploadMarkTests {
        typealias BatchServer = HealthSampleBackfillAndHoldTests.BatchServer

        static func backfillServer() -> SyncTriggerContext {
            let context = SyncTriggerContext()
            context.noteServerVersion(ServerVersionInfo(version: "1.47.0"))
            context.noteServerFeatures([.syncTriggerBackfill])
            return context
        }

        static func uploader(_ api: BatchServer, context: SyncTriggerContext) -> MeasurementBatchUploader {
            MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 1000, jitter: 0 ... 0),
                syncTrigger: context
            )
        }

        static var page: HealthSampleMappingResult {
            HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil)
                .map([0.95, 0.96, 0.97].map(SkipFixture.spo2Sample))
        }

        @Test("a sweep started from inside a history page's upload posts under the live trigger")
        func workStartedInsideTheUploadIsLive() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let context = Self.backfillServer()
            let api = BatchServer()
            let uploader = Self.uploader(api, context: context)
            let started = Mutex<[Task<Void, Never>]>([])
            // The one hook that runs inside the upload: the success stamp. A
            // sweep someone starts from there is live work.
            uploader.setSuccessNotifier { _, _ in
                let alreadyStarted = started.withLock { !$0.isEmpty }
                guard !alreadyStarted else { return }
                let sweep = Task {
                    _ = try? await uploader.upload([SkipFixture.entry("hr-bucket-live")])
                }
                started.withLock { $0.append(sweep) }
            }
            let consumption = HealthSampleConsumption(
                uploader: uploader,
                gate: HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil),
                retry: nil,
                skipRegister: HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage),
                build: "300"
            )

            await context.bind(.background) {
                _ = await consumption.transmitReporting(Self.page, admitted: lease, asBackfill: true)
            }
            for sweep in started.withLock({ $0 }) {
                await sweep.value
            }

            let byPost = api.payloads.map { ($0.entries.map(\.externalId), $0.syncTrigger) }
            let history = byPost.first { !$0.0.contains("hr-bucket-live") }
            let sweep = byPost.first { $0.0.contains("hr-bucket-live") }
            #expect(history?.1 == .backfill, "the history page itself is the catch-up")
            #expect(sweep != nil, "the sweep posted")
            #expect(sweep?.1 != .backfill, "the sweep keeps a live word")
        }

        @Test("a live and a history upload running at once on one uploader keep their own words")
        func interleavedUploadsKeepTheirWords() async {
            let context = Self.backfillServer()
            let api = BatchServer()
            let uploader = Self.uploader(api, context: context)

            await context.bind(.foreground) {
                async let history: Void = {
                    _ = try? await uploader.upload(
                        (0 ..< 3).map { SkipFixture.entry("old-\($0)") },
                        requiring: nil,
                        asBackfill: true
                    )
                }()
                async let live: Void = {
                    _ = try? await uploader.upload([SkipFixture.entry("new-0")])
                }()
                _ = await (history, live)
            }

            for payload in api.payloads {
                let isHistory = payload.entries.allSatisfy { $0.externalId.hasPrefix("old-") }
                #expect(payload.syncTrigger == (isHistory ? .backfill : .foreground))
            }
            #expect(api.payloads.count == 2)
        }

        @Test("server without the field: a marked upload goes under the trigger it would have had")
        func markedUploadAgainstOlderServers() async {
            for (version, flag) in [(nil as String?, false), ("1.42.4", false), ("1.43.0", false), ("1.42.4", true)] {
                let context = SyncTriggerContext()
                if let version { context.noteServerVersion(ServerVersionInfo(version: version)) }
                context.noteServerFeatures(flag ? [.syncTriggerBackfill] : [])
                let api = BatchServer()
                await context.bind(.push) {
                    _ = try? await Self.uploader(api, context: context)
                        .upload([SkipFixture.entry("p")], requiring: nil, asBackfill: true)
                }
                #expect(api.payloads.map(\.syncTrigger) == [.push], "server \(version ?? "unknown"), flag \(flag)")
            }
        }

        @Test("the mark belongs to one call: the next unmarked upload is live again")
        func markIsPerCall() async throws {
            let context = Self.backfillServer()
            let api = BatchServer()
            let uploader = Self.uploader(api, context: context)
            _ = try await uploader.upload([SkipFixture.entry("a")], requiring: nil, asBackfill: true)
            _ = try await uploader.upload([SkipFixture.entry("b")])
            #expect(api.payloads.map(\.syncTrigger) == [.backfill, .foreground])
        }
    }
#endif
