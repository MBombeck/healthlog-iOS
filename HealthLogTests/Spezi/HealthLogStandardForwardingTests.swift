#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import SpeziHealthKit
    import Testing

    /// Behavioural contract for `HealthLogStandard.handleNewSamples` —
    /// the v0.5.5 W-A3 forwarding path that hands Steps + ActiveEnergy
    /// observed by SpeziHealthKit's `CollectSamples` collectors over to
    /// the same `MeasurementBatchUploader` the legacy `HealthKitService`
    /// uses for everything else.
    ///
    /// The suite intentionally bypasses the SpeziHealthKit collector
    /// machinery and exercises the Standard's actor surface directly with
    /// real `HKQuantitySample` instances. That keeps the test hermetic
    /// (no full Spezi boot needed) while still proving the four
    /// invariants the legacy pipeline guarantees:
    ///
    /// 1. Foreign sample reaches the uploader (happy path).
    /// 2. Own sample (`HKMetadataKeyExternalUUID` set) is dropped.
    /// 3. `enableDailyStats` ON ⇒ stepCount is dropped (HK-STATS gate).
    /// 4. `enableDailyStats` OFF ⇒ stepCount flows.
    /// 5. A delivery arriving before composition waits for the uploader and is
    ///    forwarded after attachment instead of being silently consumed.
    @Suite("HealthLogStandard — forwarding behaviour")
    struct HealthLogStandardForwardingTests {
        // MARK: - Helpers

        /// In-memory uploader stub — captures each entry batch the
        /// standard forwards. Wired into the real `MeasurementBatchUploader`
        /// via the `APIClientProtocol` seam the existing
        /// `BatchUploaderStubAPI` uses (mirrors that pattern so the
        /// HK-batch envelope encoding stays exercised end-to-end).
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
                guard let body = request.body else {
                    throw HLError.unknown("test stub: no body")
                }
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
                guard let typed = response as? T else {
                    throw HLError.unknown("test stub: T mismatch")
                }
                return typed
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {}

            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.unknown("test stub: download not implemented")
            }
        }

        /// Minimal `FeatureFlagsServicing` honoring a single static flag
        /// override. Mirrors `LiveFeatureFlagsService` but with a fixed
        /// state for the test horizon.
        private struct FlagStub: FeatureFlagsServicing {
            let dailyStatsEnabled: Bool

            func isEnabled(_ flag: FeatureFlag) -> Bool {
                switch flag {
                case .enableDailyStats:
                    dailyStatsEnabled
                default:
                    flag.defaultValue
                }
            }
        }

        private func makeUploader(api: CapturingAPI) -> MeasurementBatchUploader {
            MeasurementBatchUploader(api: api, throttle: BatchSyncThrottle())
        }

        /// Build an `HKQuantitySample` in the same wire unit
        /// ``HealthKitWireConverter/preferredUnit(for:)`` uses, so the
        /// round-trip through `HealthLogStandard.handleNewSamples` lands
        /// on the API stub with the exact value the test passes in.
        /// Falls back to `count()` for identifiers without a known unit
        /// (only relevant when a new cluster is added before the wire
        /// converter learns about it — keeps the test scaffold tolerant).
        private func makeQuantitySample(
            identifier: HKQuantityTypeIdentifier,
            value: Double,
            externalUUID: String? = nil
        ) -> HKQuantitySample {
            let type = HKQuantityType(identifier)
            let unit = Self.testUnit(for: identifier)
            let quantity = HKQuantity(unit: unit, doubleValue: value)
            let now = Date()
            var metadata: [String: Any] = [:]
            if let externalUUID {
                metadata[HKMetadataKeyExternalUUID] = externalUUID
            }
            return HKQuantitySample(
                type: type,
                quantity: quantity,
                start: now.addingTimeInterval(-60),
                end: now,
                metadata: metadata.isEmpty ? nil : metadata
            )
        }

        /// Mirror of the wire-converter unit picker, kept duplicated in
        /// the test so a converter refactor surfaces here as a build error
        /// rather than a silent value drift.
        private static func testUnit(for identifier: HKQuantityTypeIdentifier) -> HKUnit {
            switch identifier {
            case .stepCount, .flightsClimbed:
                .count()
            case .activeEnergyBurned:
                .kilocalorie()
            case .heartRate, .restingHeartRate:
                HKUnit.count().unitDivided(by: .minute())
            case .heartRateVariabilitySDNN:
                .secondUnit(with: .milli)
            case .oxygenSaturation, .bodyFatPercentage, .walkingAsymmetryPercentage:
                .percent()
            case .bodyTemperature:
                .degreeCelsius()
            case .bodyMass:
                .gramUnit(with: .kilo)
            case .bodyMassIndex:
                .count()
            case .walkingSpeed:
                HKUnit.meter().unitDivided(by: .second())
            case .walkingStepLength:
                .meter()
            case .bloodPressureSystolic, .bloodPressureDiastolic:
                .millimeterOfMercury()
            default:
                .count()
            }
        }

        // MARK: - Tests

        @Test("foreign stepCount sample reaches uploader when dailyStats is OFF")
        func foreignStepCountFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let sample = makeQuantitySample(identifier: .stepCount, value: 500)
            await standard.handleNewSamples([sample], ofType: SampleType.stepCount)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.stepCount.rawValue)
            #expect(entry.value == 500)
        }

        @Test("G-7: a THIRD-PARTY sample carrying an externalUUID is forwarded (not silently dropped)")
        func thirdPartyUUIDSampleIsForwarded() async {
            // Pre-G-7 this asserted entryCount == 0 ("any externalUUID ⇒
            // skip"), which silently dropped genuine third-party data. A
            // test-constructed sample is unsaved ⇒ its source is NOT
            // HKSource.default() ⇒ it is foreign and now correctly forwarded.
            // Our own echo (our externalUUID AND our source) is still skipped —
            // that path is pinned at the predicate level in
            // HealthKitSampleOwnershipTests (the test host cannot forge an
            // own-source HKSample).
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let thirdParty = makeQuantitySample(identifier: .stepCount, value: 200, externalUUID: "abc-123")
            await standard.handleNewSamples([thirdParty], ofType: SampleType.stepCount)

            #expect(api.entryCount == 1)
        }

        @Test("dailyStats ON drops stepCount from per-sample path (HK-STATS gate)")
        func dailyStatsGateDropsStepCount() async {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: true))

            let sample = makeQuantitySample(identifier: .stepCount, value: 500)
            await standard.handleNewSamples([sample], ofType: SampleType.stepCount)

            // Step samples ride the HKStatisticsSyncCoordinator path
            // instead. The standard's batch uploader sees nothing.
            #expect(api.entryCount == 0)
        }

        @Test("dailyStats ON drops activeEnergyBurned from per-sample path too")
        func dailyStatsGateDropsActiveEnergy() async {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: true))

            let sample = makeQuantitySample(identifier: .activeEnergyBurned, value: 42)
            await standard.handleNewSamples([sample], ofType: SampleType.activeEnergyBurned)

            #expect(api.entryCount == 0)
        }

        @Test("delivery before uploader attachment is retained and forwarded after composition")
        func deliveryBeforeUploaderAttachmentIsRetained() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            let sample = makeQuantitySample(identifier: .heartRateVariabilitySDNN, value: 42)

            let delivery = Task {
                await standard.handleNewSamples([sample], ofType: SampleType.heartRateVariabilitySDNN)
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(api.entryCount == 0)

            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))
            await delivery.value

            #expect(api.entryCount == 1)
        }

        // MARK: - W-A4 cluster c1 — vital-signs (heartRate, HRV, restingHR)

        @Test("foreign heartRate sample reaches uploader (cluster c1)")
        func foreignHeartRateFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let sample = makeQuantitySample(identifier: .heartRate, value: 72)
            await standard.handleNewSamples([sample], ofType: SampleType.heartRate)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.heartRate.rawValue)
            #expect(entry.value == 72)
            #expect(entry.unit == "bpm")
        }

        @Test("foreign heartRateVariabilitySDNN sample reaches uploader (cluster c1)")
        func foreignHeartRateVariabilityFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let sample = makeQuantitySample(identifier: .heartRateVariabilitySDNN, value: 42)
            await standard.handleNewSamples([sample], ofType: SampleType.heartRateVariabilitySDNN)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue)
            #expect(entry.value == 42)
            #expect(entry.unit == "ms")
        }

        // MARK: - W-A4 cluster c2 — blood-chemistry (SpO2 + bodyTemp)

        @Test("foreign oxygenSaturation sample reaches uploader (cluster c2)")
        func foreignOxygenSaturationFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            // HK stores SpO2 as a 0..1 fraction; the wire converter
            // scales by 100 so the server receives the % value.
            let sample = makeQuantitySample(identifier: .oxygenSaturation, value: 0.97)
            await standard.handleNewSamples([sample], ofType: SampleType.bloodOxygen)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.oxygenSaturation.rawValue)
            #expect(entry.value == 97)
            #expect(entry.unit == "%")
        }

        @Test("foreign bodyTemperature sample reaches uploader (cluster c2)")
        func foreignBodyTemperatureFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let sample = makeQuantitySample(identifier: .bodyTemperature, value: 36.8)
            await standard.handleNewSamples([sample], ofType: SampleType.bodyTemperature)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.bodyTemperature.rawValue)
            #expect(entry.value == 36.8)
            #expect(entry.unit == "degC")
        }

        @Test("foreign restingHeartRate sample reaches uploader (cluster c1)")
        func foreignRestingHeartRateFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let sample = makeQuantitySample(identifier: .restingHeartRate, value: 58)
            await standard.handleNewSamples([sample], ofType: SampleType.restingHeartRate)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.restingHeartRate.rawValue)
            #expect(entry.value == 58)
            #expect(entry.unit == "bpm")
        }

        // MARK: - W-A4 cluster c3 — mass (bodyMass + bodyFat + BMI)

        @Test("foreign bodyMass sample reaches uploader (cluster c3)")
        func foreignBodyMassFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let sample = makeQuantitySample(identifier: .bodyMass, value: 82.4)
            await standard.handleNewSamples([sample], ofType: SampleType.bodyMass)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.bodyMass.rawValue)
            #expect(entry.value == 82.4)
            #expect(entry.unit == "kg")
        }

        @Test("foreign bodyFatPercentage sample reaches uploader (cluster c3)")
        func foreignBodyFatFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            // HK stores body-fat as a 0..1 fraction; converter scales by
            // 100 so the server receives the % value.
            let sample = makeQuantitySample(identifier: .bodyFatPercentage, value: 0.21)
            await standard.handleNewSamples([sample], ofType: SampleType.bodyFatPercentage)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.bodyFatPercentage.rawValue)
            #expect(entry.value == 21)
            #expect(entry.unit == "%")
        }

        @Test("foreign bodyMassIndex sample reaches uploader (cluster c3)")
        func foreignBMIFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let sample = makeQuantitySample(identifier: .bodyMassIndex, value: 24.3)
            await standard.handleNewSamples([sample], ofType: SampleType.bodyMassIndex)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.bodyMassIndex.rawValue)
            #expect(entry.value == 24.3)
            #expect(entry.unit == "kg/m^2")
        }

        // MARK: - W-A4 cluster c4 — walking (speed + asymmetry + step length)

        @Test("foreign walkingSpeed sample reaches uploader (cluster c4)")
        func foreignWalkingSpeedFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let sample = makeQuantitySample(identifier: .walkingSpeed, value: 1.25)
            await standard.handleNewSamples([sample], ofType: SampleType.walkingSpeed)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.walkingSpeed.rawValue)
            #expect(entry.value == 1.25)
            #expect(entry.unit == "m/s")
        }

        @Test("foreign walkingAsymmetryPercentage sample reaches uploader (cluster c4)")
        func foreignWalkingAsymmetryFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            // W-SERVER-SYNC (server v1.5.5): HK stores asymmetry as a 0..1
            // fraction and the converter now sends it RAW (scale: 1), like
            // walkingSteadiness — the server scales ×100 server-side. The
            // previous iOS ×100 would double-scale against v1.5.5.
            let sample = makeQuantitySample(identifier: .walkingAsymmetryPercentage, value: 0.04)
            await standard.handleNewSamples(
                [sample],
                ofType: SampleType.walkingAsymmetryPercentage
            )

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue)
            #expect(abs(entry.value - 0.04) < 0.0001)
            #expect(entry.unit == "%")
        }

        @Test("foreign walkingStepLength sample reaches uploader (cluster c4)")
        func foreignWalkingStepLengthFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let sample = makeQuantitySample(identifier: .walkingStepLength, value: 0.72)
            await standard.handleNewSamples([sample], ofType: SampleType.walkingStepLength)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.walkingStepLength.rawValue)
            #expect(entry.value == 0.72)
            #expect(entry.unit == "m")
        }

        // MARK: - W-A4 cluster c5 — blood-pressure (sys + dia delivered separately)

        @Test("foreign bloodPressureSystolic sample reaches uploader (cluster c5)")
        func foreignBloodPressureSystolicFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let sample = makeQuantitySample(identifier: .bloodPressureSystolic, value: 124)
            await standard.handleNewSamples([sample], ofType: SampleType.bloodPressureSystolic)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue)
            #expect(entry.value == 124)
            #expect(entry.unit == "mmHg")
        }

        @Test("foreign bloodPressureDiastolic sample reaches uploader (cluster c5)")
        func foreignBloodPressureDiastolicFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            let sample = makeQuantitySample(identifier: .bloodPressureDiastolic, value: 81)
            await standard.handleNewSamples([sample], ofType: SampleType.bloodPressureDiastolic)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue)
            #expect(entry.value == 81)
            #expect(entry.unit == "mmHg")
        }

        // MARK: - W-A4 cluster c6 — sleep (HKCategorySample dispatch)

        /// Build an `HKCategorySample` for sleepAnalysis with the given
        /// stage value (`HKCategoryValueSleepAnalysis` raw int) and a
        /// duration in minutes. Matches the wire converter's
        /// `sleepEntry` expectation that `endDate - startDate` yields
        /// the row's duration in minutes.
        private func makeSleepSample(
            stage value: Int,
            minutes: Double,
            externalUUID: String? = nil
        ) -> HKCategorySample {
            let type = HKCategoryType(.sleepAnalysis)
            let now = Date()
            var metadata: [String: Any] = [:]
            if let externalUUID {
                metadata[HKMetadataKeyExternalUUID] = externalUUID
            }
            return HKCategorySample(
                type: type,
                value: value,
                start: now.addingTimeInterval(-(minutes * 60)),
                end: now,
                metadata: metadata.isEmpty ? nil : metadata
            )
        }

        @Test("foreign sleepAnalysis sample reaches uploader (cluster c6)")
        func foreignSleepSampleFlows() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            // 60-min REM sample. `HKCategoryValueSleepAnalysis.asleepREM`
            // is rawValue 5 on iOS 16+.
            let sample = makeSleepSample(stage: 5, minutes: 60)
            await standard.handleNewSamples([sample], ofType: SampleType.sleepAnalysis)

            #expect(api.entryCount == 1)
            let entry = try #require(api.batches.first?.entries.first)
            #expect(entry.hkIdentifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue)
            #expect(entry.unit == "min")
            #expect(entry.sleepStage == 5)
            // Allow a tiny tolerance — the duration is computed from the
            // Date difference and platform clock resolution may shave
            // sub-millisecond fractions off the requested 60.
            #expect(abs(entry.value - 60) < 0.01)
        }

        @Test("sleep batch with multiple stages yields one entry per stage (cluster c6)")
        func sleepBatchPerStageExpansion() async throws {
            let api = CapturingAPI()
            let uploader = makeUploader(api: api)
            let standard = HealthLogStandard()
            await standard.attachUploader(uploader, featureFlags: FlagStub(dailyStatsEnabled: false))

            // Four stages — Awake / Core / Deep / REM — Apple's
            // raw values 2, 3, 4, 5 on iOS 16+.
            let samples = [
                makeSleepSample(stage: 2, minutes: 5),
                makeSleepSample(stage: 3, minutes: 240),
                makeSleepSample(stage: 4, minutes: 90),
                makeSleepSample(stage: 5, minutes: 60)
            ]
            await standard.handleNewSamples(samples, ofType: SampleType.sleepAnalysis)

            #expect(api.entryCount == 4)
            let batch = try #require(api.batches.first)
            let stages = batch.entries.compactMap(\.sleepStage)
            #expect(Set(stages) == [2, 3, 4, 5])
            #expect(batch.entries.allSatisfy {
                $0.hkIdentifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue
                    && $0.unit == "min"
            })
        }

        /// Cross-test: after the Spezi-delivered sys + dia HK samples land
        /// in the model store (via the server roundtrip), the downstream
        /// `MetricSeriesProjection.systolicOnly` layer keeps extracting
        /// systolic components correctly. The projection is pure (no
        /// HK-source coupling), so this proof guards against a future
        /// refactor that accidentally introduces a delivery-source branch
        /// in the projection. HP2 pairing-tolerance is preserved.
        @Test("MetricSeriesProjection.systolicOnly stays correct on Spezi-delivered BP rows")
        func bloodPressureProjectionAfterSpeziDelivery() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            // Two paired BP rows as the server returns them after Spezi
            // delivered the originating samples as two separate
            // `HKQuantitySample` instances. `MeasurementAggregator` paired
            // them server-side; the projection layer sees the merged
            // Measurement row.
            let samples: [HealthLog.Measurement] = [
                HealthLog.Measurement(
                    id: "bp-1",
                    kind: .bloodPressure,
                    recordedAt: now.addingTimeInterval(-300),
                    value: .bloodPressure(systolic: 124, diastolic: 81),
                    source: .manual
                ),
                HealthLog.Measurement(
                    id: "bp-2",
                    kind: .bloodPressure,
                    recordedAt: now.addingTimeInterval(-100),
                    value: .bloodPressure(systolic: 126, diastolic: 82),
                    source: .manual
                )
            ]
            let result = MetricSeriesProjection.systolicOnly(samples)
            // Sorted ascending by recordedAt → 124 first, 126 second.
            #expect(result == [124, 126])
        }
    }
#endif
