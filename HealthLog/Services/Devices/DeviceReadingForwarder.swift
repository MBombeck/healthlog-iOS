#if canImport(HealthKit) && canImport(SpeziDevices)
    import Foundation
    import HealthKit
    import SpeziDevices

    /// Drains paired-BLE readings (Omron BPM today, scale + glucose tomorrow)
    /// into the same `MeasurementBatchUploader` + HK-write pipeline the rest
    /// of the app already uses for manual-entry and HK-observer paths.
    ///
    /// **Dual-write rationale (v0.6.0.5 F.2 Q4 decision):**
    /// the reading flows BOTH to the HealthLog server (via
    /// `MeasurementBatchUploader.upload(_:)`) AND back into Apple Health (via
    /// `HKHealthStore.save([...])`). The HK write stamps
    /// `HKMetadataKeyExternalUUID` per measurement, so the upstream Spezi
    /// observer pipeline (`HealthLogStandard.handleNewSamples`) recognises
    /// the round-trip and drops it (anti-dup filter at
    /// `HealthLogStandard.swift:107-113`) — preventing the upload from
    /// firing a second time when the new HK sample is delivered to our own
    /// `CollectSamples` collectors.
    ///
    /// Without the HK write, the reading would only ever exist on the
    /// HealthLog server — the rest of the iOS HealthKit ecosystem (Apple
    /// Watch summaries, third-party fitness apps, the Health app's BP
    /// graph) would have a hole exactly where the cuff measured. With the
    /// HK write, the operator's Apple-Health graph contains the same
    /// reading their HealthLog dashboard does, and the server stays the
    /// source of truth because every external-id is server-deduplicated.
    ///
    /// **Why a separate type instead of folding this into
    /// `HealthLogDeviceManager`?**
    /// Translation is a pure data-transformation step that should stay
    /// unit-testable without spinning up Spezi or the SwiftUI view tree.
    /// `HealthLogDeviceManager` is the SwiftUI-facing `@Observable` facade;
    /// this forwarder is the actor that owns the wire translation and
    /// network/HK-write side-effects. The screen mounts both: the manager
    /// for the paired-list projection, the forwarder for the
    /// `MeasurementsRecordedSheet` save callback.
    ///
    /// **Concurrency:**
    /// `actor` because each call lands in two side-effects (HK save +
    /// network POST). Both inputs are `Sendable` (`[HKSample]` is, the
    /// uploader is an actor, the writer is `Sendable`-conforming). The
    /// type takes no inout state — it could be a free function in theory,
    /// but the actor shape gives us a clean injection seam for tests and
    /// matches the rest of the `Services/` actor pattern.
    public actor DeviceReadingForwarder {
        public enum SourceKind: String, Sendable {
            /// Omron blood-pressure cuff. v0.6.0.5 ships this kind; future
            /// kinds (scale, glucose, pulse-ox) plug into the same enum so
            /// the external-id namespace stays disjoint per device family.
            case omronBPM = "omron-bpm"
        }

        private let uploader: MeasurementBatchUploader
        private let saver: any DeviceReadingHealthKitWriting
        private let outbox: DeviceReadingOutboxEnqueuing?
        private let outboxEncoder: JSONEncoder
        private let externalIDFactory: @Sendable () -> String
        private let clock: @Sendable () -> Date

        public init(
            uploader: MeasurementBatchUploader,
            saver: any DeviceReadingHealthKitWriting,
            outbox: DeviceReadingOutboxEnqueuing? = nil,
            outboxEncoder: JSONEncoder = .hlBatch,
            externalIDFactory: @escaping @Sendable () -> String = { UUID().uuidString },
            clock: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.uploader = uploader
            self.saver = saver
            self.outbox = outbox
            self.outboxEncoder = outboxEncoder
            self.externalIDFactory = externalIDFactory
            self.clock = clock
        }

        /// Translate + dual-write a batch of HK samples from a paired
        /// device's `MeasurementsRecordedSheet` confirm step.
        ///
        /// Steps per reading:
        ///   1. Flatten any `HKCorrelation` (blood-pressure ships as
        ///      `bloodPressureSample` → `HKCorrelation` containing systolic
        ///      + diastolic) plus any standalone `HKQuantitySample` (e.g.
        ///      the optional heart-rate sample Spezi attaches).
        ///   2. Generate ONE external-id-stem per reading-group (the
        ///      systolic + diastolic + heart-rate from the same cuff press
        ///      share the same stem so the server-side correlation logic
        ///      can re-couple them) — derived ids look like
        ///      `omron-bpm:<uuid>:sys`, `:dia`, `:hr`.
        ///   3. Re-create each `HKQuantitySample` with
        ///      `HKMetadataKeyExternalUUID = <derived id>` so the upstream
        ///      Spezi observer round-trips through the same dup-filter the
        ///      manual-entry path uses.
        ///   4. Save the re-created samples to HK (single batched
        ///      `store.save([...])`).
        ///   5. Build matching `HealthKitBatchEntryDTO` rows with the same
        ///      external-id + unit mapping as
        ///      `HealthKitWireConverter.preferredUnit(for:)` so the server
        ///      receives identical wire bytes to a manual-entry write.
        ///   6. POST via `MeasurementBatchUploader.upload(_:)` — re-uses
        ///      the backoff + idempotency-key + chunking contract.
        ///
        /// - Returns: number of DTO entries successfully POST-ed (sum
        ///   across all chunks reported `consumed`). 0 if the HK save threw
        ///   or the upload threw — the caller logs but doesn't unwind the
        ///   sheet (the operator already saw "saved" UI; the next BLE wake
        ///   re-tries via `HealthMeasurements.pendingMeasurements`).
        @discardableResult
        public func forward(
            samples: [HKSample],
            source: SourceKind = .omronBPM
        ) async -> Int {
            // Defensive batch-size cap (v0.6.0.7 P4 — extra check
            // beyond H1). A real Omron press emits 2–3 samples
            // (sys + dia + optional HR). A malformed or attacker-
            // controlled GATT writer could in theory shovel an
            // unbounded array into `MeasurementsRecordedSheet` →
            // here → through `HKHealthStore.save([...])`. Refuse the
            // whole input batch above `Self.maxSamplesPerForward`
            // (256) — 80x the realistic worst case but small enough
            // that an over-the-wire DoS becomes a no-op log line.
            guard samples.count <= Self.maxSamplesPerForward else {
                HLLog.healthKit
                    .warning(
                        "DeviceReadingForwarder dropped oversized batch: \(samples.count, privacy: .public) > \(Self.maxSamplesPerForward, privacy: .public)"
                    )
                return 0
            }

            let groups = readingGroups(from: samples)
            guard !groups.isEmpty else { return 0 }

            let now = clock()
            var totalUploaded = 0
            for group in groups {
                // Defensive timestamp window. A cuff with a wrong RTC
                // (battery pulled, never set after manufacture, or
                // attacker-poisoned) can emit a startDate in the year
                // 9999 or 1970. Reject readings outside the window so
                // a single skewed press doesn't poison the BP graph
                // or the Apple-Health ecosystem.
                guard Self.isWithinFreshnessWindow(timestamp: group.timestamp, now: now) else {
                    HLLog.healthKit
                        .warning("DeviceReadingForwarder dropped reading group: timestamp outside freshness window")
                    continue
                }
                let stem = externalIDFactory()
                let prepared = group.prepare(stem: stem, source: source)
                guard !prepared.samples.isEmpty else { continue }

                do {
                    try await saver.save(prepared.samples)
                } catch {
                    HLLog.healthKit
                        .error("DeviceReadingForwarder HK save failed: \(error.localizedDescription, privacy: .public)")
                    // Continue to upload even if HK save fails — the
                    // server still gets the reading, just without the HK
                    // mirror. Operator can see the reading in HealthLog
                    // even when Apple Health permissions are partial.
                }

                do {
                    let outcomes = try await uploader.upload(prepared.entries)
                    let consumed = outcomes.reduce(0) { $0 + $1.consumedIndexes.count }
                    totalUploaded += consumed
                    HLLog.healthKit
                        .info(
                            "DeviceReadingForwarder uploaded \(consumed, privacy: .public)/\(prepared.entries.count, privacy: .public) entries for \(source.rawValue, privacy: .public)"
                        )
                } catch {
                    HLLog.healthKit
                        .error("DeviceReadingForwarder upload failed: \(error.localizedDescription, privacy: .public)")
                    // Offline / backoff / transient server failure: enqueue
                    // the prepared DTOs onto the Outbox so OutboxReplayService
                    // re-tries them at the next reachability + foreground
                    // wave. Without this hop, a cuff press taken while the
                    // phone is offline (or while `BatchBackoffError.throttled`
                    // is active) would write to HK locally but never reach
                    // the server. PROJECT_GUIDE.md "Critical constraints —
                    // Optimistic Writes + Outbox" applies to the device
                    // forwarder path identically to the manual-entry path.
                    if let outbox {
                        do {
                            try await outbox.enqueueBatch(prepared.entries, encoder: outboxEncoder)
                            HLLog.outbox
                                .info(
                                    "DeviceReadingForwarder enqueued \(prepared.entries.count, privacy: .public) entries to outbox after upload failure"
                                )
                        } catch {
                            HLLog.outbox
                                .error(
                                    "DeviceReadingForwarder outbox enqueue failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                                )
                        }
                    }
                }
            }
            return totalUploaded
        }

        // MARK: - Translation

        /// Group input samples into one logical reading per timestamp.
        /// `HKCorrelation` always counts as one group (systolic+diastolic
        /// share a moment); standalone `HKQuantitySample` whose start
        /// timestamp matches a correlation in the same batch joins that
        /// correlation's group (`heartRateSample` from Omron has the same
        /// timestamp as the BP correlation).
        ///
        /// Internal so the test target can exercise the grouping shape
        /// without going through `forward(samples:)`.
        nonisolated func readingGroups(from samples: [HKSample]) -> [ReadingGroup] {
            var groups: [ReadingGroup] = []
            var loose: [HKQuantitySample] = []

            for sample in samples {
                if let correlation = sample as? HKCorrelation {
                    let quantities = correlation.objects.compactMap { $0 as? HKQuantitySample }
                    groups.append(
                        ReadingGroup(
                            timestamp: correlation.startDate,
                            quantities: quantities,
                            device: correlation.device
                        )
                    )
                } else if let quantity = sample as? HKQuantitySample {
                    loose.append(quantity)
                }
            }

            // Attach loose quantity samples to the nearest matching group
            // (same timestamp). Any leftover (no correlation in the batch)
            // becomes its own single-quantity group — the Omron path always
            // pairs BP with HR, but future device families may send only
            // standalones (e.g. a continuous glucose monitor reading).
            for loose in loose {
                if let idx = groups.firstIndex(where: { abs($0.timestamp.timeIntervalSince(loose.startDate)) < 1.0 }) {
                    groups[idx].quantities.append(loose)
                } else {
                    groups.append(
                        ReadingGroup(
                            timestamp: loose.startDate,
                            quantities: [loose],
                            device: loose.device
                        )
                    )
                }
            }
            return groups
        }

        /// Public so the test target can build expected groups + compare
        /// against `readingGroups(from:)`. Holds the timestamp, the raw
        /// quantity samples, and the source device.
        struct ReadingGroup {
            var timestamp: Date
            var quantities: [HKQuantitySample]
            var device: HKDevice?

            /// Produce the (re-stamped HK samples, wire DTOs) tuple. The
            /// inner translation is pure — same input always yields same
            /// output, no clock, no UUID generation (the `stem` is the
            /// only external dependency).
            ///
            /// **Validation (v0.6.0.6):** physiological-range + finite
            /// checks are applied before re-stamp + DTO build. A
            /// malfunctioning or attacker-controlled cuff that emits
            /// `sys=0/dia=999`, NaN, or `sys < dia` must NOT reach HK or
            /// the server — both stores share the same operator-facing
            /// BP graph, so a single bad reading contaminates the
            /// Apple-Health ecosystem too. Per-quantity bounds reject
            /// non-finite + out-of-range values; the cross-quantity
            /// rule (`sys > dia`) is enforced at the group level after
            /// the per-quantity pass and drops the entire group if it
            /// fails. Rejected groups log a privacy-public warning
            /// (no PII — only kind + count) and return an empty
            /// `Prepared`.
            func prepare(stem: String, source: SourceKind) -> Prepared {
                let sysIdent = HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue
                let diaIdent = HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue

                // First pass: per-quantity validate, build the working
                // set. We can't emit anything yet — the cross-quantity
                // BP rule below may invalidate the whole group.
                struct PerQuantity {
                    let quantity: HKQuantitySample
                    let mapping: WireMapping
                    let value: Double
                }
                var validated: [PerQuantity] = []
                var hadInvalidBpComponent = false
                var groupHadBpComponent = false

                for quantity in quantities {
                    guard let mapping = DeviceReadingForwarder.wireMapping(for: quantity.quantityType) else {
                        continue
                    }
                    let isBpComponent =
                        quantity.quantityType.identifier == sysIdent
                            || quantity.quantityType.identifier == diaIdent
                    if isBpComponent { groupHadBpComponent = true }
                    let value = quantity.quantity.doubleValue(for: mapping.hkUnit)
                    guard DeviceReadingForwarder.isPhysiologicallyValid(
                        value: value,
                        identifier: quantity.quantityType.identifier
                    ) else {
                        HLLog.healthKit
                            .warning(
                                "DeviceReadingForwarder dropped out-of-range reading for \(quantity.quantityType.identifier, privacy: .public)"
                            )
                        if isBpComponent { hadInvalidBpComponent = true }
                        continue
                    }
                    validated.append(PerQuantity(quantity: quantity, mapping: mapping, value: value))
                }

                // Cross-quantity BP guard: any time the group included a
                // BP component (sys and/or dia), the BP reading is the
                // primary signal — if ANY BP component failed validation
                // or the sys/dia pair is malformed, drop the entire
                // group (including a same-press HR sample) because the
                // HR is meaningless without its paired BP context.
                let perTypeValues = Dictionary(
                    uniqueKeysWithValues: validated.map { ($0.quantity.quantityType.identifier, $0.value) }
                )
                if groupHadBpComponent {
                    if hadInvalidBpComponent {
                        HLLog.healthKit
                            .warning("DeviceReadingForwarder dropped reading group: invalid BP component")
                        return Prepared(samples: [], entries: [])
                    }
                    let sys = perTypeValues[sysIdent]
                    let dia = perTypeValues[diaIdent]
                    // Reading must carry BOTH sys + dia (BP pair is
                    // atomic) and sys must exceed dia by >=5 mmHg.
                    guard let sys, let dia, sys > dia + 5 else {
                        HLLog.healthKit
                            .warning("DeviceReadingForwarder dropped reading group: BP pair invariant violated")
                        return Prepared(samples: [], entries: [])
                    }
                }

                // Second pass: re-stamp + DTO build for the survivors.
                var samples: [HKQuantitySample] = []
                var entries: [HealthKitBatchEntryDTO] = []
                for item in validated {
                    let externalID = "\(source.rawValue):\(stem):\(item.mapping.suffix)"
                    let metadata: [String: Any] = [
                        HKMetadataKeyExternalUUID: externalID
                    ]
                    let restamped = HKQuantitySample(
                        type: item.quantity.quantityType,
                        quantity: item.quantity.quantity,
                        start: item.quantity.startDate,
                        end: item.quantity.endDate,
                        device: device,
                        metadata: metadata
                    )
                    samples.append(restamped)
                    entries.append(
                        HealthKitBatchEntryDTO(
                            hkIdentifier: item.quantity.quantityType.identifier,
                            value: item.value * item.mapping.scale,
                            unit: item.mapping.wireSymbol,
                            startDate: item.quantity.startDate,
                            endDate: item.quantity.endDate,
                            externalId: externalID,
                            externalSourceVersion: nil,
                            deviceType: .other
                        )
                    )
                }
                return Prepared(samples: samples, entries: entries)
            }
        }

        struct Prepared {
            let samples: [HKQuantitySample]
            let entries: [HealthKitBatchEntryDTO]
        }

        /// Per-`HKQuantityType` wire mapping for the metric kinds a
        /// paired-BLE device can produce. Mirrors
        /// `HealthKitWireConverter.preferredUnit(for:)` so a forwarder-
        /// minted entry hits the server with identical bytes to a manual-
        /// entry write — the server doesn't need to special-case device
        /// origin, only the `externalId` namespace does.
        ///
        /// Public for test coverage: the test target asserts the
        /// systolic/diastolic/pulse mapping shapes without spinning up
        /// HKHealthStore.
        /// Defensive cap for the input batch handed to
        /// `forward(samples:)`. A real Omron press emits 2-3 samples;
        /// this ceiling is 80x the realistic worst case so legitimate
        /// bulk-resync flows (e.g. a cuff that buffered N readings
        /// while offline) still pass while a flood-the-pipeline DoS
        /// gets a single log-line rejection.
        nonisolated static let maxSamplesPerForward: Int = 256

        /// Defensive freshness window applied per-group. Readings whose
        /// `startDate` falls outside `[now - 30 days, now + 24h]` are
        /// dropped — a cuff with a wrong RTC, a battery-pulled clock,
        /// or an attacker-poisoned timestamp must NOT contaminate the
        /// operator's BP graph. The future-side tolerance accommodates
        /// minor clock-skew (Bluetooth devices commonly drift a few
        /// minutes); the past-side tolerance accommodates a cuff that
        /// genuinely buffered readings while the phone was unpaired
        /// (operator was on holiday, etc.).
        nonisolated static let freshnessPast: TimeInterval = 30 * 24 * 60 * 60
        nonisolated static let freshnessFuture: TimeInterval = 24 * 60 * 60

        nonisolated static func isWithinFreshnessWindow(timestamp: Date, now: Date) -> Bool {
            let delta = timestamp.timeIntervalSince(now)
            // delta < 0  ⇒ past. -freshnessPast … 0 is OK.
            // delta >= 0 ⇒ future. 0 … +freshnessFuture is OK.
            return delta >= -freshnessPast && delta <= freshnessFuture
        }

        /// Physiological range + finite check applied per-quantity before
        /// the forwarder commits a reading to HK or the wire.
        ///
        /// Ranges are deliberately permissive — wider than typical adult
        /// resting values — because the goal is to reject hardware-fault
        /// readings (zero, max-int, NaN, infinity), NOT to second-guess
        /// clinically-plausible outliers (severe hypertension, athlete
        /// resting bradycardia). Out-of-range values land in the log
        /// (no PII — only the HK identifier) and are dropped from both
        /// the HK save + the wire batch.
        ///
        /// - Systolic: 40 ... 300 mmHg
        /// - Diastolic: 20 ... 200 mmHg
        /// - Heart rate / pulse: 20 ... 250 bpm
        /// - All values: must be finite, non-negative
        ///
        /// Cross-quantity rule (`sys > dia + 5`) is checked at the group
        /// level after this per-quantity gate — see `prepare(stem:source:)`.
        nonisolated static func isPhysiologicallyValid(
            value: Double,
            identifier: String
        ) -> Bool {
            guard value.isFinite, value >= 0 else { return false }
            switch identifier {
            case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue:
                return (40 ... 300).contains(value)
            case HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:
                return (20 ... 200).contains(value)
            case HKQuantityTypeIdentifier.heartRate.rawValue:
                return (20 ... 250).contains(value)
            default:
                // Unknown identifier: the wireMapping lookup would have
                // already dropped this quantity. Default-allow keeps
                // future-mapped types from silently failing the gate
                // before they get their own per-type bounds.
                return true
            }
        }

        nonisolated static func wireMapping(for type: HKQuantityType) -> WireMapping? {
            switch type.identifier {
            case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue:
                WireMapping(
                    hkUnit: .millimeterOfMercury(),
                    wireSymbol: "mmHg",
                    scale: 1,
                    suffix: "sys"
                )
            case HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:
                WireMapping(
                    hkUnit: .millimeterOfMercury(),
                    wireSymbol: "mmHg",
                    scale: 1,
                    suffix: "dia"
                )
            case HKQuantityTypeIdentifier.heartRate.rawValue:
                WireMapping(
                    hkUnit: HKUnit.count().unitDivided(by: .minute()),
                    wireSymbol: "bpm",
                    scale: 1,
                    suffix: "hr"
                )
            default:
                nil
            }
        }

        struct WireMapping {
            let hkUnit: HKUnit
            let wireSymbol: String
            let scale: Double
            /// Per-metric external-id suffix so the server can re-couple
            /// the three rows from one cuff press. Stable across releases.
            let suffix: String
        }
    }

    /// Test-injection seam over `HKHealthStore.save([...])`. The production
    /// implementation is an `HKHealthStore`-backed actor; the test target
    /// substitutes a spy that records the saved sample array without
    /// touching the simulator's HK database.
    public protocol DeviceReadingHealthKitWriting: Sendable {
        func save(_ samples: [HKQuantitySample]) async throws
    }

    /// Test-injection seam over `OutboxQueue.enqueue`. The production
    /// conformance below ferries a failed `MeasurementBatchUploader`
    /// batch onto the outbox so `OutboxReplayService` retries at the
    /// next reachability + foreground wave. The forwarder talks to the
    /// protocol so tests can stub the enqueue path without spinning up
    /// SwiftData.
    public protocol DeviceReadingOutboxEnqueuing: Sendable {
        /// Persist a batch of `HealthKitBatchEntryDTO`s as a single
        /// `syncHealthKitSample` outbox operation. Encoding is done by
        /// the caller (so a single shared encoder choice — `.hlBatch` —
        /// stays consistent with `MeasurementBatchUploader`).
        func enqueueBatch(
            _ entries: [HealthKitBatchEntryDTO],
            encoder: JSONEncoder
        ) async throws
    }

    /// Production conformance ferrying failed device-forwarder batches
    /// onto the existing `OutboxQueue`.
    ///
    /// Phase 07 moved the enqueue body itself into
    /// `OutboxQueue+HealthKit.swift`, where it sits beside the importer
    /// overload and the quarantine rule, so the `syncHealthKitSample`
    /// payload shape has exactly one definition. `OutboxReplayService`
    /// now re-issues those exact wire bytes under the persisted
    /// idempotency key. Only the protocol conformance stays here: the
    /// protocol is declared in this app-only, HealthKit-guarded file,
    /// while the queue extension also compiles into `HealthLogCore` and
    /// the widget extension.
    extension OutboxQueue: DeviceReadingOutboxEnqueuing {
        public func enqueueBatch(
            _ entries: [HealthKitBatchEntryDTO],
            encoder: JSONEncoder
        ) async throws {
            try await enqueueHealthKitBatch(entries, encoder: encoder)
        }
    }

    /// Default `HKHealthStore`-backed writer. `final` so the type stays
    /// `Sendable` without `@unchecked` — `HKHealthStore` itself is
    /// documented thread-safe by Apple and the inner `save` is a single
    /// async hop.
    public final class HealthKitDeviceReadingWriter: DeviceReadingHealthKitWriting {
        private let store: HKHealthStore

        public init(store: HKHealthStore) {
            self.store = store
        }

        public func save(_ samples: [HKQuantitySample]) async throws {
            guard !samples.isEmpty else { return }
            try await store.save(samples)
        }
    }
#endif
