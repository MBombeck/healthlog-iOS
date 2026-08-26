import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// The HealthKit half of the ECG upload path (GH #74, server v1.35.3).
    ///
    /// Reads `HKElectrocardiogram` samples through an `HKAnchoredObjectQuery`
    /// (metadata) and each strip's trace through an `HKElectrocardiogramQuery`
    /// (voltages) — the latter one recording at a time, on demand, never for the
    /// whole batch at once.
    ///
    /// **No observer query.** Unlike the workout / event importers this type
    /// does not register an `HKObserverQuery`. An ECG is recorded a handful of
    /// times a year by a deliberate 30-second act; waking the app for it buys
    /// nothing and costs a permanent background subscription on the most
    /// sensitive type in the store. The sweep rides the existing wake paths
    /// instead (foreground refresh + the BGProcessingTask anchor sweep).
    ///
    /// **The trace never lands anywhere but the request.** `voltages(forRecordingID:)`
    /// materialises one `[Double]`, hands it to the caller, and keeps nothing;
    /// the actor's own cache holds `HKElectrocardiogram` *metadata* objects only
    /// (HealthKit does not load the waveform until the voltage query runs), so
    /// no decrypted trace outlives the upload that needed it. Nothing here is
    /// ever logged beyond counts.
    actor EcgHealthKitSource: EcgRecordingSource {
        private let store: HKHealthStore
        /// The recordings handed out by the last `fetchRecordings` call, keyed
        /// by UUID string, so the follow-up voltage query can find its sample
        /// object. Metadata only — replaced wholesale on every fetch.
        private var pending: [String: HKElectrocardiogram] = [:]

        init(store: HKHealthStore) {
            self.store = store
        }

        // MARK: - Metadata

        func fetchRecordings(since anchor: Data?) async throws -> EcgSourceFetchResult {
            let decoded = HealthKitAnchorArchive.decodeAnchor(anchor, label: "ecg")
            let (samples, newAnchor) = try await fetchSamples(anchor: decoded)
            var cache: [String: HKElectrocardiogram] = [:]
            var mapped: [EcgSourceRecording] = []
            mapped.reserveCapacity(samples.count)
            for sample in samples {
                // Anti-duplicate (PROJECT_GUIDE.md): the app never writes ECGs back, so
                // an own-echo is impossible today; the filter stays for
                // uniformity with the sibling importers and to stay correct if a
                // write path ever lands.
                if HealthKitSampleOwnership.isOwnEcho(sample) { continue }
                let key = sample.uuid.uuidString
                cache[key] = sample
                mapped.append(Self.metadata(from: sample))
            }
            pending = cache
            return EcgSourceFetchResult(
                recordings: mapped,
                anchor: HealthKitAnchorArchive.encodeAnchor(newAnchor, label: "ecg")
            )
        }

        /// Map one sample to the platform-free metadata shape.
        ///
        /// `nonisolated static` + pure so the mapping — in particular the
        /// verdict translation — is testable without a HealthKit store.
        nonisolated static func metadata(from sample: HKElectrocardiogram) -> EcgSourceRecording {
            EcgSourceRecording(
                id: sample.uuid.uuidString,
                recordedAt: sample.startDate,
                samplingFrequency: sample.samplingFrequency?
                    .doubleValue(for: HKUnit.hertz()) ?? 0,
                averageHeartRate: sample.averageHeartRate?
                    .doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                classification: classification(from: sample.classification),
                lead: appleWatchLead,
                sampleCount: sample.numberOfVoltageMeasurements
            )
        }

        /// The lead an Apple Watch strip is taken on. HealthKit models it as
        /// `HKElectrocardiogram.Lead.appleWatchSimilarToLeadI` — "similar to
        /// Lead I" — and the server's contract example uses `"I"`, which is the
        /// value the archive importer already writes for the same recordings.
        static let appleWatchLead = "I"

        /// Translate the DEVICE's verdict into the three values the ECG route
        /// accepts. **A translation, never an assessment** — HealthLog does not
        /// look at the trace and does not form an opinion; every arm below is a
        /// restatement of what the watch's own certified algorithm already
        /// decided, in the vocabulary the server publishes.
        ///
        /// - `sinusRhythm` → `NOT_DETECTED`: Apple's own semantics for that case
        ///   are "no signs of atrial fibrillation were found", which is exactly
        ///   what the server's `NOT_DETECTED` names. It is **not** "normal".
        /// - `atrialFibrillation` → `IRREGULAR`.
        /// - every `inconclusive*` arm → `INCONCLUSIVE`. The device declined to
        ///   judge; the reason it declined (heart rate too low/high, poor
        ///   reading) is not expressible on this route and is not invented here.
        /// - `notSet` / `unrecognized` / anything a future OS adds → `nil`. A
        ///   verdict we cannot name is sent as no verdict at all; guessing one
        ///   would be HealthLog making a cardiac claim the device did not.
        nonisolated static func classification(
            from value: HKElectrocardiogram.Classification
        ) -> EcgIngestClassification? {
            switch value {
            case .sinusRhythm:
                .notDetected
            case .atrialFibrillation:
                .irregular
            case .inconclusiveLowHeartRate,
                 .inconclusiveHighHeartRate,
                 .inconclusivePoorReading,
                 .inconclusiveOther:
                .inconclusive
            case .notSet, .unrecognized:
                nil
            @unknown default:
                nil
            }
        }

        /// Bridge the anchored query into async/await. One resume per query —
        /// a non-live `HKAnchoredObjectQuery` invokes its handler exactly once.
        private func fetchSamples(
            anchor: HKQueryAnchor?
        ) async throws -> (samples: [HKElectrocardiogram], newAnchor: HKQueryAnchor?) {
            let type = HKObjectType.electrocardiogramType()
            return try await withCheckedThrowingContinuation { continuation in
                let query = HKAnchoredObjectQuery(
                    type: type,
                    predicate: nil,
                    anchor: anchor,
                    limit: HKObjectQueryNoLimit
                ) { _, samples, _, newAnchor, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let recordings = (samples as? [HKElectrocardiogram]) ?? []
                    continuation.resume(returning: (recordings, newAnchor))
                }
                store.execute(query)
            }
        }

        // MARK: - Waveform

        /// The trace for one recording, in volts, index-ordered.
        ///
        /// Driven through an `AsyncThrowingStream` rather than a lock-guarded
        /// accumulator: `HKElectrocardiogramQuery` calls its handler once per
        /// voltage measurement, and the stream's continuation is the one
        /// `Sendable` sink that can absorb that under strict concurrency
        /// without an `@unchecked Sendable` box.
        func voltages(forRecordingID id: String) async throws -> [Double] {
            guard let sample = pending[id] else {
                throw EcgSourceError.recordingNotAvailable
            }
            let (stream, continuation) = AsyncThrowingStream<Double, any Error>.makeStream()
            let query = HKElectrocardiogramQuery(sample) { _, result in
                switch result {
                case let .measurement(measurement):
                    guard let quantity = measurement.quantity(for: .appleWatchSimilarToLeadI) else {
                        // A measurement without the lead we asked for is a hole
                        // in the trace. There is no honest way to fill it, so
                        // the whole recording fails and the caller skips it.
                        continuation.finish(throwing: EcgSourceError.missingLeadValue)
                        return
                    }
                    continuation.yield(quantity.doubleValue(for: HKUnit.volt()))
                case .done:
                    continuation.finish()
                case let .error(error):
                    continuation.finish(throwing: error)
                @unknown default:
                    continuation.finish(throwing: EcgSourceError.unsupportedResult)
                }
            }
            store.execute(query)
            var volts: [Double] = []
            volts.reserveCapacity(sample.numberOfVoltageMeasurements)
            for try await value in stream {
                volts.append(value)
            }
            return volts
        }
    }

    /// Failures the HealthKit ECG source raises itself (as opposed to the ones
    /// HealthKit raises). All are terminal for the recording they concern and
    /// none carries data.
    enum EcgSourceError: Error, Equatable {
        /// Asked for a trace of a recording the last fetch did not hand out.
        case recordingNotAvailable
        /// A voltage measurement carried no value for the lead we read.
        case missingLeadValue
        /// A future OS added a query-result case we do not understand.
        case unsupportedResult
    }

#endif
