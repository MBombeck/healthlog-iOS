#if canImport(HealthKit) && canImport(SpeziDevices)
    import Foundation
    import HealthKit
    @testable import HealthLog
    import Testing

    /// DTO-translation + dual-write contract for `DeviceReadingForwarder`.
    ///
    /// These tests exercise the actor end-to-end against in-process stubs:
    ///   * `SpyHKWriter` captures the `[HKQuantitySample]` the forwarder
    ///     hands to the HealthKit save path — asserts both the metadata
    ///     stamp (`HKMetadataKeyExternalUUID`) and the sample types match
    ///     what the cuff produced upstream.
    ///   * `SpyBatchAPI` (an `APIClientProtocol` conformance) captures the
    ///     `HealthKitBatchEntryDTO` array on the wire — asserts the
    ///     external-id namespace + unit symbols line up with the
    ///     `HealthKitWireConverter.preferredUnit` contract for systolic /
    ///     diastolic / heart-rate.
    ///
    /// The forwarder grouping logic (`HKCorrelation` + standalone
    /// `HKQuantitySample` with matching timestamp) is exercised through
    /// the public `forward(samples:)` entry so the test pins the
    /// real-call-site path the Settings → Geräte screen uses.
    @Suite("DeviceReadingForwarder — Omron BPM dual-write contract")
    struct DeviceReadingForwarderTests {
        /// Stable stem so external-id assertions stay deterministic.
        static let stem = "BP-ID-0001"

        /// Build the canonical Omron-shaped sample bundle:
        /// `HKCorrelation` wrapping (systolic, diastolic) plus a standalone
        /// `HKQuantitySample` for heart-rate, all sharing a single
        /// timestamp. Mirrors what `BloodPressureMeasurement.bloodPressure-
        /// Sample(source:) + heartRateSample(source:)` produces upstream.
        static func makeOmronReading(
            systolic: Double = 117,
            diastolic: Double = 76,
            pulse: Double = 68,
            // Default to "now" so the v0.6.0.7 P4 freshness-window gate
            // ([-30 days, +24h] around the forwarder clock) doesn't
            // reject a pre-existing test whose helper happens to mint
            // a stamp that's > 30 days old at runtime. Tests that need
            // a pinned timestamp pass an explicit `timestamp:` value
            // AND inject a matching `clock:` into the forwarder.
            timestamp: Date = Date()
        ) -> [HKSample] {
            let mmHg = HKUnit.millimeterOfMercury()
            let bpm = HKUnit.count().unitDivided(by: .minute())

            let sysSample = HKQuantitySample(
                type: HKQuantityType(.bloodPressureSystolic),
                quantity: HKQuantity(unit: mmHg, doubleValue: systolic),
                start: timestamp,
                end: timestamp
            )
            let diaSample = HKQuantitySample(
                type: HKQuantityType(.bloodPressureDiastolic),
                quantity: HKQuantity(unit: mmHg, doubleValue: diastolic),
                start: timestamp,
                end: timestamp
            )
            let correlation = HKCorrelation(
                type: HKCorrelationType(.bloodPressure),
                start: timestamp,
                end: timestamp,
                objects: [sysSample, diaSample]
            )
            let pulseSample = HKQuantitySample(
                type: HKQuantityType(.heartRate),
                quantity: HKQuantity(unit: bpm, doubleValue: pulse),
                start: timestamp,
                end: timestamp
            )
            return [correlation, pulseSample]
        }

        // MARK: - DTO translation

        @Test("BP reading produces three DTO entries (sys, dia, hr) with shared id stem")
        func threeEntriesFromOneReading() async {
            let api = SpyBatchAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                externalIDFactory: { Self.stem }
            )

            let uploaded = await forwarder.forward(samples: Self.makeOmronReading())
            #expect(uploaded == 3)

            let entries = api.allEntries
            #expect(entries.count == 3)
            // Stable external-id namespace: `omron-bpm:<stem>:<sys|dia|hr>`
            #expect(entries.map(\.externalId).sorted() == [
                "omron-bpm:\(Self.stem):dia",
                "omron-bpm:\(Self.stem):hr",
                "omron-bpm:\(Self.stem):sys"
            ])
            // Unit symbols match `HealthKitWireConverter.preferredUnit`
            // (mmHg for BP, bpm for HR) so the server-side schema check
            // (max 60 chars, matched against the known enum) succeeds
            // identically to a manual-entry write.
            let bySuffix = Dictionary(uniqueKeysWithValues: entries.map { ($0.externalId, $0) })
            #expect(bySuffix["omron-bpm:\(Self.stem):sys"]?.unit == "mmHg")
            #expect(bySuffix["omron-bpm:\(Self.stem):sys"]?.value == 117)
            #expect(bySuffix["omron-bpm:\(Self.stem):dia"]?.unit == "mmHg")
            #expect(bySuffix["omron-bpm:\(Self.stem):dia"]?.value == 76)
            #expect(bySuffix["omron-bpm:\(Self.stem):hr"]?.unit == "bpm")
            #expect(bySuffix["omron-bpm:\(Self.stem):hr"]?.value == 68)
        }

        // MARK: - HK dual-write metadata

        @Test("HK save receives 3 samples each stamped with HKMetadataKeyExternalUUID matching wire id")
        func dualWriteStampsExternalUUID() async {
            let api = SpyBatchAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                externalIDFactory: { Self.stem }
            )

            _ = await forwarder.forward(samples: Self.makeOmronReading())

            let saved = writer.savedSamples
            #expect(saved.count == 3)
            // Each re-stamped sample carries the metadata key. The metadata
            // value matches the wire external-id so a same-app HK read-back
            // can drop the sample via the standard anti-dup filter.
            let externalIDs: [String] = saved.compactMap { sample in
                sample.metadata?[HKMetadataKeyExternalUUID] as? String
            }
            #expect(externalIDs.sorted() == [
                "omron-bpm:\(Self.stem):dia",
                "omron-bpm:\(Self.stem):hr",
                "omron-bpm:\(Self.stem):sys"
            ])
        }

        // MARK: - Empty input is a no-op

        @Test("Empty samples → forwarder does no work")
        func emptyInputShortCircuits() async {
            let api = SpyBatchAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                externalIDFactory: { Self.stem }
            )

            let uploaded = await forwarder.forward(samples: [])
            #expect(uploaded == 0)
            #expect(api.callCount == 0)
            #expect(writer.savedSamples.isEmpty)
        }

        // MARK: - Physiological-range validation (v0.6.0.6)

        @Test("Reading with sys=0/dia=999 is rejected — no HK save, no DTO")
        func outOfRangeBpRejected() async {
            let api = SpyBatchAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                externalIDFactory: { Self.stem }
            )

            // sys=0 fails the 40 ... 300 gate; dia=999 fails the 20 ... 200
            // gate. Per-quantity validation rejects both, so the prepared
            // bundle is empty and neither HK nor the wire see the reading.
            let bogus = Self.makeOmronReading(systolic: 0, diastolic: 999, pulse: 70)
            let uploaded = await forwarder.forward(samples: bogus)

            #expect(uploaded == 0)
            #expect(api.allEntries.isEmpty)
            #expect(writer.savedSamples.isEmpty)
        }

        @Test("Reading with sys < dia is rejected at group level")
        func swappedBpPairRejected() async {
            let api = SpyBatchAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                externalIDFactory: { Self.stem }
            )

            // sys=70 < dia=110 — both inside the per-quantity bounds but
            // the cross-quantity guard (sys must exceed dia by >=5) drops
            // the entire group so HK + server never see the swapped pair.
            let swapped = Self.makeOmronReading(systolic: 70, diastolic: 110, pulse: 75)
            let uploaded = await forwarder.forward(samples: swapped)

            #expect(uploaded == 0)
            #expect(api.allEntries.isEmpty)
            #expect(writer.savedSamples.isEmpty)
        }

        @Test("Reading with out-of-range pulse drops pulse but keeps valid BP pair")
        func outOfRangePulseDroppedBpKept() async {
            let api = SpyBatchAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                externalIDFactory: { Self.stem }
            )

            // sys/dia valid, pulse=400 fails the 20 ... 250 gate. The pulse
            // entry is dropped; the BP pair survives because the cross-
            // quantity rule only requires sys > dia + 5 (both still inside
            // bounds).
            let mixed = Self.makeOmronReading(systolic: 117, diastolic: 76, pulse: 400)
            let uploaded = await forwarder.forward(samples: mixed)

            #expect(uploaded == 2)
            #expect(api.allEntries.count == 2)
            let identifiers = Set(api.allEntries.map(\.hkIdentifier))
            #expect(identifiers.contains(HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue))
            #expect(identifiers.contains(HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue))
            #expect(!identifiers.contains(HKQuantityTypeIdentifier.heartRate.rawValue))
        }

        @Test("isPhysiologicallyValid rejects NaN + infinity")
        func nonFiniteValuesRejected() {
            let sysIdent = HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue
            let diaIdent = HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue
            let hrIdent = HKQuantityTypeIdentifier.heartRate.rawValue

            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: .nan, identifier: sysIdent) == false)
            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: .infinity, identifier: sysIdent) == false)
            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: -.infinity, identifier: diaIdent) == false)
            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: .nan, identifier: hrIdent) == false)
            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: -1.0, identifier: hrIdent) == false)
        }

        @Test("isPhysiologicallyValid accepts in-range values")
        func inRangeValuesAccepted() {
            let sysIdent = HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue
            let diaIdent = HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue
            let hrIdent = HKQuantityTypeIdentifier.heartRate.rawValue

            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: 117, identifier: sysIdent))
            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: 40, identifier: sysIdent)) // lower bound
            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: 300, identifier: sysIdent)) // upper bound
            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: 76, identifier: diaIdent))
            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: 68, identifier: hrIdent))
            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: 20, identifier: hrIdent)) // lower bound
            #expect(DeviceReadingForwarder.isPhysiologicallyValid(value: 250, identifier: hrIdent)) // upper bound
        }

        // MARK: - Outbox-replay enqueue on offline upload failure (v0.6.0.6)

        @Test("Upload throw enqueues prepared DTOs to the outbox stub")
        func uploadFailureEnqueuesOutbox() async {
            let api = ThrowingSpyAPI()
            let writer = SpyHKWriter()
            let outbox = SpyOutbox()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                outbox: outbox,
                externalIDFactory: { Self.stem }
            )

            _ = await forwarder.forward(samples: Self.makeOmronReading())

            // Uploader threw on every batch — the prepared DTOs must land
            // on the outbox so OutboxReplayService re-tries them at the
            // next reachability + foreground wave.
            #expect(outbox.callCount == 1)
            #expect(outbox.allEntries.count == 3)
            #expect(Set(outbox.allEntries.map(\.externalId)) == Set([
                "omron-bpm:\(Self.stem):dia",
                "omron-bpm:\(Self.stem):hr",
                "omron-bpm:\(Self.stem):sys"
            ]))
            // HK save still happened — operator still sees the reading
            // in Apple Health even though the server leg deferred.
            #expect(writer.savedSamples.count == 3)
        }

        @Test("No outbox attached: upload throw is logged but enqueue is skipped")
        func uploadFailureNoOutboxIsLoggedOnly() async {
            let api = ThrowingSpyAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            // outbox: nil — back-compat path for callers that haven't
            // wired the outbox seam (tests, legacy resolves).
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                outbox: nil,
                externalIDFactory: { Self.stem }
            )

            let uploaded = await forwarder.forward(samples: Self.makeOmronReading())
            #expect(uploaded == 0)
            // HK save still happened; no outbox to enqueue into.
            #expect(writer.savedSamples.count == 3)
        }

        // MARK: - Unknown sample types are dropped

        @Test("Sample with unmapped HK type is dropped from DTO + HK save (defensive)")
        func unmappedSampleDropped() async {
            let api = SpyBatchAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                externalIDFactory: { Self.stem }
            )

            // Construct a stray sample type the forwarder does NOT map
            // (BodyMass) — exercises the defensive `wireMapping(for:)` nil
            // branch so future device-family additions don't blow up the
            // pipeline on a partial mapping table.
            let stray = HKQuantitySample(
                type: HKQuantityType(.bodyMass),
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 80),
                start: Date(),
                end: Date()
            )
            _ = await forwarder.forward(samples: [stray])

            #expect(api.allEntries.isEmpty)
            #expect(writer.savedSamples.isEmpty)
        }

        // MARK: - Defensive bounds beyond H1 (v0.6.0.7 P4)

        @Test("Batch larger than maxSamplesPerForward is rejected wholesale")
        func oversizedBatchRejected() async {
            let api = SpyBatchAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                externalIDFactory: { Self.stem }
            )

            // Synthesize an oversized batch — `maxSamplesPerForward + 1`
            // dummy HR samples. A real cuff press is 2–3 samples; an
            // attacker-controlled GATT writer flooding the pipeline must
            // get a single rejection, not partial admission.
            let bpm = HKUnit.count().unitDivided(by: .minute())
            let count = DeviceReadingForwarder.maxSamplesPerForward + 1
            let oversized: [HKSample] = (0 ..< count).map { _ in
                HKQuantitySample(
                    type: HKQuantityType(.heartRate),
                    quantity: HKQuantity(unit: bpm, doubleValue: 72),
                    start: Date(),
                    end: Date()
                )
            }

            let uploaded = await forwarder.forward(samples: oversized)
            #expect(uploaded == 0)
            #expect(api.allEntries.isEmpty)
            #expect(writer.savedSamples.isEmpty)
        }

        @Test("Reading timestamped 5 years in the future is rejected by freshness window")
        func futureTimestampRejected() async {
            let api = SpyBatchAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            // Pin the forwarder clock so the test is deterministic.
            let pinnedNow = Date(timeIntervalSince1970: 1_715_673_600)
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                externalIDFactory: { Self.stem },
                clock: { pinnedNow }
            )

            // 5 years past pinnedNow — way outside the +24h window. A
            // cuff with a wrong RTC writing year-9999 readings is
            // exactly what this gate exists for.
            let fiveYears = pinnedNow.addingTimeInterval(5 * 365 * 24 * 60 * 60)
            let skewed = Self.makeOmronReading(timestamp: fiveYears)

            let uploaded = await forwarder.forward(samples: skewed)
            #expect(uploaded == 0)
            #expect(api.allEntries.isEmpty)
            #expect(writer.savedSamples.isEmpty)
        }

        @Test("Reading timestamped 60 days in the past is rejected by freshness window")
        func ancientTimestampRejected() async {
            let api = SpyBatchAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            let pinnedNow = Date(timeIntervalSince1970: 1_715_673_600)
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                externalIDFactory: { Self.stem },
                clock: { pinnedNow }
            )

            // 60 days back — outside the 30-day past window. A cuff
            // that's been offline for two months is more likely to
            // have a corrupted RTC than a legitimate two-month
            // buffered reading.
            let twoMonthsAgo = pinnedNow.addingTimeInterval(-60 * 24 * 60 * 60)
            let stale = Self.makeOmronReading(timestamp: twoMonthsAgo)

            let uploaded = await forwarder.forward(samples: stale)
            #expect(uploaded == 0)
            #expect(api.allEntries.isEmpty)
            #expect(writer.savedSamples.isEmpty)
        }

        @Test("Reading 5 days old is accepted (inside freshness window)")
        func recentBufferedReadingAccepted() async {
            let api = SpyBatchAPI()
            let writer = SpyHKWriter()
            let uploader = MeasurementBatchUploader(
                api: api,
                throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
            )
            let pinnedNow = Date(timeIntervalSince1970: 1_715_673_600)
            let forwarder = DeviceReadingForwarder(
                uploader: uploader,
                saver: writer,
                externalIDFactory: { Self.stem },
                clock: { pinnedNow }
            )

            // 5 days ago — well inside the 30-day past window. A cuff
            // that buffered readings while the operator was on a
            // short trip is a legitimate flow that must survive the
            // gate.
            let fiveDaysAgo = pinnedNow.addingTimeInterval(-5 * 24 * 60 * 60)
            let buffered = Self.makeOmronReading(timestamp: fiveDaysAgo)

            let uploaded = await forwarder.forward(samples: buffered)
            #expect(uploaded == 3)
            #expect(api.allEntries.count == 3)
            #expect(writer.savedSamples.count == 3)
        }

        @Test("isWithinFreshnessWindow accepts now + small clock skew")
        func freshnessWindowBoundaries() {
            let now = Date(timeIntervalSince1970: 1_715_673_600)
            // Exactly now: accepted.
            #expect(DeviceReadingForwarder.isWithinFreshnessWindow(timestamp: now, now: now))
            // 1 hour in the future (typical Bluetooth clock skew): accepted.
            #expect(DeviceReadingForwarder.isWithinFreshnessWindow(
                timestamp: now.addingTimeInterval(60 * 60), now: now
            ))
            // 25 hours in the future: rejected (>24h tolerance).
            #expect(!DeviceReadingForwarder.isWithinFreshnessWindow(
                timestamp: now.addingTimeInterval(25 * 60 * 60), now: now
            ))
            // 25 days in the past: accepted (inside 30-day window).
            #expect(DeviceReadingForwarder.isWithinFreshnessWindow(
                timestamp: now.addingTimeInterval(-25 * 24 * 60 * 60), now: now
            ))
            // 35 days in the past: rejected.
            #expect(!DeviceReadingForwarder.isWithinFreshnessWindow(
                timestamp: now.addingTimeInterval(-35 * 24 * 60 * 60), now: now
            ))
        }
    }

    // MARK: - Test doubles

    /// Spy `DeviceReadingHealthKitWriting` that records every `save(...)`
    /// invocation. `@unchecked Sendable` because the spy needs concurrent
    /// access (forwarder calls land on the actor; assertions run on the
    /// test runner) — guarded by `NSLock`.
    final class SpyHKWriter: DeviceReadingHealthKitWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var _saved: [HKQuantitySample] = []

        var savedSamples: [HKQuantitySample] {
            lock.withLock { _saved }
        }

        func save(_ samples: [HKQuantitySample]) async throws {
            lock.withLock { _saved.append(contentsOf: samples) }
        }
    }

    /// Stub APIClient that pretends every entry was `inserted` and records
    /// the full DTO list across all calls. Mirrors the stub pattern used
    /// in `MeasurementBatchUploaderTests` so the contract assertions stay
    /// readable without bringing in URLSession.
    ///
    /// `@unchecked Sendable` (vs. an `actor` double) because the spy's
    /// mutable state (`_calls`, `_entries`) is guarded by an `NSLock` —
    /// the established pattern for `MeasurementBatchUploaderTests`
    /// + the other forwarder doubles. Switching to `actor` would force
    /// every assertion read in the suite to `await`, with no race-safety
    /// benefit over the current lock-guarded invariant. PROJECT_GUIDE.md anti-
    /// pattern call-out applies to production code; test doubles with
    /// documented locking are the canonical exception.
    final class SpyBatchAPI: APIClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _entries: [HealthKitBatchEntryDTO] = []

        var callCount: Int {
            lock.withLock { _calls }
        }

        var allEntries: [HealthKitBatchEntryDTO] {
            lock.withLock { _entries }
        }

        func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
            guard let body = request.body else {
                throw HLError.unknown("test stub: no body")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(HealthKitBatchPayload.self, from: body)
            lock.withLock {
                _calls += 1
                _entries.append(contentsOf: payload.entries)
            }
            let entries = payload.entries.indices.map { idx in
                HealthKitBatchResponseDTO.EntryResult(index: idx, status: .inserted)
            }
            let response = HealthKitBatchResponseDTO(
                processed: payload.entries.count,
                inserted: payload.entries.count,
                duplicates: 0,
                skipped: [],
                entries: entries
            )
            guard let typed = response as? T else {
                throw HLError.unknown("test stub: T mismatch")
            }
            return typed
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {
            lock.withLock { _calls += 1 }
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.unknown("test stub: download not implemented")
        }
    }

    /// API stub that always throws a retriable network error — exercises
    /// the forwarder's offline-failure catch arm so the outbox-enqueue
    /// hop can be observed without spinning up URLSession.
    ///
    /// `@unchecked Sendable` is trivially safe here: the class holds no
    /// mutable state, every method just throws. Marked `@unchecked` (vs.
    /// plain `Sendable`) because `APIClientProtocol` is not `Sendable`-
    /// constrained upstream, so the conformance must be opt-in. No lock
    /// needed.
    final class ThrowingSpyAPI: APIClientProtocol, @unchecked Sendable {
        func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
            throw HLError.network(.connectionLost)
        }

        func sendVoid(_: APIRequest<EmptyPayload>) async throws {
            throw HLError.network(.connectionLost)
        }

        func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
            throw HLError.network(.connectionLost)
        }
    }

    /// Spy `DeviceReadingOutboxEnqueuing` that captures every enqueued
    /// batch. Pinned by `NSLock` for the same reason as the other test
    /// doubles — concurrent access between the forwarder actor + the
    /// test assertion path.
    final class SpyOutbox: DeviceReadingOutboxEnqueuing, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _entries: [HealthKitBatchEntryDTO] = []

        var callCount: Int {
            lock.withLock { _calls }
        }

        var allEntries: [HealthKitBatchEntryDTO] {
            lock.withLock { _entries }
        }

        func enqueueBatch(
            _ entries: [HealthKitBatchEntryDTO],
            encoder _: JSONEncoder
        ) async throws {
            lock.withLock {
                _calls += 1
                _entries.append(contentsOf: entries)
            }
        }
    }
#endif
