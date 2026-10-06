#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Synchronization
    import Testing

    // #113 / 0.3 — doubles shared by the skip-register suites.

    /// Batch API stub that answers every posted row with a verdict chosen by a
    /// closure, the way the deployed route answers: `entries[]` always, and a
    /// mirrored `skipped[]` row for every skip.
    final class VerdictBatchAPI: APIClientProtocol, @unchecked Sendable {
        typealias Verdict = (status: HealthKitEntryStatus, reason: String?)

        private let verdict: @Sendable (HealthKitBatchEntryDTO) -> Verdict
        private let posted = Mutex<[[HealthKitBatchEntryDTO]]>([])
        private let failing = Mutex<Bool>(false)

        init(_ verdict: @escaping @Sendable (HealthKitBatchEntryDTO) -> Verdict) {
            self.verdict = verdict
        }

        var postedBatches: [[HealthKitBatchEntryDTO]] {
            posted.withLock { $0 }
        }

        func failTransport(_ value: Bool) {
            failing.withLock { $0 = value }
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            if failing.withLock({ $0 }) { throw HLError.offline }
            guard let body = request.body else { throw HLError.unknown("no body") }
            let payload = try BatchUploadOutcomeTests.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
            posted.withLock { $0.append(payload.entries) }
            var entries: [HealthKitBatchResponseDTO.EntryResult] = []
            var skipped: [HealthKitBatchResponseDTO.SkippedEntry] = []
            for (index, entry) in payload.entries.enumerated() {
                let answer = verdict(entry)
                entries.append(.init(index: index, status: answer.status, reason: answer.reason))
                if answer.status == .skipped {
                    skipped.append(.init(index: index, reason: answer.reason ?? "unknown"))
                }
            }
            let response = HealthKitBatchResponseDTO(
                processed: payload.entries.count,
                inserted: entries.count(where: { $0.status == .inserted }),
                duplicates: entries.count(where: { $0.status == .duplicate }),
                skipped: skipped,
                entries: entries
            )
            guard let typed = response as? T else { throw HLError.unknown("T mismatch") }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("download not implemented")
        }
    }

    /// In-memory backing for the register; `lossy` drops every save.
    final class SkipRegisterBacking: Sendable {
        private let data = Mutex<Data?>(nil)
        private let lossy: Bool

        init(lossy: Bool = false) {
            self.lossy = lossy
        }

        var storage: HealthKitSkippedRowStorage {
            HealthKitSkippedRowStorage(
                load: { [self] in data.withLock { $0 } },
                save: { [self] value in
                    guard !lossy else { return }
                    data.withLock { $0 = value }
                }
            )
        }
    }

    enum SkipFixture {
        static let spo2 = HKQuantityTypeIdentifier.oxygenSaturation.rawValue

        static func entry(
            _ id: String,
            type: String = spo2,
            value: Double = 0.97,
            at date: Date = Date(timeIntervalSince1970: 1_726_300_800)
        ) -> HealthKitBatchEntryDTO {
            HealthKitBatchEntryDTO(
                hkIdentifier: type,
                value: value,
                unit: "%",
                startDate: date,
                endDate: date,
                externalId: id
            )
        }

        static func spo2Sample(_ fraction: Double) -> HKQuantitySample {
            let date = Date(timeIntervalSince1970: 1_726_300_800)
            return HKQuantitySample(
                type: HKQuantityType(.oxygenSaturation),
                quantity: HKQuantity(unit: .percent(), doubleValue: fraction),
                start: date,
                end: date
            )
        }

        static let outOfRange: VerdictBatchAPI.Verdict = (.skipped, MeasurementBatchAcceptance.Reason.valueOutOfRange)
    }

    /// The register itself: owner partition, bound, durability, relaunch.
    @Suite("HealthKit skip register (#113)")
    struct HealthKitSkippedRowRegisterTests {
        @Test("a refused row is kept with type, date, value, reason and account")
        func refusedRowIsKeptWithEverythingNeededToSeeIt() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let entry = SkipFixture.entry("uuid-1")
            try await register.record(
                [HealthKitSkippedEntry(entry: entry, reason: "value_out_of_range")],
                ownerID: "account-a",
                build: "280"
            )

            let rows = await register.rows(ownerID: "account-a")
            let row = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(row.hkIdentifier == SkipFixture.spo2)
            #expect(row.measuredAt == entry.startDate)
            #expect(row.entry?.value == 0.97)
            #expect(row.reason == "value_out_of_range")
            #expect(row.ownerID == "account-a")
            #expect(row.lastOfferedBuild == "280")
            #expect(await register.countsByIdentifier(ownerID: "account-a") == [SkipFixture.spo2: 1])
        }

        @Test("rows are partitioned by account and recording the same row twice updates it")
        func ownerPartitionedAndIdempotent() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let skipped = [HealthKitSkippedEntry(entry: SkipFixture.entry("uuid-1"), reason: "value_out_of_range")]
            try await register.record(skipped, ownerID: "account-a", build: "280")
            try await register.record(skipped, ownerID: "account-a", build: "281")
            try await register.record(skipped, ownerID: "account-b", build: "280")

            let rowsA = await register.rows(ownerID: "account-a")
            #expect(rowsA.count == 1)
            #expect(rowsA.first?.attempts == 2)
            #expect(rowsA.first?.lastOfferedBuild == "281")
            #expect(await register.count(ownerID: "account-b") == 1)
            #expect(await register.rows(ownerID: " ").isEmpty)
            await #expect(throws: HealthKitSkippedRowRegisterError.unownedWriteRefused) {
                try await register.record(skipped, ownerID: "  ", build: "280")
            }
        }

        @Test("the register is bounded per account; what falls off is counted, oldest first")
        func boundedPerAccount() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let base = Date(timeIntervalSince1970: 1_726_000_000)
            let extra = 3
            let skipped = (0 ..< HealthKitSkippedRowRegister.maxRowsPerOwner + extra).map { index in
                HealthKitSkippedEntry(
                    entry: SkipFixture.entry("uuid-\(index)", at: base.addingTimeInterval(Double(index) * 60)),
                    reason: "value_out_of_range"
                )
            }
            try await register.record(skipped, ownerID: "account-a", build: "280")

            let rows = await register.rows(ownerID: "account-a")
            #expect(rows.count == HealthKitSkippedRowRegister.maxRowsPerOwner)
            #expect(await register.overflowCount(ownerID: "account-a") == extra)
            #expect(!rows.contains { $0.id == "uuid-0" })
            #expect(rows.first?.id == "uuid-\(HealthKitSkippedRowRegister.maxRowsPerOwner + extra - 1)")
        }

        @Test("the register survives a relaunch and a lost write is not trusted")
        func durableAcrossRelaunchAndLossyWriteThrows() async throws {
            let backing = SkipRegisterBacking()
            let skipped = [HealthKitSkippedEntry(entry: SkipFixture.entry("uuid-1"), reason: "value_out_of_range")]
            try await HealthKitSkippedRowRegister(storage: backing.storage)
                .record(skipped, ownerID: "account-a", build: "280")
            #expect(await HealthKitSkippedRowRegister(storage: backing.storage).count(ownerID: "account-a") == 1)

            let lossy = HealthKitSkippedRowRegister(storage: SkipRegisterBacking(lossy: true).storage)
            await #expect(throws: HealthKitSkippedRowRegisterError.writeNotVerified) {
                try await lossy.record(skipped, ownerID: "account-a", build: "280")
            }
        }

        @Test("clearAll empties every account")
        func clearAllEmpties() async throws {
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let skipped = [HealthKitSkippedEntry(entry: SkipFixture.entry("uuid-1"), reason: "value_out_of_range")]
            try await register.record(skipped, ownerID: "account-a", build: "280")
            try await register.record(skipped, ownerID: "account-b", build: "280")
            await register.clearOnLogout()
            #expect(await register.count(ownerID: "account-a") == 0)
            #expect(await register.count(ownerID: "account-b") == 0)
        }
    }

    /// The consumption path: a refused row is remembered before the cursor may
    /// pass it, and the counts are honest.
    @Suite("HealthKit skip register — page consumption (#113)")
    struct HealthKitSkipRegisterConsumptionTests {
        private struct FlagStub: FeatureFlagsServicing {
            func isEnabled(_ flag: FeatureFlag) -> Bool {
                flag == .enableDailyStats ? false : flag.defaultValue
            }
        }

        private func consumption(
            api: VerdictBatchAPI,
            register: HealthKitSkippedRowRegister?
        ) -> HealthSampleConsumption {
            HealthSampleConsumption(
                uploader: MeasurementBatchUploader(api: api, throttle: BatchSyncThrottle()),
                gate: HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil),
                retry: nil,
                skipRegister: register,
                build: "280"
            )
        }

        @Test("value_out_of_range: the row lands in the register, then the page may commit")
        func outOfRangeIsRegisteredBeforeTheCursorMoves() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let api = VerdictBatchAPI { _ in SkipFixture.outOfRange }

            let (outcome, tally) = await consumption(api: api, register: register)
                .transmitReporting(
                    HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil)
                        .map([SkipFixture.spo2Sample(0.97)]),
                    admitted: lease
                )

            let rows = await register.rows(ownerID: lease.ownerID)
            #expect(rows.count == 1)
            #expect(rows.first?.reason == MeasurementBatchAcceptance.Reason.valueOutOfRange)
            #expect(rows.first?.hkIdentifier == SkipFixture.spo2)
            #expect(tally == HealthSampleServerTally(accepted: 0, skipped: 1, parked: 0))
            #expect(HealthSyncCursorPolicy.required.decide(outcome) == .commit)
        }

        @Test("a refusal with nowhere to be remembered holds the page")
        func refusalWithoutRegisterHolds() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let api = VerdictBatchAPI { _ in SkipFixture.outOfRange }

            let lossy = HealthKitSkippedRowRegister(storage: SkipRegisterBacking(lossy: true).storage)
            for register in [nil, lossy] {
                let (outcome, tally) = await consumption(api: api, register: register)
                    .transmitReporting(
                        HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil)
                            .map([SkipFixture.spo2Sample(0.97)]),
                        admitted: lease
                    )
                #expect(HealthSyncCursorPolicy.required.decide(outcome) == .hold(reason: .retryPersistenceFailed))
                #expect(tally.skipped == 0)
            }
        }

        @Test("only inserted, updated and duplicate count as uploaded")
        func onlyStoredRowsCountAsUploaded() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let byValue: [Double: VerdictBatchAPI.Verdict] = [
                0.95: (.inserted, nil), 0.96: (.duplicate, nil), 0.97: (.updated, nil), 0.98: SkipFixture.outOfRange
            ]
            let api = VerdictBatchAPI { entry in byValue[entry.value] ?? (.failed, nil) }
            let samples = [0.95, 0.96, 0.97, 0.98].map(SkipFixture.spo2Sample)

            let (_, tally) = await consumption(api: api, register: register)
                .transmitReporting(
                    HealthSampleWireGate(dailyStatsEnabled: false, hrBucketGate: nil).map(samples),
                    admitted: lease
                )
            #expect(tally == HealthSampleServerTally(accepted: 3, skipped: 1, parked: 0))
        }

        @Test("Sync Diagnostics: a refused SpO2 row is skipped, not uploaded")
        @MainActor
        func standardRecordsHonestCounts() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            let lease = try CollectorFixture.makeLease(registry: registry)
            let register = HealthKitSkippedRowRegister(storage: SkipRegisterBacking().storage)
            let standard = HealthLogStandard()
            await standard.attachUploader(
                MeasurementBatchUploader(api: VerdictBatchAPI { _ in SkipFixture.outOfRange }, throttle: BatchSyncThrottle()),
                featureFlags: FlagStub(),
                skipRegister: register
            )
            let before = HKSyncDiagnostics.shared.byIdentifier[SkipFixture.spo2]
                ?? HKSyncDiagnostics.KindStats(identifier: SkipFixture.spo2)

            _ = await standard.consumePage([SkipFixture.spo2Sample(0.97)], ofType: SkipFixture.spo2, admitted: lease)

            let after = try #require(HKSyncDiagnostics.shared.byIdentifier[SkipFixture.spo2])
            #expect(after.samplesUploadedTotal - before.samplesUploadedTotal == 0)
            #expect(after.samplesSkippedTotal - before.samplesSkippedTotal == 1)
            #expect(await register.count(ownerID: lease.ownerID) == 1)
        }
    }

    /// Offering refused rows again: once per build, on demand, never lossy.
    @Suite("HealthKit skip register — re-offer (#113)")
    struct HealthKitSkippedRowReofferTests {
        private func seeded(build: String) async throws -> (HealthKitSkippedRowRegister, SkipRegisterBacking) {
            let backing = SkipRegisterBacking()
            let register = HealthKitSkippedRowRegister(storage: backing.storage)
            try await register.record(
                [
                    HealthKitSkippedEntry(entry: SkipFixture.entry("uuid-1"), reason: "value_out_of_range"),
                    HealthKitSkippedEntry(entry: SkipFixture.entry("uuid-2", value: 0.5), reason: "value_out_of_range")
                ],
                ownerID: "account-a",
                build: build
            )
            return (register, backing)
        }

        private func reoffer(_ register: HealthKitSkippedRowRegister, api: VerdictBatchAPI) -> HealthKitSkippedRowReoffer {
            let uploader = MeasurementBatchUploader(api: api, throttle: BatchSyncThrottle())
            return HealthKitSkippedRowReoffer(register: register) { entries in
                try await uploader.upload(entries)
            }
        }

        @Test("same build: nothing is offered; after an update every row is offered once")
        func reofferedOncePerBuild() async throws {
            let (register, _) = try await seeded(build: "279")
            let api = VerdictBatchAPI { entry in
                entry.externalId == "uuid-1" ? (.inserted, nil) : SkipFixture.outOfRange
            }
            let offer = reoffer(register, api: api)

            #expect(await offer.run(ownerID: "account-a", build: "279", force: false) == .nothingToOffer)
            #expect(api.postedBatches.isEmpty)

            let summary = await offer.run(ownerID: "account-a", build: "280", force: false)
            #expect(summary == .init(offered: 2, stored: 1, stillRefused: 1, transportFailed: false))
            let rows = await register.rows(ownerID: "account-a")
            #expect(rows.map(\.id) == ["uuid-2"])
            #expect(rows.first?.attempts == 2)
            #expect(rows.first?.lastOfferedBuild == "280")

            #expect(await offer.run(ownerID: "account-a", build: "280", force: false) == .nothingToOffer)
            #expect(api.postedBatches.count == 1)
        }

        @Test("\"Resend skipped\" offers every row regardless of build")
        func manualResendOffersEverything() async throws {
            let (register, _) = try await seeded(build: "280")
            let api = VerdictBatchAPI { _ in (.duplicate, nil) }
            let summary = await reoffer(register, api: api).run(ownerID: "account-a", build: "280", force: true)
            #expect(summary == .init(offered: 2, stored: 2, stillRefused: 0, transportFailed: false))
            #expect(await register.count(ownerID: "account-a") == 0)
        }

        @Test("a transport failure changes nothing, and the rows stay due")
        func transportFailureChangesNothing() async throws {
            let (register, _) = try await seeded(build: "279")
            let api = VerdictBatchAPI { _ in (.inserted, nil) }
            api.failTransport(true)
            let summary = await reoffer(register, api: api).run(ownerID: "account-a", build: "280", force: false)
            #expect(summary.transportFailed)
            #expect(await register.rowsDue(ownerID: "account-a", build: "280").count == 2)
        }
    }
#endif
