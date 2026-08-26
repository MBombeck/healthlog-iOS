#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import SpeziHealthKit
    import Testing

    /// AUD-3 D-1 — the HK-STATS gate must FAIL CLOSED in the unconfigured
    /// window (`featureFlags == nil`, before the live flag reader is attached).
    ///
    /// Raw cumulative samples upload with `externalId = uuid`; the daily-stats
    /// coordinator uploads the same day's sum with
    /// `externalId = "stats:<id>:<day>"`. These are DIFFERENT externalIds the
    /// server cannot collapse, so a day that gets BOTH double-counts in the
    /// nightly rollup. `enableDailyStats` defaults ON and the stats path is
    /// authoritative for the cumulative types, so when the flag reader is not
    /// yet attached the gate must behave as if ON — drop the cumulative
    /// identifiers — never let them through.
    @Suite("HealthLogStandard — AUD-3 D-1 stats gate fails closed")
    struct HealthLogStandardStatsGateFailClosedTests {
        /// Captures every entry batch the standard forwards to the uploader.
        private final class CapturingAPI: APIClientProtocol, @unchecked Sendable {
            private let lock = NSLock()
            private var _entryIdentifiers: [String] = []

            var entryIdentifiers: [String] {
                lock.withLock { _entryIdentifiers }
            }

            var entryCount: Int {
                lock.withLock { _entryIdentifiers.count }
            }

            func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
                guard let body = request.body else { throw HLError.unknown("no body") }
                let payload = try BatchUploadOutcomeTests.batchDecoder().decode(HealthKitBatchPayload.self, from: body)
                lock.withLock { _entryIdentifiers.append(contentsOf: payload.entries.map(\.hkIdentifier)) }
                let entryResults: [HealthKitBatchResponseDTO.EntryResult] = payload.entries.indices.map {
                    HealthKitBatchResponseDTO.EntryResult(index: $0, status: .inserted)
                }
                let response = HealthKitBatchResponseDTO(
                    processed: payload.entries.count,
                    inserted: payload.entries.count,
                    duplicates: 0,
                    skipped: [],
                    entries: entryResults
                )
                guard let typed = response as? T else { throw HLError.unknown("T mismatch") }
                return typed
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {}
            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                throw HLError.unknown("download not implemented")
            }
        }

        private func makeUploader(api: CapturingAPI) -> MeasurementBatchUploader {
            MeasurementBatchUploader(api: api, throttle: BatchSyncThrottle())
        }

        private func stepSample(_ value: Double) -> HKQuantitySample {
            let now = Date()
            return HKQuantitySample(
                type: HKQuantityType(.stepCount),
                quantity: HKQuantity(unit: .count(), doubleValue: value),
                start: now.addingTimeInterval(-3600),
                end: now
            )
        }

        private func heartRateSample(_ value: Double) -> HKQuantitySample {
            let now = Date()
            return HKQuantitySample(
                type: HKQuantityType(.heartRate),
                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: value),
                start: now.addingTimeInterval(-60),
                end: now
            )
        }

        @Test("featureFlags == nil ⇒ cumulative stepCount is DROPPED (fail closed)")
        func nilFlagsDropsCumulative() async {
            let api = CapturingAPI()
            let standard = HealthLogStandard()
            // Attach the uploader but NO feature-flag reader (the unconfigured
            // window). Pre-fix this let cumulative through (`?? false`).
            await standard.attachUploader(makeUploader(api: api), featureFlags: nil)

            await standard.handleNewSamples([stepSample(500)], ofType: SampleType.stepCount)

            // stepCount is a cumulative identifier — the stats path is
            // authoritative, so it must NOT reach the per-sample uploader.
            #expect(api.entryCount == 0)
            #expect(!api.entryIdentifiers.contains(HKQuantityTypeIdentifier.stepCount.rawValue))
        }

        @Test("featureFlags == nil ⇒ a NON-cumulative type still flows (only cumulative is gated)")
        func nilFlagsKeepsNonCumulative() async {
            let api = CapturingAPI()
            let standard = HealthLogStandard()
            await standard.attachUploader(makeUploader(api: api), featureFlags: nil)

            await standard.handleNewSamples([heartRateSample(72)], ofType: SampleType.heartRate)

            // heartRate is not a cumulative identifier — fail-closed must not
            // over-drop spot metrics.
            #expect(api.entryCount == 1)
            #expect(api.entryIdentifiers == [HKQuantityTypeIdentifier.heartRate.rawValue])
        }
    }
#endif
