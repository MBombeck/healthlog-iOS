import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// Write-back branch table for `HealthKitService.writeMeasurement`.
    ///
    /// **Why this lives in its own extension (v0.5.4 BF-5):**
    /// the write-back switch grew from 4 cases to 11 cases when we extended
    /// the round-trip coverage to every manual-entry kind in the Capture
    /// sheet (operator perception "ich erfasse was, aber Apple Health sieht
    /// es nicht"). Keeping the switch inline pushed the actor body over the
    /// 500-line SwiftLint limit; the extract keeps `HealthKitService.swift`
    /// focused on observation + anchor + auth lifecycle and gives the write
    /// table a single explicit home.
    ///
    /// **Anti-duplicate invariant (PROJECT_GUIDE.md HealthKit Specifics):**
    /// every branch sets `HKMetadataKeyExternalUUID = measurement.id` so the
    /// observation pipeline reading the same sample back in via
    /// `handleNewSamples` will see the metadata, recognise the round-trip,
    /// and skip the upload (`HealthKitService.handleNewSamples` filter loop).
    /// Drop that metadata key in any new branch and you build a re-upload
    /// loop on every HK observer wake.
    public extension HealthKitService {
        /// Save a manual-entry `Measurement` back into HealthKit. Idempotent
        /// from the iOS side — duplicate calls with the same `measurement.id`
        /// create two HK samples (HK has no de-dup on metadata), so callers
        /// MUST gate this on a successful server POST. The
        /// `MeasurementsRepository.create` path already does that; the outbox
        /// replay path inherits the same single-call guarantee because every
        /// outbox entry has a unique idempotency-key.
        func writeMeasurement(_ measurement: Measurement) async throws {
            // A4 MEDIUM #3 — source-aware write-back guard. Only user-originated
            // rows round-trip into Apple Health; device-integration rows
            // (WHOOP / Fitbit / Withings / Import) are server-authoritative and
            // must NEVER be pushed into HK with our `externalUUID`, else Apple
            // Health would show a foreign reading as if HealthLog-authored and
            // the value could re-enter via the Apple-Health source on another
            // device (cross-source contamination). Today the only call site is
            // the manual Capture sheet, so this is defensive — but it makes the
            // invariant structural rather than call-site discipline. Split from
            // `performWrite` so the guard doesn't push the kind-switch over the
            // SwiftLint cyclomatic-complexity ceiling.
            guard measurement.source == .manual else { return }
            try await performWrite(measurement)
        }

        private func performWrite(_ measurement: Measurement) async throws {
            let metadata: [String: Any] = [
                HKMetadataKeyExternalUUID: measurement.id,
                HKMetadataKeyWasUserEntered: true,
                // BH-final-diff H2 — app-origin marker so the delete path can
                // confirm ownership (HKDeletedObject has no sourceRevision).
                HealthKitSampleOwnership.appOriginMetadataKey: HealthKitSampleOwnership.appOriginMetadataValue
            ]
            let samples = Self.quantitySamples(for: measurement, metadata: metadata)
            guard !samples.isEmpty else {
                // MetricKind raw value is an enum case — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.debug(
                    "HK-Write skip für \(measurement.kind.rawValue, privacy: .public) — kein HK-Schreibtyp definiert."
                )
                return
            }
            try await store.save(samples)
        }

        /// **W-HKMIRROR** — pure builder mapping a `Measurement` to the
        /// `HKQuantitySample`(s) it round-trips into. Shared by the manual
        /// write-back path (`performWrite`) and the server-origin mirror
        /// (`mirrorServerMeasurements`). Returns `[]` for kinds without an HK
        /// write-counterpart (sleep is system-owned, walking metrics are
        /// passive iPhone sensors, body-water + bone-mass are smart-scale-only)
        /// so the caller can log+skip. Each branch mirrors the unit table in
        /// `HealthKitWireConverter.preferredUnit` (×100 inversion for percent
        /// kinds — HK stores the 0..1 fraction).
        ///
        /// **Anti-duplicate invariant:** the supplied `metadata` MUST carry
        /// `HKMetadataKeyExternalUUID = measurement.id` so the observation
        /// pipeline drops the sample on read-back (`HealthLogStandard.handleNewSamples`
        /// foreign-filter) and no re-upload loop forms.
        static func quantitySamples(
            for measurement: Measurement,
            metadata: [String: Any]
        ) -> [HKQuantitySample] {
            let at = measurement.recordedAt
            func scalar(_ type: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double) -> HKQuantitySample {
                HKQuantitySample(
                    type: HKQuantityType(type),
                    quantity: HKQuantity(unit: unit, doubleValue: value),
                    start: at,
                    end: at,
                    metadata: metadata
                )
            }
            let bpm = HKUnit.count().unitDivided(by: .minute())

            switch (measurement.kind, measurement.value) {
            case let (.weight, .scalar(kg)):
                return [scalar(.bodyMass, .gramUnit(with: .kilo), kg)]

            case let (.bloodPressure, .bloodPressure(sys, dia)):
                let mmHg = HKUnit.millimeterOfMercury()
                return [
                    scalar(.bloodPressureSystolic, mmHg, sys),
                    scalar(.bloodPressureDiastolic, mmHg, dia)
                ]

            case let (.glucose, .scalar(mgdl)):
                let unit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
                return [scalar(.bloodGlucose, unit, mgdl)]

            case let (.pulse, .scalar(value)):
                return [scalar(.heartRate, bpm, value)]

            case let (.bodyFat, .scalar(percent)):
                return [scalar(.bodyFatPercentage, .percent(), percent / 100.0)]

            case let (.bodyTemperature, .scalar(celsius)):
                return [scalar(.bodyTemperature, .degreeCelsius(), celsius)]

            case let (.spo2, .scalar(percent)):
                return [scalar(.oxygenSaturation, .percent(), percent / 100.0)]

            case let (.restingHeartRate, .scalar(value)):
                return [scalar(.restingHeartRate, bpm, value)]

            case let (.hrv, .scalar(milliseconds)):
                return [scalar(.heartRateVariabilitySDNN, .secondUnit(with: .milli), milliseconds)]

            case let (.vo2Max, .scalar(value)):
                // mL / (kg·min) — same composite unit as the wire converter.
                let perKgMin = HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())
                return [scalar(.vo2Max, HKUnit.literUnit(with: .milli).unitDivided(by: perKgMin), value)]

            case let (.bmi, .scalar(value)):
                // HK BMI is dimensionless `count` — server wire unit kg/m^2.
                return [scalar(.bodyMassIndex, .count(), value)]

            default:
                return []
            }
        }

        // MARK: - Server-origin mirror (W-HKMIRROR)

        /// **W-HKMIRROR** — mirror SERVER-ORIGIN measurements (entered on web /
        /// another device, or imported) back into Apple Health, so the user's
        /// iPhone Health app shows readings they did NOT type on this device.
        ///
        /// Hooked into the MeasurementsStore SWR `.fresh` path (authoritative
        /// server page). Closes the bidirectional-sync gap: until now only
        /// `.manual` rows round-tripped at create-time.
        ///
        /// **Conservative source policy.** We mirror ONLY rows the user
        /// genuinely authored away from this device and for which the server is
        /// a legitimate authoring source: `.withings` and `.import_`. We
        /// deliberately EXCLUDE:
        /// - `.manual` — already round-tripped at create-time (and suppressed
        ///   in standalone), mirroring again would double-write.
        /// - `.appleHealth` — originated in HealthKit already; writing it back
        ///   would duplicate / could re-enter via the Apple-Health source on
        ///   another device (cross-source contamination).
        /// - `.whoop` / `.fitbit` — wearable read-only-source kinds
        ///   (HR-series / sleep / strain) that belong to their provider; never
        ///   author those into Apple Health.
        ///
        /// **Anti-duplicate / idempotency.** Every sample carries
        /// `HKMetadataKeyExternalUUID = measurement.id` (the SAME stable server
        /// id used by the read foreign-filter), so HK read-back drops it (no
        /// echo). Before writing we query existing samples by that externalUUID
        /// and skip ids already present — writing the same id twice on a
        /// re-sync is a no-op (HK has no metadata de-dup, so we de-dup
        /// ourselves). Requires share-auth (skips silently otherwise). Runs on
        /// the actor, off the main thread; never throws into the sync path.
        func mirrorServerMeasurements(_ measurements: [Measurement]) async {
            let candidates = measurements.filter { Self.shouldMirrorFromServer($0) }
            guard !candidates.isEmpty else { return }

            var samples: [HKQuantitySample] = []
            for measurement in candidates {
                let metadata: [String: Any] = [
                    HKMetadataKeyExternalUUID: measurement.id,
                    // BH-final-diff H2 — app-origin marker for delete-path ownership.
                    HealthKitSampleOwnership.appOriginMetadataKey: HealthKitSampleOwnership.appOriginMetadataValue
                ]
                let built = Self.quantitySamples(for: measurement, metadata: metadata)
                guard !built.isEmpty else { continue }
                // Share-auth gate per write-type — skip silently if not granted.
                guard built.allSatisfy({ store.authorizationStatus(for: $0.sampleType) == .sharingAuthorized }) else {
                    continue
                }
                // Idempotency: skip ids already mirrored (re-sync no-op).
                if await existsInHealth(externalUUID: measurement.id, sampleType: built[0].sampleType) {
                    continue
                }
                samples.append(contentsOf: built)
            }
            guard !samples.isEmpty else { return }
            do {
                try await store.save(samples)
                // Count is operator-grade (no PHI).
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.debug(
                    "HK server-mirror: \(samples.count, privacy: .public) Sample(s) gespiegelt."
                )
            } catch {
                // Localized HK error string is operator-grade diagnostics.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.warning(
                    "HK server-mirror write fehlgeschlagen: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        /// Source + kind policy for the server-origin mirror. Mirrors only
        /// user-authored-elsewhere sources whose kind has an HK write-type.
        ///
        /// **W-HKBACKFILL** — the source predicate now reads the platform-free
        /// `MeasurementSource.isServerMirrorEligible` so the latest-page mirror
        /// and the historical backfill share one policy and cannot drift. The
        /// kind half stays anchored to the authoritative `quantitySamples`
        /// switch (a kind with no HK write-type yields `[]` → skip).
        static func shouldMirrorFromServer(_ measurement: Measurement) -> Bool {
            guard measurement.source.isServerMirrorEligible else { return false }
            return !quantitySamples(for: measurement, metadata: [:]).isEmpty
        }

        /// Idempotency probe — true if a sample with this externalUUID already
        /// exists in HealthKit for the given type. Cheap, bounded `limit: 1`.
        private func existsInHealth(externalUUID: String, sampleType: HKSampleType) async -> Bool {
            let predicate = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                allowedValues: [externalUUID]
            )
            return await withCheckedContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: sampleType,
                    predicate: predicate,
                    limit: 1,
                    sortDescriptors: nil
                ) { _, result, _ in
                    continuation.resume(returning: !(result ?? []).isEmpty)
                }
                store.execute(query)
            }
        }

        /// **v0.10.0 W10 M1 — delete the HKStateOfMind sample mirrored for a
        /// mood entry.** Mirrors a HealthLog mood-delete into Apple Health so a
        /// deleted mood doesn't linger in the Health app. Looks the sample up by
        /// our anti-dupe marker (`HKMetadataKeyExternalUUID == id`) and deletes
        /// every match. Silent no-op when the sample isn't ours / auth is off
        /// (the `try?` at the call site swallows `HKErrorAuthorizationDenied`,
        /// same gating as the write path). iOS 18+.
        func deleteMoodEntry(id: String) async throws {
            guard #available(iOS 18.0, *) else { return }
            let type = HKObjectType.stateOfMindType()
            let predicate = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                allowedValues: [id]
            )
            let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
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
            guard !samples.isEmpty else { return }
            try await store.delete(samples)
        }
    }

#endif
