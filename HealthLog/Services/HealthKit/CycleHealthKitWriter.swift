import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **Phase C2 — write MANUAL cycle day-logs back into Apple Health.**
    ///
    /// The reverse of ``CycleHealthKitImporter``: a MANUAL-origin
    /// ``CycleDayLogDTO`` mirrors its reproductive fields into Apple Health as
    /// `HKCategorySample`s so a HealthLog-logged period / ovulation test / mucus /
    /// symptom shows up in the system Health app.
    ///
    /// **Anti-dup + echo guard (PROJECT_GUIDE.md + contract §5).**
    /// - Every written sample carries `HKMetadataKeyExternalUUID = dayLog.id`, so
    ///   the importer recognises the round-trip and skips it (no re-upload loop).
    /// - We **never** write a `source:"HEALTHKIT"` row back to HealthKit — that
    ///   row originated in Apple Health; pushing it back would duplicate. Only
    ///   MANUAL-source day-logs round-trip (mirrors the `MoodLog` reverse-sync
    ///   filter + `writeMeasurement`'s `source == .manual` guard).
    ///
    /// **Flow type.** Always `HKCategoryTypeIdentifierMenstrualFlow` —
    /// `HKCategoryValueVaginalBleeding` is only a *value* enum on that same type
    /// (verified against the iOS 26.5 SDK; there is NO
    /// `HKCategoryTypeIdentifierVaginalBleeding`). Every menstrual-flow sample
    /// MUST carry `HKMetadataKeyMenstrualCycleStart` (required key — HealthKit
    /// raises an uncatchable `NSInvalidArgumentException` in
    /// `_validateForCreation` without it; W-CYCLECRASH root cause).
    /// `SPOTTING → HK light` (Q3 boundary); `NONE` is not mirrored (a "no
    /// bleeding" log has no meaningful Health-app entry).
    ///
    /// **Value validation.** Every category value is range-checked against
    /// ``CycleHealthKitMapping/validWriteValueRange(forIdentifier:)`` before
    /// `HKCategorySample` init — an out-of-range codepoint also raises the same
    /// uncatchable exception. Invalid values are logged + skipped, never written.
    ///
    /// Gated behind `FeatureFlag.cycleTracking` — only constructed once the gate
    /// passes. iOS 18+; silent no-op on older OS.
    actor CycleHealthKitWriter {
        private let store: HKHealthStore

        init(store: HKHealthStore) {
            self.store = store
        }

        /// Mirror a MANUAL day-log into Apple Health. Idempotent from the iOS
        /// side only when gated on a successful server write (HK has no metadata
        /// de-dup); callers MUST gate this on a 2xx, exactly like
        /// `writeMeasurement`. A `source:"HEALTHKIT"` day-log is a no-op (echo
        /// guard). Note: BBT is NOT written here — `basalBodyTemperature` is a
        /// quantity sample owned by the measurements write path (see C2 report).
        ///
        /// - Parameter isCycleStart: true when `dayLog.date` is the first day of
        ///   a menstrual cycle (period start) — feeds the REQUIRED
        ///   `HKMetadataKeyMenstrualCycleStart` flag on the flow sample.
        func write(_ dayLog: CycleDayLogDTO, isCycleStart: Bool) async throws {
            guard #available(iOS 18.0, *) else { return }
            // Echo guard — never push a HealthKit-origin row back into HealthKit.
            guard dayLog.source == "MANUAL" else { return }

            guard let date = Self.dateFormatter.date(from: dayLog.date) else { return }
            // HealthKit validates `HKMetadataKeyExternalUUID` as a UUID string at
            // sample init (uncatchable exception otherwise) — a non-UUID id must
            // skip the mirror entirely; dropping the key instead would break the
            // echo guard + delete path and re-import our own write.
            guard UUID(uuidString: dayLog.id) != nil else {
                HLLog.healthKit.error("cycle HK mirror skipped: day-log id is not a UUID")
                return
            }
            let metadata: [String: Any] = [
                HKMetadataKeyExternalUUID: dayLog.id,
                HKMetadataKeyWasUserEntered: true,
                // BH-final-diff H2 — app-origin marker for delete-path ownership.
                HealthKitSampleOwnership.appOriginMetadataKey: HealthKitSampleOwnership.appOriginMetadataValue
            ]

            let samples = Self.buildSamples(for: dayLog, isCycleStart: isCycleStart, date: date, metadata: metadata)
            guard !samples.isEmpty else { return }
            try await store.save(samples)
        }

        /// Delete every cycle category sample we mirrored for a day-log (by our
        /// anti-dup marker). Mirrors `deleteMoodEntry`. Silent no-op when nothing
        /// matches / auth is off.
        func delete(dayLogID: String) async throws {
            guard #available(iOS 18.0, *) else { return }
            let predicate = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                allowedValues: [dayLogID]
            )
            for type in CycleHealthKitImporter.readCategoryTypes() {
                let matches = try await samples(of: type, matching: predicate)
                if !matches.isEmpty { try await store.delete(matches) }
            }
        }

        // MARK: - Sample builders (static + pure so the crash path unit-tests)

        /// Build every `HKCategorySample` a day-log mirrors. Pure (no store) —
        /// `HKCategorySample` init is exactly where HealthKit raises for missing
        /// menstrual-cycle-start metadata or out-of-range values, so the tests
        /// pinning this function exercise the real crash path.
        @available(iOS 18.0, *)
        static func buildSamples(
            for dayLog: CycleDayLogDTO,
            isCycleStart: Bool,
            date: Date,
            metadata: [String: Any]
        ) -> [HKCategorySample] {
            var samples: [HKCategorySample] = []
            samples.append(contentsOf: flowSamples(dayLog, isCycleStart: isCycleStart, date: date, metadata: metadata))
            samples.append(contentsOf: enumSamples(dayLog, date: date, metadata: metadata))
            samples.append(contentsOf: symptomSamples(dayLog, date: date, metadata: metadata))
            return samples
        }

        @available(iOS 18.0, *)
        private static func flowSamples(
            _ dayLog: CycleDayLogDTO,
            isCycleStart: Bool,
            date: Date,
            metadata: [String: Any]
        ) -> [HKCategorySample] {
            // NONE = an explicit "no bleeding" log — there is no meaningful
            // Health-app mirror for it (and it would pollute Apple's own cycle
            // predictions), so it writes nothing.
            guard let flow = dayLog.flowLevel, flow != CycleFlowLevel.none else { return [] }
            let value = CycleHealthKitMapping.vaginalBleedingValue(for: flow)
            // REQUIRED on every menstrual-flow sample (see actor doc).
            var meta = metadata
            meta[HKMetadataKeyMenstrualCycleStart] = NSNumber(value: isCycleStart)
            return makeSample(
                identifier: CycleHealthKitMapping.menstrualFlow,
                value: value,
                date: date,
                metadata: meta
            ).map { [$0] } ?? []
        }

        @available(iOS 18.0, *)
        private static func enumSamples(_ dayLog: CycleDayLogDTO, date: Date, metadata: [String: Any]) -> [HKCategorySample] {
            var out: [HKCategorySample] = []
            if let test = dayLog.ovulationTestValue {
                append(&out, CycleHealthKitMapping.ovulationTest, CycleHealthKitMapping.ovulationTestValue(for: test), date, metadata)
            }
            if let mucus = dayLog.cervicalMucusValue {
                append(&out, CycleHealthKitMapping.cervicalMucus, CycleHealthKitMapping.cervicalMucusValue(for: mucus), date, metadata)
            }
            if let preg = dayLog.pregnancyTest.flatMap(CycleTestResult.init) {
                append(&out, CycleHealthKitMapping.pregnancyTest, CycleHealthKitMapping.homeTestValue(for: preg), date, metadata)
            }
            if let prog = dayLog.progesteroneTest.flatMap(CycleTestResult.init) {
                append(&out, CycleHealthKitMapping.progesteroneTest, CycleHealthKitMapping.homeTestValue(for: prog), date, metadata)
            }
            if dayLog.intermenstrualBleeding {
                // `HKCategoryValueNotApplicable` (0) — the ONLY valid value for
                // this type (presence is the sample itself).
                append(&out, CycleHealthKitMapping.intermenstrualBleeding, 0, date, metadata)
            }
            if dayLog.sexualActivity {
                out.append(contentsOf: sexualActivitySamples(dayLog, date: date, metadata: metadata))
            }
            return out
        }

        @available(iOS 18.0, *)
        private static func sexualActivitySamples(
            _ dayLog: CycleDayLogDTO,
            date: Date,
            metadata: [String: Any]
        ) -> [HKCategorySample] {
            var meta = metadata
            if let prot = dayLog.protectedSex {
                meta[CycleHealthKitMapping.sexualActivityProtectionMeta] = prot
            }
            // `HKCategoryValueNotApplicable` (0) — the only valid value.
            return makeSample(
                identifier: CycleHealthKitMapping.sexualActivity,
                value: 0,
                date: date,
                metadata: meta
            ).map { [$0] } ?? []
        }

        @available(iOS 18.0, *)
        private static func symptomSamples(_ dayLog: CycleDayLogDTO, date: Date, metadata: [String: Any]) -> [HKCategorySample] {
            var out: [HKCategorySample] = []
            for symptom in dayLog.symptoms {
                guard let identifier = CycleHealthKitMapping.symptomIdentifier(forKey: symptom.key) else { continue }
                // Contract severity → the identifier's OWN value enum (Severity /
                // Presence / AppetiteChanges — they are NOT interchangeable).
                // Unmappable severities skip the sample instead of crashing.
                guard let value = CycleHealthKitMapping.hkSymptomWriteValue(
                    identifier: identifier,
                    severity: symptom.severity
                ) else {
                    HLLog.healthKit.error(
                        "cycle HK mirror: unmappable symptom severity for \(identifier, privacy: .public) — skipped"
                    )
                    continue
                }
                append(&out, identifier, value, date, metadata)
            }
            return out
        }

        @available(iOS 18.0, *)
        private static func append(
            _ out: inout [HKCategorySample],
            _ identifier: String,
            _ value: Int,
            _ date: Date,
            _ metadata: [String: Any]
        ) {
            if let sample = makeSample(identifier: identifier, value: value, date: date, metadata: metadata) {
                out.append(sample)
            }
        }

        /// The single, validated `HKCategorySample` construction seam: every
        /// write-back sample is built here, gated on the SDK-verified value range
        /// for its type. Invalid values / unknown identifiers log + return nil —
        /// `HKCategorySample` init raises an uncatchable `NSInvalidArgument-`
        /// `Exception` for out-of-range values, so this gate is what keeps a bad
        /// mapping from crashing the app.
        @available(iOS 18.0, *)
        private static func makeSample(
            identifier: String,
            value: Int,
            date: Date,
            metadata: [String: Any]
        ) -> HKCategorySample? {
            guard let range = CycleHealthKitMapping.validWriteValueRange(forIdentifier: identifier),
                  range.contains(value),
                  let type = HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier)) else
            {
                HLLog.healthKit.error(
                    "cycle HK mirror: invalid category value \(value, privacy: .public) for \(identifier, privacy: .public) — skipped"
                )
                return nil
            }
            return HKCategorySample(type: type, value: value, start: date, end: date, metadata: metadata)
        }

        @available(iOS 18.0, *)
        private func samples(of type: HKCategoryType, matching predicate: NSPredicate) async throws -> [HKSample] {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, result, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: result ?? [])
                }
                store.execute(query)
            }
        }

        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()
    }

#endif
