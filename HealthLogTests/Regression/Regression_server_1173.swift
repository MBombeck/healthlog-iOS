#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    @testable import HealthLog
    import Synchronization
    import Testing

    /// **REG (1.5) — Server #1173 (mills1975): values arrived only after a
    /// manual sync; a restart helped.**
    ///
    /// Three ways the report could come back, each pinned here:
    /// 1. the pass that runs when the app comes to the front reaches fewer
    ///    types than "Alles synchronisieren" (it did before the orchestrator);
    /// 2. a page that could not go out (offline, the uploader's backoff) is
    ///    held and never sent by a later pass;
    /// 3. a pass hangs and every later trigger folds into it (the stall
    ///    itself is pinned by `SweepCoalescerWatchdogTests.staleRunIsReplaced`
    ///    and `HRBucketSweepStallTests.hangingCapabilityDoesNotHoldTheRound`).
    @Suite("REG Server #1173: the foreground pass does what a manual sync does")
    struct Regression_server_1173 {
        /// Records which capabilities ran.
        actor Entered {
            private(set) var capabilities: [HealthSyncCapability] = []
            func add(_ capability: HealthSyncCapability) {
                capabilities.append(capability)
            }
        }

        private static func registry(_ entered: Entered) -> HealthSyncCapabilityRegistry {
            func make(_ capability: HealthSyncCapability) -> HealthSyncCapabilityRegistry.Run {
                { _ in
                    await entered.add(capability)
                    return HealthSyncCapabilityResult(capability: capability, disposition: .succeeded)
                }
            }
            return HealthSyncCapabilityRegistry(
                speziSampleCollection: make(.speziSampleCollection),
                workoutImport: make(.workoutImport),
                ecgUpload: make(.ecgUpload),
                dailyStatistics: make(.dailyStatistics),
                heartRateBuckets: make(.heartRateBuckets),
                nutrientDailyTotals: make(.nutrientDailyTotals),
                moodStateOfMindImport: make(.moodStateOfMindImport),
                appleMedicationImport: make(.appleMedicationImport),
                cycleImport: make(.cycleImport),
                heartHealthEvents: make(.heartHealthEvents),
                outboxDrain: make(.outboxDrain),
                serverMirror: make(.serverMirror)
            )
        }

        @Test("coming to the front runs the same capabilities, with the same budget, as a manual sync")
        func foregroundEqualsManual() async {
            let foregroundLog = Entered()
            let manualLog = Entered()
            let foreground = await HealthSyncOrchestrator(registry: Self.registry(foregroundLog)).run(.foreground)
            let manual = await HealthSyncOrchestrator(registry: Self.registry(manualLog)).run(.manual)

            let everything = Set(HealthSyncCapability.allCases)
            #expect(foreground.planned == manual.planned)
            #expect(foreground.planned == everything, "the foreground pass leaves out \(everything.subtracting(foreground.planned))")
            #expect(foreground.omitted.isEmpty)
            #expect(await Set(foregroundLog.capabilities) == Set(manualLog.capabilities))
            #expect(await Set(foregroundLog.capabilities) == everything)
            #expect(HealthSyncBudget.required(for: .foreground) == HealthSyncBudget.required(for: .manual))
            // "A restart helped": a cold start is the same complete pass.
            #expect(HealthSyncCompositionPlan.required(for: .coldActivation) == everything)
        }

        /// The server answers offline until told otherwise, then accepts.
        final class FlakyServer: APIClientProtocol, @unchecked Sendable {
            private let state = Mutex<(online: Bool, posted: [[String]])>((false, []))

            func goOnline() {
                state.withLock { $0.online = true }
            }

            var posted: [[String]] {
                state.withLock { $0.posted }
            }

            func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
                guard let body = request.body else { throw HLError.unknown("no body") }
                let payload = try BatchUploadOutcomeTests.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                guard state.withLock({ $0.online }) else { throw HLError.offline }
                state.withLock { $0.posted.append(payload.entries.map(\.externalId)) }
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

        @Test("a page held while offline goes out, whole, on the next pass")
        func heldPageIsSentNextPass() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let server = FlakyServer()
            let retry = HealthSampleBackfillAndHoldTests.RecordingRetry()
            let consumption = HealthSampleConsumption(
                uploader: MeasurementBatchUploader(
                    api: server,
                    throttle: BatchSyncThrottle(maxPerWindow: 1000, jitter: 0 ... 0),
                    syncTrigger: SyncTriggerContext()
                ),
                gate: HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil),
                retry: retry,
                skipRegister: HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage),
                build: "300"
            )
            let page = HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil)
                .map([0.95, 0.96, 0.97].map(SkipFixture.spo2Sample))
            let ids = page.entries.map(\.externalId)
            #expect(ids.count == 3)

            // Pass 1, offline: held. The cursor stays, so the next pass reads
            // the same rows again; nothing is parked or lost.
            let (held, _) = await consumption.transmitReporting(page, admitted: lease)
            #expect(HealthSyncCursorPolicy.required.decide(held) == .hold(reason: .serverUnreachable))
            #expect(server.posted.isEmpty)
            #expect(await retry.rows.isEmpty)

            // Pass 2, back online: the very same rows reach the server.
            server.goOnline()
            let (sent, tally) = await consumption.transmitReporting(page, admitted: lease)
            #expect(HealthSyncCursorPolicy.required.decide(sent) == .commit)
            #expect(server.posted.flatMap { $0 }.sorted() == ids.sorted(), "posted \(server.posted)")
            #expect(tally.parked == 0)
            #expect(await retry.rows.isEmpty)
        }
    }
#endif
