#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import SpeziHealthKit
    import Testing

    /// W-HR-BUCKET-UPLOAD / GH #34 — the HEADLINE per-day-exclusivity invariant.
    ///
    /// The cutover boundary guarantees that no UTC day ever carries BOTH raw
    /// per-sample HR rows AND `stats:` bucket rows (the server's nightly PULSE
    /// rollup would otherwise double-count). This suite proves the per-sample
    /// half of that contract at the `HealthLogStandard` gate:
    ///
    /// - a day < cutover → HR flows per-sample (raw), unchanged;
    /// - a day >= cutover → HR is DROPPED from the per-sample path (the bucket
    ///   sweep owns it) → no day ever yields both;
    /// - the gate only touches heartRate — every other identifier is untouched.
    @Suite("HealthLogStandard — HR-bucket cutover gate (per-day exclusivity)")
    struct HealthLogStandardHRBucketGateTests {
        // MARK: - Stubs (mirror HealthLogStandardForwardingTests)

        private final class CapturingAPI: APIClientProtocol, @unchecked Sendable {
            private let lock = NSLock()
            private var _batches: [HealthKitBatchPayload] = []

            var batches: [HealthKitBatchPayload] {
                lock.withLock { _batches }
            }

            var entryCount: Int {
                lock.withLock { _batches.reduce(0) { $0 + $1.entries.count } }
            }

            func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
                guard let body = request.body else { throw HLError.unknown("test stub: no body") }
                let payload = try BatchUploadOutcomeTests.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                lock.withLock { _batches.append(payload) }
                let entryResults: [HealthKitBatchResponseDTO.EntryResult] = payload.entries.indices.map { idx in
                    HealthKitBatchResponseDTO.EntryResult(index: idx, status: .inserted)
                }
                let response = HealthKitBatchResponseDTO(
                    processed: payload.entries.count,
                    inserted: payload.entries.count,
                    duplicates: 0,
                    skipped: [],
                    entries: entryResults
                )
                guard let typed = response as? T else { throw HLError.unknown("test stub: T mismatch") }
                return typed
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.unknown("test stub: download not implemented")
            }
        }

        private struct FlagStub: FeatureFlagsServicing {
            let hrBucketEnabled: Bool
            func isEnabled(_ flag: FeatureFlag) -> Bool {
                switch flag {
                case .enableHRBuckets: hrBucketEnabled
                case .enableDailyStats: false // keep the cumulative gate out of the way
                default: flag.defaultValue
                }
            }
        }

        private func makeUploader(api: CapturingAPI) -> MeasurementBatchUploader {
            MeasurementBatchUploader(api: api, throttle: BatchSyncThrottle())
        }

        /// Build an HR sample whose `endDate` is a fixed instant, so the cutover
        /// gate (which compares `entry.endDate` against the boundary) is
        /// deterministic.
        private func makeHRSample(bpm: Double, endingAt end: Date) -> HKQuantitySample {
            let type = HKQuantityType(.heartRate)
            let unit = HKUnit.count().unitDivided(by: .minute())
            let quantity = HKQuantity(unit: unit, doubleValue: bpm)
            return HKQuantitySample(type: type, quantity: quantity, start: end.addingTimeInterval(-30), end: end)
        }

        private func makeQuantitySample(
            identifier: HKQuantityTypeIdentifier,
            unit: HKUnit,
            value: Double,
            endingAt end: Date
        ) -> HKQuantitySample {
            let quantity = HKQuantity(unit: unit, doubleValue: value)
            return HKQuantitySample(
                type: HKQuantityType(identifier),
                quantity: quantity,
                start: end.addingTimeInterval(-30),
                end: end
            )
        }

        private func iso(_ s: String) -> Date {
            // swiftlint:disable:next force_unwrapping
            ISO8601DateFormatter.fractional.date(from: s)!
        }

        /// A fixed cutover boundary: 2026-06-22T00:00:00Z.
        private var cutover: Date {
            iso("2026-06-22T00:00:00.000Z")
        }

        private func cutoverGate() -> @Sendable (Date) -> Bool {
            let boundary = cutover
            return { date in date >= boundary }
        }

        // MARK: - The exclusivity proof

        @Test("day < cutover: HR flows per-sample (raw), unchanged")
        func preCutoverHRFlowsPerSample() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(
                uploader,
                featureFlags: FlagStub(hrBucketEnabled: true),
                hrCutoverGate: cutoverGate()
            )

            // Pre-cutover sample (the partial current day / historical).
            let sample = makeHRSample(bpm: 72, endingAt: iso("2026-06-21T20:00:00.000Z"))
            await standard.handleNewSamples([sample], ofType: SampleType.heartRate)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.heartRate.rawValue)
            #expect(entry.value == 72)
        }

        @Test("day >= cutover: HR is DROPPED from per-sample path (no raw + no bucket-from-here)")
        func postCutoverHRDroppedFromPerSample() async {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(
                uploader,
                featureFlags: FlagStub(hrBucketEnabled: true),
                hrCutoverGate: cutoverGate()
            )

            // On-or-after the cutover → the bucket sweep owns this hour.
            let sample = makeHRSample(bpm: 80, endingAt: iso("2026-06-23T11:30:00.000Z"))
            await standard.handleNewSamples([sample], ofType: SampleType.heartRate)

            // The per-sample batch uploader must see NOTHING for this day.
            #expect(api.entryCount == 0)
        }

        @Test("NO DOUBLE-COUNT: a mixed batch keeps only pre-cutover HR per-sample, drops on/after-cutover HR")
        func noDoubleCountMixedBatch() async {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(
                uploader,
                featureFlags: FlagStub(hrBucketEnabled: true),
                hrCutoverGate: cutoverGate()
            )

            let samples = [
                makeHRSample(bpm: 70, endingAt: iso("2026-06-21T09:00:00.000Z")), // pre  → keep raw
                makeHRSample(bpm: 71, endingAt: iso("2026-06-21T23:59:59.000Z")), // pre  → keep raw
                makeHRSample(bpm: 90, endingAt: iso("2026-06-22T00:00:00.000Z")), // ==   → drop (bucket)
                makeHRSample(bpm: 95, endingAt: iso("2026-06-24T08:00:00.000Z")) // post → drop (bucket)
            ]
            await standard.handleNewSamples(samples, ofType: SampleType.heartRate)

            // Exactly the two pre-cutover samples remain on the per-sample path.
            // The on/after-cutover ones are gone → those days never get BOTH a
            // raw per-sample row AND a `stats:` bucket row.
            #expect(api.entryCount == 2)
            let bpms = Set(api.batches.flatMap { $0.entries.map(\.value) })
            #expect(bpms == [70, 71])
        }

        @Test("flag OFF: cutover gate is inert — HR flows per-sample even on/after the boundary")
        func flagOffHRAlwaysPerSample() async {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(
                uploader,
                featureFlags: FlagStub(hrBucketEnabled: false),
                hrCutoverGate: cutoverGate()
            )

            let sample = makeHRSample(bpm: 88, endingAt: iso("2026-06-25T10:00:00.000Z"))
            await standard.handleNewSamples([sample], ofType: SampleType.heartRate)

            #expect(api.entryCount == 1)
        }

        @Test("other sample types are UNAFFECTED by the HR gate (steps on/after cutover still flow)")
        func otherTypesUnaffected() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(
                uploader,
                featureFlags: FlagStub(hrBucketEnabled: true),
                hrCutoverGate: cutoverGate()
            )

            // A stepCount sample dated AFTER the cutover — must NOT be gated by
            // the HR cutover (the HR gate is heartRate-only). dailyStats is OFF
            // in this stub so steps ride the per-sample path.
            let steps = makeQuantitySample(
                identifier: .stepCount, unit: .count(), value: 500, endingAt: iso("2026-06-24T08:00:00.000Z")
            )
            await standard.handleNewSamples([steps], ofType: SampleType.stepCount)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.stepCount.rawValue)
        }

        @Test("restingHeartRate is NOT gated (different identifier than heartRate)")
        func restingHRNotGated() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(
                uploader,
                featureFlags: FlagStub(hrBucketEnabled: true),
                hrCutoverGate: cutoverGate()
            )

            // restingHeartRate after the cutover — the bucket path is heartRate
            // ONLY, so restingHR must still flow per-sample.
            let rhr = makeQuantitySample(
                identifier: .restingHeartRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                value: 55,
                endingAt: iso("2026-06-24T08:00:00.000Z")
            )
            await standard.handleNewSamples([rhr], ofType: SampleType.restingHeartRate)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.restingHeartRate.rawValue)
        }

        @Test("respiratoryRate stays per-sample after the cutover (NOT bucketed — HR-only gate)")
        func respiratoryRateNotGated() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(
                uploader,
                featureFlags: FlagStub(hrBucketEnabled: true),
                hrCutoverGate: cutoverGate()
            )

            // respiratoryRate on/after the cutover — only heartRate is bucketed,
            // so respiratoryRate must still flow per-sample (volume doesn't
            // justify bucketing; server allowlist can add it later).
            let resp = makeQuantitySample(
                identifier: .respiratoryRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                value: 14,
                endingAt: iso("2026-06-24T08:00:00.000Z")
            )
            await standard.handleNewSamples([resp], ofType: SampleType.respiratoryRate)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.respiratoryRate.rawValue)
            // Per-sample rows never carry the bucket spread fields.
            #expect(entry.valueMin == nil)
            #expect(entry.valueMax == nil)
        }

        /// Der Betreiber-Schalter der P2-Einheit wirkt über
        /// ``HRUploadModeSchedule`` auf **denselben** Gate wie der Stichtag. Hier
        /// wird die Produktions-Verdrahtung nachgebaut (Closure über den Plan
        /// statt fester Grenze), damit der Einzel-Batch-Pfad nachweislich auf
        /// eine Umschaltung reagiert — und zwar erst ab der Tagesgrenze.
        @Test("Betreiber-Umschaltung: ein Roh-Tag fließt wieder per-Sample, ein Faltungs-Tag nicht")
        func operatorSwitchDrivesThePerSampleGate() async throws {
            let suite = "test.hrgate.\(UUID().uuidString)"
            // swiftlint:disable:next force_unwrapping
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            let user = "u1"
            // swiftlint:disable:next force_unwrapping
            let defaults = try #require(UserDefaults(suiteName: suite))
            HRBucketCutoverStore.cutover(userId: user, now: iso("2026-06-21T14:00:00.000Z"), defaults: defaults)
            HRUploadModeSchedule.setDesiredMode(
                .raw, userId: user, now: iso("2026-06-25T14:00:00.000Z"), defaults: defaults
            )
            let now = iso("2026-06-27T10:00:00.000Z")
            let gate: @Sendable (Date) -> Bool = { date in
                // swiftlint:disable:next force_unwrapping
                let suiteDefaults = UserDefaults(suiteName: suite)!
                return HRUploadModeSchedule.mode(
                    at: date, userId: user, now: now, defaults: suiteDefaults
                ) == .buckets
            }

            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(
                uploader,
                featureFlags: FlagStub(hrBucketEnabled: true),
                hrCutoverGate: gate
            )

            let samples = [
                makeHRSample(bpm: 60, endingAt: iso("2026-06-23T09:00:00.000Z")), // Faltungs-Tag → verwerfen
                makeHRSample(bpm: 61, endingAt: iso("2026-06-25T23:00:00.000Z")), // Tipp-Tag, noch Faltung → verwerfen
                makeHRSample(bpm: 62, endingAt: iso("2026-06-26T00:00:00.000Z")), // ab Tagesgrenze roh → behalten
                makeHRSample(bpm: 63, endingAt: iso("2026-06-27T09:00:00.000Z")) // roh → behalten
            ]
            await standard.handleNewSamples(samples, ofType: SampleType.heartRate)

            #expect(api.entryCount == 2)
            let bpms = Set(api.batches.flatMap { $0.entries.map(\.value) })
            #expect(bpms == [62, 63])
        }

        @Test("oxygenSaturation (SpO2) stays per-sample after the cutover (NOT bucketed)")
        func oxygenSaturationNotGated() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(
                uploader,
                featureFlags: FlagStub(hrBucketEnabled: true),
                hrCutoverGate: cutoverGate()
            )

            // SpO2 on/after the cutover — only heartRate is bucketed, so SpO2
            // must still flow per-sample.
            let spo2 = makeQuantitySample(
                identifier: .oxygenSaturation,
                unit: .percent(),
                value: 0.98,
                endingAt: iso("2026-06-24T08:00:00.000Z")
            )
            await standard.handleNewSamples([spo2], ofType: SampleType.bloodOxygen)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.oxygenSaturation.rawValue)
            #expect(entry.valueMin == nil)
            #expect(entry.valueMax == nil)
        }
    }
#endif
