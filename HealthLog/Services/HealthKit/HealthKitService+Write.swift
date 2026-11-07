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
        /// Save a manual-entry `Measurement` back into HealthKit. Callers MUST
        /// gate this on a successful server POST so `measurement.id` is the
        /// server id. Idempotent since S1: a second call for the same server id
        /// (or a mirror write of the same row) is skipped, by the in-flight
        /// claim and by the externalUUID probe. An offline-queued row is not
        /// written here at all; the server→Health mirror writes it once the
        /// outbox replay has given it a server id.
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
            // B5 (1.4) — only a kind the person lets HealthLog write
            // (``HealthKitWriteBackPolicy``). When the direction is not known
            // right now nothing is written here; the server mirror, which
            // covers `.manual` rows since S1, writes it once it is.
            guard let policy = await Self.resolveWriteBackPolicy(writeBackPolicyProvider),
                  policy.allowsWrite(measurement.kind) else { return }
            try await performWrite(measurement)
        }

        private func performWrite(_ measurement: Measurement) async throws {
            // S1 / public #11 — the server→Health mirror now writes `.manual`
            // rows too, so a row this device just created can reach the mirror
            // (a `.fresh` page right after the POST) while this write is in
            // flight. Claim its server ids before the first suspension; whoever
            // claims first writes, the other skips.
            let ids = measurement.serverMirrorLinkageIDs
            guard serverMirrorClaims.isDisjoint(with: ids) else { return }
            serverMirrorClaims.formUnion(ids)
            let metadata = Self.createTimeMetadata(for: measurement)
            let samples = Self.quantitySamples(for: measurement, metadata: metadata)
            guard let first = samples.first else {
                serverMirrorClaims.subtract(ids)
                // MetricKind raw value is an enum case — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.healthKit.debug(
                    "HK-Write skip für \(measurement.kind.rawValue, privacy: .public) — kein HK-Schreibtyp definiert."
                )
                return
            }
            // A sample with this id is already there (the mirror finished first).
            if await existsInHealth(externalUUIDs: ids, sampleType: first.sampleType) { return }
            do {
                try await store.save(Self.healthObjects(for: measurement, samples: samples, metadata: metadata))
            } catch {
                serverMirrorClaims.subtract(ids)
                throw error
            }
        }

        /// The metadata of a reading typed in this app: the mirror's (server id
        /// and origin marker) plus "entered by the person".
        static func createTimeMetadata(for measurement: Measurement) -> [String: Any] {
            var metadata = HealthKitServerMirrorPlanner.metadata(for: measurement)
            metadata[HKMetadataKeyWasUserEntered] = true
            return metadata
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
        ///
        /// A6 (1.4) — such a copy also gets its own sync identifier per type
        /// (``HealthKitCopySyncIdentity``), the one thing a deletion keeps.
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
                    metadata: copyMetadata(metadata, of: measurement, typeIdentifier: type.rawValue)
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

        /// `metadata` for one object of `measurement`'s copy: with the copy's
        /// sync identifier for `typeIdentifier` when it names the row (A6), as
        /// it is otherwise (the empty probe of the eligibility checks).
        static func copyMetadata(
            _ metadata: [String: Any],
            of measurement: Measurement,
            typeIdentifier: String
        ) -> [String: Any] {
            guard metadata[HKMetadataKeyExternalUUID] as? String == measurement.id else { return metadata }
            return metadata.merging(
                HealthKitCopySyncIdentity.metadata(serverID: measurement.id, typeIdentifier: typeIdentifier)
            ) { _, identity in identity }
        }

        /// **T4 / public #15** — what is actually saved for a measurement's
        /// samples. A blood pressure is ONE `HKCorrelation` of type
        /// `.bloodPressure` holding the systolic and diastolic sample; every
        /// other kind saves its samples as they are.
        ///
        /// Apple Health presents blood pressure only as that correlation. Two
        /// loose systolic/diastolic samples (what every build up to 290 saved)
        /// never show up as a blood-pressure reading in the Health app, so a
        /// reading typed in HealthLog looked as if it had not reached Apple
        /// Health at all. The child samples keep their own metadata, so the
        /// externalUUID probe, the read-back echo filter and the deletion
        /// tombstones, which all query the quantity types, see them unchanged.
        /// Saving the correlation needs share authorization for the two
        /// quantity types only; the correlation type itself is not requestable.
        /// A6 — the correlation carries its own sync identifier, so a second
        /// save of the same reading is ignored as a whole, never half.
        static func healthObjects(
            for measurement: Measurement,
            samples: [HKQuantitySample],
            metadata: [String: Any]
        ) -> [HKObject] {
            guard measurement.kind == .bloodPressure,
                  samples.count == 2,
                  Set(samples.map(\.quantityType)) == [
                      HKQuantityType(.bloodPressureSystolic),
                      HKQuantityType(.bloodPressureDiastolic)
                  ] else { return samples }
            return [HKCorrelation(
                type: HKCorrelationType(.bloodPressure),
                start: measurement.recordedAt,
                end: measurement.recordedAt,
                objects: Set(samples),
                metadata: copyMetadata(
                    metadata,
                    of: measurement,
                    typeIdentifier: HKCorrelationTypeIdentifier.bloodPressure.rawValue
                )
            )]
        }

        // MARK: - Server-origin mirror (W-HKMIRROR)

        /// **W-HKMIRROR** — mirror SERVER-ORIGIN measurements (entered on web /
        /// another device, or imported) back into Apple Health, so the user's
        /// iPhone Health app shows readings they did NOT type on this device.
        ///
        /// Hooked into the MeasurementsStore SWR `.fresh` path (authoritative
        /// server page) and the one-shot historical backfill.
        ///
        /// **Source policy** (`MeasurementSource.isServerMirrorEligible`):
        /// `.withings`, `.import_` and — since S1 / public #11 — `.manual`. A
        /// manual row typed on the web or on another device never reached Apple
        /// Health while `.manual` was excluded as "already round-tripped at
        /// create-time"; that only ever held for rows typed on this device.
        /// Still excluded: `.appleHealth` (originated in HealthKit) and every
        /// provider-owned source.
        ///
        /// **Anti-duplicate / idempotency** (``HealthKitServerMirrorPlanner``).
        /// Every sample carries `HKMetadataKeyExternalUUID = measurement.id`,
        /// so HK read-back drops it (no echo). A row is skipped when a sample
        /// already carries one of its server ids (BP: the systolic id, or the
        /// diastolic id older builds stamped at create-time), when this app
        /// already authored a sample of the same type, instant and value, when
        /// a create-time write on this actor has claimed it, or when the user
        /// deleted its sample from Apple Health (``HealthKitMirrorTombstones``).
        /// Since 1.4 it also skips a row older than the window the person lets
        /// HealthLog read on iOS 27: there "not found" is not evidence.
        /// Requires share-auth (skips silently otherwise). Runs on the actor,
        /// off the main thread; never throws into the sync path.
        ///
        /// B5 (1.4) — and only kinds the person lets HealthLog write
        /// (``HealthKitWriteBackPolicy``). Returns `false` when the direction
        /// was not known and the pass wrote nothing for that reason.
        @discardableResult
        func mirrorServerMeasurements(_ measurements: [Measurement]) async -> Bool {
            await mirrorServerMeasurements(measurements, rowLimit: .max, isExpired: { false }).decided
        }

        /// **MIRROR (1.5, public #28)** — the same mirror, bounded: at most
        /// `rowLimit` readings, and `isExpired` is asked before every reading and
        /// once more before the save. A window that closes before the save writes
        /// nothing, so a background wake never leaves half a batch; the next
        /// window plans again and the probes skip what is already there. The
        /// foreground page and the history pass call it unbounded.
        internal func mirrorServerMeasurements(
            _ measurements: [Measurement],
            rowLimit: Int,
            isExpired: @escaping @Sendable () -> Bool
        ) async -> ServerMirrorWriteOutcome {
            let plan = await HealthKitServerMirrorPlanner.plan(
                measurements,
                excluding: serverMirrorExclusions(),
                probe: serverMirrorProbe(),
                rowLimit: rowLimit,
                shouldStop: isExpired
            )
            guard !plan.samples.isEmpty else { return HealthKitServerMirrorPlanner.outcome(of: plan) }
            // S1 — a create-time write that reached the actor while the plan was
            // probing may have claimed one of these rows; it owns that row.
            guard serverMirrorClaims.isDisjoint(with: plan.linkageIDs) else {
                return await mirrorServerMeasurements(measurements, rowLimit: rowLimit, isExpired: isExpired)
            }
            serverMirrorClaims.formUnion(plan.linkageIDs)
            let store = store
            let outcome = await HealthKitServerMirrorPlanner.commit(plan, isExpired: isExpired) { objects in
                try await store.save(objects)
            }
            // Nothing saved (window closed, or HealthKit refused): release the
            // claims so the next pass may write these rows.
            if outcome.written == 0 { serverMirrorClaims.subtract(plan.linkageIDs) }
            return outcome
        }

        /// What the mirror leaves alone: rows a write on this actor has claimed,
        /// and rows whose copy the signed-in person deleted from Apple Health
        /// (A6, read under the same owner the deletion path records for).
        func serverMirrorExclusions() -> Set<String> {
            let owner = keychain.getString(forKey: KeychainKey.userID)
            return serverMirrorClaims.union(HealthKitMirrorTombstones(ownerID: owner).ids)
        }

        /// The live Health reads behind ``HealthKitServerMirrorPlanner``.
        private func serverMirrorProbe() -> HealthKitServerMirrorProbe {
            let store = store
            return HealthKitServerMirrorProbe(
                isShareAuthorized: { store.authorizationStatus(for: $0.sampleType) == .sharingAuthorized },
                existsWithExternalIDs: { [weak self] ids, type in
                    await self?.existsInHealth(externalUUIDs: ids, sampleType: type) ?? true
                },
                ownSamplesNear: { [weak self] type, instant in
                    await self?.ownSamples(of: type, near: instant) ?? []
                },
                // 1.4 / iOS 27 — the readable window, so rows older than it
                // are left alone instead of written again.
                earliestAuthorizedDates: { types in
                    await HealthKitAuthorizedHistory(store: store).earliestAuthorizedSampleDates(for: types)
                },
                // B5 (1.4) — the person's direction per type.
                writeBackPolicy: { [provider = writeBackPolicyProvider] in
                    await Self.resolveWriteBackPolicy(provider)
                }
            )
        }

        /// B5 (1.4) — the policy to write under: none attached means no
        /// setting (as before 1.4), an attached provider answers or says
        /// "not known now" (`nil`).
        static func resolveWriteBackPolicy(
            _ provider: (@Sendable () async -> HealthKitWriteBackPolicy?)?
        ) async -> HealthKitWriteBackPolicy? {
            guard let provider else { return .unrestricted }
            return await provider()
        }

        /// Source + kind policy for the server-origin mirror. Mirrors only
        /// user-authored-elsewhere sources whose kind has an HK write-type.
        ///
        /// **W-HKBACKFILL** — the source predicate reads the platform-free
        /// `MeasurementSource.isServerMirrorEligible` so the latest-page mirror
        /// and the historical backfill share one policy and cannot drift. The
        /// kind half stays anchored to the authoritative `quantitySamples`
        /// switch (a kind with no HK write-type yields `[]` → skip).
        ///
        /// **MIRROR (1.5, #152)** — the source half is now the server's
        /// per-row answer (``Measurement/isServerMirrorAllowed``), the source
        /// rule only where the row carries no `appleHealthMirror`.
        ///
        /// A blood pressure with a zero half (a pair the page cut in two, which
        /// the aggregator keeps as a lone half) is never written: "124/0" is not
        /// a reading.
        static func shouldMirrorFromServer(_ measurement: Measurement) -> Bool {
            guard measurement.isServerMirrorAllowed else { return false }
            if case let .bloodPressure(systolic, diastolic) = measurement.value, systolic <= 0 || diastolic <= 0 {
                return false
            }
            return !quantitySamples(for: measurement, metadata: [:]).isEmpty
        }

        /// Idempotency probe — true if a sample carrying one of these
        /// externalUUIDs already exists in HealthKit for the given type. Cheap,
        /// bounded `limit: 1`.
        private func existsInHealth(externalUUIDs: [String], sampleType: HKSampleType) async -> Bool {
            let predicate = HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeyExternalUUID,
                allowedValues: externalUUIDs
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

        /// Samples this app authored of `type` that start within a second of
        /// `instant` — the metadata-free fallback of the mirror dedup.
        private func ownSamples(of type: HKQuantityType, near instant: Date) async -> [HKQuantitySample] {
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForSamples(
                    withStart: instant.addingTimeInterval(-1),
                    end: instant.addingTimeInterval(1),
                    options: []
                ),
                HKQuery.predicateForObjects(from: HKSource.default())
            ])
            return await withCheckedContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: 16,
                    sortDescriptors: nil
                ) { _, result, _ in
                    continuation.resume(returning: (result ?? []).compactMap { $0 as? HKQuantitySample })
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

    /// MIRROR (1.5) — the background pass writes through the bounded mirror.
    extension HealthKitService: BoundedServerMirrorWriting {}

#endif
