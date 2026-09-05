import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **GH #47 — the iOS 26+ HealthKit-backed ``AppleHealthMedicationReading``.**
    ///
    /// The ONLY HealthKit-aware seam of the Apple-medications feature. Reads
    /// `HKUserAnnotatedMedication` + `HKMedicationDoseEvent` (both iOS 26 types)
    /// and projects them into the plain `Sendable` records the importer + tests
    /// consume. Every HK access is gated `#available(iOS 26.0, *)`; below iOS 26
    /// (or when the Medications data type is unavailable) ``isAvailable`` is
    /// `false` and the importer short-circuits — no auth prompt ever fires.
    ///
    /// Mapping (read-only, lossy by design):
    /// - `medication.displayText` → name
    /// - `medication.generalForm` → deliveryForm (`ORAL|INJECTION|OTHER`)
    /// - `medication.relatedCodings` (RxNorm system) → rxNormCode
    /// - `!hasSchedule` → asNeeded (a med with no dosing schedule is PRN)
    /// - `medication.identifier` → the stable mirror `externalId`
    /// - dose `logStatus` → taken / skipped / other
    public struct AppleHealthMedicationReader: AppleHealthMedicationReading {
        public init() {}

        /// A fresh `HKHealthStore` per call. HealthKit tracks authorization
        /// process-wide and queries run against any instance, so the reader
        /// holds no non-`Sendable` state (the struct stays trivially `Sendable`
        /// — no `@unchecked` needed, per PROJECT_GUIDE.md).
        private func makeStore() -> HKHealthStore {
            HKHealthStore()
        }

        public var isAvailable: Bool {
            guard HKHealthStore.isHealthDataAvailable() else { return false }
            if #available(iOS 26.0, *) { return true }
            return false
        }

        public func requestAuthorization() async throws {
            guard #available(iOS 26.0, *) else { return }
            // GH #47 crash fix: per-object read authorization applies ONLY to the
            // medication OBJECT type (`HKUserAnnotatedMedicationType`). Dose events
            // are `HKSample`s — `HKMedicationDoseEventType: HKSampleType` — and do
            // NOT support per-object auth; authorizing a medication automatically
            // grants read access to its dose events (WWDC25 §321). Passing the
            // dose-event sample type to `requestPerObjectReadAuthorization` is an
            // invalid argument that raises an uncatchable ObjC NSException →
            // SIGABRT (the medication overlay shows, then the second call traps).
            // Dose events are read via a normal `HKSampleQuery` in `readDoseEvents`.
            try await makeStore().requestPerObjectReadAuthorization(
                for: HKObjectType.userAnnotatedMedicationType(),
                predicate: nil
            )
        }

        public func readMedications() async throws -> [AppleHealthMedicationRecord] {
            guard #available(iOS 26.0, *) else { return [] }
            let descriptor = HKUserAnnotatedMedicationQueryDescriptor(predicate: nil, limit: nil)
            let annotated = try await descriptor.result(for: makeStore())
            return annotated.compactMap(Self.record(from:))
        }

        public func readDoseEvents(since: Date?) async throws -> [AppleHealthDoseRecord] {
            guard #available(iOS 26.0, *) else { return [] }
            let store = makeStore()
            let end = Date.distantFuture
            let start = since ?? .distantPast
            // PRN/as-needed events deliberately have no scheduledDate. Query
            // the sample interval so they remain visible to every sync.
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
                let query = HKSampleQuery(
                    sampleType: HKObjectType.medicationDoseEventType(),
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: samples ?? [])
                    }
                }
                store.execute(query)
            }
            let events = samples.compactMap { $0 as? HKMedicationDoseEvent }
            return events.compactMap(Self.record(from:))
        }

        // MARK: - Mapping

        @available(iOS 26.0, *)
        private static func record(from annotated: HKUserAnnotatedMedication) -> AppleHealthMedicationRecord? {
            let concept = annotated.medication
            let conceptID = conceptString(concept.identifier)
            guard !conceptID.isEmpty else { return nil }
            // Prefer a non-empty user nickname, else the concept's display text.
            let name = annotated.nickname.flatMap { $0.isEmpty ? nil : $0 } ?? concept.displayText
            return AppleHealthMedicationRecord(
                conceptIdentifier: conceptID,
                name: name,
                deliveryForm: deliveryForm(from: concept.generalForm),
                rxNormCode: rxNormCode(from: concept.relatedCodings),
                asNeeded: !annotated.hasSchedule,
                isArchived: annotated.isArchived
            )
        }

        @available(iOS 26.0, *)
        private static func record(from event: HKMedicationDoseEvent) -> AppleHealthDoseRecord? {
            let status: AppleHealthDoseLogStatus = switch event.logStatus {
            case .taken: .taken
            case .skipped: .skipped
            default: .other
            }
            // Only the taken/skipped dispositions are imported; drop the rest.
            guard status != .other else { return nil }
            let occurrence = AppleHealthDoseRecord.occurrenceDate(
                scheduledDate: event.scheduledDate,
                sampleStart: event.startDate
            )
            // CU-10: an unarchivable concept yields no stable identity, so the
            // dose has nothing to attach to — drop it instead of sending it under
            // a key that can never resolve.
            let conceptID = conceptString(event.medicationConceptIdentifier)
            guard !conceptID.isEmpty else { return nil }
            return AppleHealthDoseRecord(
                eventUUID: event.uuid.uuidString,
                conceptIdentifier: conceptID,
                logStatus: status,
                scheduledAt: occurrence,
                takenAt: status == .taken ? event.startDate : nil,
                recordedAt: event.startDate,
                doseQuantity: status == .taken ? (event.doseQuantity ?? event.scheduledDoseQuantity) : nil,
                doseUnit: event.unit.unitString
            )
        }

        /// A deterministic, stable string for a HK concept identifier. The SAME
        /// concept produces the SAME string on both the medication side and the
        /// dose-event side **and across process runs**, so the concept →
        /// mirrored-med map stays consistent and the server's
        /// `(userId, externalSource, externalId)` upsert key actually matches.
        ///
        /// **CU-10 / GH #47.** This used to be `String(describing: identifier)`.
        /// `HKHealthConceptIdentifier` is opaque and documents no `description`
        /// contract, so that returned `NSObject`'s default —
        /// `<HKHealthConceptIdentifier: 0x12568db80>`, a memory address that is a
        /// new value on every launch. The server upsert never matched, so each
        /// sweep minted a fresh medication row (23 phantom rows on the operator's
        /// instance) and every dose resolved through the same rotating string and
        /// never found its medication. What Apple *does* document for the type is
        /// `NSSecureCoding`, so the identity comes from the archived bytes.
        ///
        /// Returns `""` when the identifier cannot be archived — the callers drop
        /// the record rather than mirror it under an unstable key. A medication
        /// that is silently missing is recoverable; a phantom row is not.
        @available(iOS 26.0, *)
        private static func conceptString(_ identifier: HKHealthConceptIdentifier) -> String {
            do {
                let archived = try NSKeyedArchiver.archivedData(
                    withRootObject: identifier,
                    requiringSecureCoding: true
                )
                return AppleHealthConceptKey.derive(fromArchivedIdentifier: archived)
            } catch {
                HLLog.healthKit.error(
                    "APPLE-MED concept archive failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                return ""
            }
        }

        /// Map the HK dosage form onto the server `deliveryForm` enum.
        ///
        /// Build 274 (public #2) — compares the RAW string. The typed constants
        /// (`.capsule` …) are un-annotated `extern NSString *const` globals in
        /// the iOS 26.5 SDK; pattern-matching them emitted STRONG dyld references
        /// and build 273 aborted at launch on every iOS 18 device. Nothing in the
        /// app binary may name those symbols — `AppleHealthMedicationFormLinkageTests`
        /// pins the strings, `scripts/verify-no-strong-ios26-symbols.sh` the binary.
        @available(iOS 26.0, *)
        private static func deliveryForm(from form: HKMedicationGeneralForm) -> String? {
            deliveryForm(fromRawForm: form.rawValue)
        }

        /// Build 274 (public #2) — the raw-string mapping. Internal so the
        /// linkage test can drive it on any OS; the strings are the SDK's own
        /// (pinned by the same suite).
        static func deliveryForm(fromRawForm raw: String) -> String? {
            switch raw {
            case "injection":
                "INJECTION"
            case "tablet", "capsule", "liquid", "drops", "powder":
                "ORAL"
            case "unknown":
                nil
            default:
                "OTHER"
            }
        }

        /// Pull the RxNorm RxCUI out of the concept's related clinical codings.
        @available(iOS 26.0, *)
        private static func rxNormCode(from codings: Set<HKClinicalCoding>) -> String? {
            codings.first { $0.system.lowercased().contains("rxnorm") }?.code
        }
    }

#endif
