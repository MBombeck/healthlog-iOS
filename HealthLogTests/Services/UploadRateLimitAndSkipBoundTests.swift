#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    /// A 429 holds the page instead of parking it, and the skip register
    /// never drops a row the server has not answered for.
    @Suite("Upload: 429 holds, unanswered rows stay in the register")
    struct UploadRateLimitAndSkipBoundTests {
        private typealias BatchServer = HealthSampleBackfillAndHoldTests.BatchServer
        private typealias RecordingRetry = HealthSampleBackfillAndHoldTests.RecordingRetry

        private static func consumption(_ api: APIClientProtocol, retry: RecordingRetry) -> HealthSampleConsumption {
            HealthSampleConsumption(
                uploader: MeasurementBatchUploader(
                    api: api,
                    throttle: BatchSyncThrottle(maxPerWindow: 1000, jitter: 0 ... 0),
                    syncTrigger: SyncTriggerContext()
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

        // MARK: - 429

        @Test("a 429 holds the page: no outbox row, nothing counted, the cursor stays")
        func rateLimitHolds() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let retry = RecordingRetry()

            for wait in [30.0, nil] as [TimeInterval?] {
                let (outcome, tally) = await Self.consumption(
                    BatchServer(failing: HLError.rateLimited(retryAfter: wait)),
                    retry: retry
                ).transmitReporting(Self.page, admitted: lease)

                #expect(tally == HealthSampleServerTally())
                #expect(outcome.serverUnreachable)
                #expect(HealthSyncCursorPolicy.required.decide(outcome) == .hold(reason: .serverUnreachable))
            }
            #expect(await retry.rows.isEmpty, "a rate limit never parks a page")
        }

        @Test("a 429 reads as out of reach, a server error still does not")
        func classification() {
            #expect(HealthSampleConsumption.isUnreachable(HLError.rateLimited(retryAfter: 12)))
            #expect(HealthSampleConsumption.isUnreachable(HLError.rateLimited(retryAfter: nil)))
            #expect(!HealthSampleConsumption.isUnreachable(HLError.server(status: 503, code: nil, message: "x")))
        }

        // MARK: - Skip register bound

        private static func unconfirmed(_ prefix: String, count: Int, base: Date) -> [HealthKitSkippedEntry] {
            (0 ..< count).map { index in
                HealthKitSkippedEntry(
                    entry: SkipFixture.entry("\(prefix)-\(index)", at: base.addingTimeInterval(Double(index))),
                    reason: OutboxReplayService.notConfirmedReason
                )
            }
        }

        @Test("two unconfirmed pages of 500 are both kept; the second does not push out the first")
        func unconfirmedPagesAreNeverDropped() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let base = Date(timeIntervalSince1970: 1_726_000_000)
            try await register.record(Self.unconfirmed("old", count: 500, base: base), ownerID: "account-a", build: "300")
            try await register.record(
                Self.unconfirmed("new", count: 500, base: base.addingTimeInterval(86400)),
                ownerID: "account-a",
                build: "300"
            )

            let rows = await register.rows(ownerID: "account-a")
            #expect(rows.count == 1000)
            #expect(rows.contains { $0.id == "old-0" })
            #expect(await register.overflowCount(ownerID: "account-a") == 0)
        }

        @Test("the bound still applies to refusals and counts what it drops, never an unanswered row")
        func boundAppliesToRefusalsOnly() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let base = Date(timeIntervalSince1970: 1_726_000_000)
            // Older than every refusal, so a bound that counted them would drop them first.
            try await register.record(Self.unconfirmed("held", count: 300, base: base), ownerID: "account-a", build: "300")
            try await register.record(
                [HealthKitSkippedEntry(entry: SkipFixture.entry("heart-0", at: base), reason: "unclassified_4xx:409")],
                ownerID: "account-a",
                build: "300"
            )
            let refused = (0 ..< HealthKitSkippedRowRegister.maxRowsPerOwner + 2).map { index in
                HealthKitSkippedEntry(
                    entry: SkipFixture.entry("range-\(index)", at: base.addingTimeInterval(3600 + Double(index))),
                    reason: MeasurementBatchAcceptance.Reason.valueOutOfRange
                )
            }
            try await register.record(refused, ownerID: "account-a", build: "300")

            let ids = await Set(register.rows(ownerID: "account-a").map(\.id))
            #expect(ids.count == 300 + 1 + HealthKitSkippedRowRegister.maxRowsPerOwner)
            #expect((0 ..< 300).allSatisfy { ids.contains("held-\($0)") })
            #expect(ids.contains("heart-0"))
            #expect(!ids.contains("range-0") && !ids.contains("range-1"))
            #expect(await register.overflowCount(ownerID: "account-a") == 2)
        }

        @Test("an unanswered row the server later refuses by name joins the bound")
        func answeredRowBecomesBoundable() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let entry = SkipFixture.entry("uuid-1")
            try await register.record(
                [HealthKitSkippedEntry(entry: entry, reason: OutboxReplayService.notConfirmedReason)],
                ownerID: "account-a",
                build: "300"
            )
            #expect(await register.rows(ownerID: "account-a").first?.awaitsVerdict == true)
            try await register.applyReoffer(
                stored: [],
                refused: [HealthKitSkippedEntry(entry: entry, reason: MeasurementBatchAcceptance.Reason.valueOutOfRange)],
                ownerID: "account-a",
                build: "301"
            )
            #expect(await register.rows(ownerID: "account-a").first?.awaitsVerdict == false)
        }

        @Test("update path: a full register written by 1.6 keeps every row when a new page arrives")
        func fullRegisterFromAnEarlierBuild() async throws {
            let base = Date(timeIntervalSince1970: 1_726_000_000)
            let legacyRows = (0 ..< 500).map { index in
                HealthKitSkippedRow(
                    ownerID: "account-a",
                    entry: SkipFixture.entry("legacy-\(index)", at: base.addingTimeInterval(Double(index))),
                    nutrient: nil,
                    mood: nil,
                    reason: "not_confirmed",
                    detail: nil,
                    firstSkippedAt: base,
                    lastAttemptAt: base,
                    attempts: 1,
                    lastOfferedBuild: "310"
                )
            }
            let rowsJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyRows))
            let file = try JSONSerialization.data(withJSONObject: ["version": 1, "rows": rowsJSON, "overflow": [String: Int]()])
            let stored = Mutex<Data?>(file)
            let storage = HealthKitSkippedRowStorage(
                load: { stored.withLock { $0 } },
                save: { data in stored.withLock { $0 = data } }
            )

            let register = HealthKitSkippedRowRegister(storage: storage)
            #expect(await register.count(ownerID: "account-a") == 500)
            try await register.record(
                Self.unconfirmed("fresh", count: 500, base: base.addingTimeInterval(86400)),
                ownerID: "account-a",
                build: "320"
            )

            let reopened = HealthKitSkippedRowRegister(storage: storage)
            let ids = await Set(reopened.rows(ownerID: "account-a").map(\.id))
            #expect(ids.count == 1000)
            #expect(ids.contains("legacy-0"))
            #expect(await reopened.overflowCount(ownerID: "account-a") == 0)
        }

        // MARK: - Bisection refusals and the unanswered bound

        @Test("more than 500 rows refused one by one in a split page stay within the 500 bound")
        func bisectionRefusalsAreBounded() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let base = Date(timeIntervalSince1970: 1_726_000_000)
            let refused = (0 ..< 620).map { index in
                HealthKitSkippedEntry(
                    entry: SkipFixture.entry("split-\(index)", at: base.addingTimeInterval(Double(index))),
                    reason: HealthKitBatchRejection.individuallyRefusedReason(status: 422)
                )
            }
            try await register.record(refused, ownerID: "account-a", build: "300")

            #expect(await register.count(ownerID: "account-a") == HealthKitSkippedRowRegister.maxRowsPerOwner)
            #expect(await register.overflowCount(ownerID: "account-a") == 120)
        }

        @Test("unanswered rows have their own, higher bound")
        func unansweredRowsHaveTheirOwnBound() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let base = Date(timeIntervalSince1970: 1_726_000_000)
            let extra = 7
            try await register.record(
                Self.unconfirmed("held", count: HealthKitSkippedRowRegister.maxUnansweredRowsPerOwner + extra, base: base),
                ownerID: "account-a",
                build: "300"
            )
            #expect(await register.count(ownerID: "account-a") == HealthKitSkippedRowRegister.maxUnansweredRowsPerOwner)
            #expect(await register.overflowCount(ownerID: "account-a") == extra)
        }

        // MARK: - Unanswered rows are offered again on their own

        private static func reoffer(
            _ register: HealthKitSkippedRowRegister,
            failing: Bool = false
        ) -> HealthKitSkippedRowReoffer {
            HealthKitSkippedRowReoffer(register: register) { entries in
                if failing { throw HLError.offline }
                let response = HealthKitBatchResponseDTO(
                    processed: entries.count,
                    inserted: entries.count,
                    duplicates: 0,
                    skipped: [],
                    entries: entries.indices.map { .init(index: $0, status: .inserted) }
                )
                return [BatchUploadOutcome(chunk: entries, response: response)]
            }
        }

        @Test("unanswered rows wait, then go out in batches of at most 500, whatever the build")
        func unansweredRowsAreRetriedWithBackoff() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let t0 = Date(timeIntervalSince1970: 1_760_000_000)
            try await register.record(
                Self.unconfirmed("held", count: 620, base: t0),
                ownerID: "account-a",
                build: "300",
                at: t0
            )
            // Same build: the per-build re-offer would never send them again.
            #expect(await register.rowsDue(ownerID: "account-a", build: "300").isEmpty)
            #expect(await register.unansweredRowsDue(ownerID: "account-a", at: t0.addingTimeInterval(600)).isEmpty)

            let later = t0.addingTimeInterval(16 * 60)
            let first = await Self.reoffer(register).run(ownerID: "account-a", build: "300", force: false, at: later)
            #expect(first.offered == HealthKitSkippedRowRegister.unansweredRetryBatch)
            #expect(first.stored == HealthKitSkippedRowRegister.unansweredRetryBatch)
            #expect(await register.count(ownerID: "account-a") == 120)

            let second = await Self.reoffer(register).run(ownerID: "account-a", build: "300", force: false, at: later)
            #expect(second.stored == 120)
            #expect(await register.count(ownerID: "account-a") == 0)
        }

        @Test("an offer without a verdict keeps the rows and makes the next wait longer")
        func failedOfferBacksOff() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let t0 = Date(timeIntervalSince1970: 1_760_000_000)
            try await register.record(Self.unconfirmed("held", count: 3, base: t0), ownerID: "account-a", build: "300", at: t0)

            let attempt = t0.addingTimeInterval(16 * 60)
            let summary = await Self.reoffer(register, failing: true)
                .run(ownerID: "account-a", build: "300", force: false, at: attempt)
            #expect(summary.transportFailed)
            #expect(await register.count(ownerID: "account-a") == 3)
            #expect(await register.rows(ownerID: "account-a").allSatisfy { $0.attempts == 2 })
            // Two attempts: 30 minutes from the failed offer.
            #expect(await register.unansweredRowsDue(ownerID: "account-a", at: attempt.addingTimeInterval(20 * 60)).isEmpty)
            #expect(await register.unansweredRowsDue(ownerID: "account-a", at: attempt.addingTimeInterval(31 * 60)).count == 3)
        }
    }
#endif
