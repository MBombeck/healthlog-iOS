import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// The three HealthKit reads the server→Apple-Health mirror decides with.
    ///
    /// A value of closures so ``HealthKitServerMirrorPlanner`` runs the live
    /// rules in a unit test: CI has no Health database and no share
    /// authorization, so the planner is fed a fake Health state instead.
    struct HealthKitServerMirrorProbe: Sendable {
        /// Whether this app may write the sample's type.
        var isShareAuthorized: @Sendable (HKQuantitySample) -> Bool
        /// Whether any sample of the type carries one of the ids in
        /// `HKMetadataKeyExternalUUID`.
        var existsWithExternalIDs: @Sendable ([String], HKSampleType) async -> Bool
        /// Samples THIS app authored of the type, starting within a second of
        /// the instant. Used for the metadata-free fallback.
        var ownSamplesNear: @Sendable (HKQuantityType, Date) async -> [HKQuantitySample]
        /// **1.4 / iOS 27** — the earliest readable date per limited type
        /// (``HealthKitAuthorizedHistoryProviding``). `[:]` = nothing limited,
        /// `nil` = HealthKit could not say. Defaults to "nothing limited".
        var earliestAuthorizedDates: @Sendable (Set<HKObjectType>) async -> [HKObjectType: Date]? = { _ in [:] }
        /// **B5 (1.4)** — the person's per-type direction from the server
        /// (``HealthKitWriteBackPolicy``). `nil` = not known right now (no
        /// cached answer and the server out of reach). Defaults to "no setting".
        var writeBackPolicy: @Sendable () async -> HealthKitWriteBackPolicy? = { .unrestricted }
    }

    /// **S1 / public #11** — the decision half of the server→Apple-Health mirror.
    ///
    /// `HealthKitService.mirrorServerMeasurements` and the create-time write
    /// both route through here, so the rule that decides "already in Apple
    /// Health" exists once. A row is written only when all of these hold:
    ///
    /// 0. **B5 (1.4)** — the person's direction for its kind lets HealthLog
    ///    write it (``HealthKitWriteBackPolicy``; unknown writes nothing),
    /// 1. source and kind are mirror-eligible (`shouldMirrorFromServer`),
    /// 2. none of its server ids is excluded — claimed by a write in flight on
    ///    this device, or deleted from Apple Health by the user
    ///    (``HealthKitMirrorTombstones``) — and none was seen earlier in the batch,
    /// 3. every sample type is share-authorized,
    /// 4. no sample carries one of its server ids
    ///    (``Measurement/serverMirrorLinkageIDs``: the row id, and for blood
    ///    pressure also the diastolic peer an older build stamped),
    /// 5. no sample this app authored has the same type, instant and value —
    ///    the fallback for a sample that lost or never had the id metadata.
    ///
    /// **1.4 / iOS 27 — limited history.** Rules 4 and 5 read "not found" as
    /// "not there", which only holds where the app may read. A person who
    /// grants a recent window hides everything older, including the samples
    /// this mirror wrote earlier, so a row whose sample would end before its
    /// type's boundary is not written at all: the planner cannot tell a missing
    /// sample from a hidden one, and writing would duplicate it. When HealthKit
    /// cannot report the boundary, nothing is written in that pass.
    enum HealthKitServerMirrorPlanner {
        struct Plan {
            /// Samples to save, in candidate order.
            var samples: [HKQuantitySample] = []
            /// What is handed to `HKHealthStore.save`: the samples, with each
            /// blood-pressure pair wrapped in its correlation (T4 / #15).
            var objects: [HKObject] = []
            /// Server ids of every row the plan writes. The caller keeps them
            /// claimed while the save is in flight.
            var linkageIDs: [String] = []
            /// **B5 (1.4)** — `false` when the person's direction was not known
            /// and the pass wrote nothing for that reason. The one-shot history
            /// mirror then stays due. An unknown readable window (A3) does not
            /// count: it can stay unknown, and the one-shot would then fetch the
            /// whole history again on every refresh.
            var decided = true
        }

        /// The metadata every mirrored sample carries: the server id (dedup and
        /// the import path's echo filter) and the app-origin marker. Each object
        /// adds its own sync identifier when it is built (A6,
        /// ``HealthKitCopySyncIdentity``), the one key a deletion keeps.
        static func metadata(for measurement: Measurement) -> [String: Any] {
            [
                HKMetadataKeyExternalUUID: measurement.id,
                HealthKitSampleOwnership.appOriginMetadataKey: HealthKitSampleOwnership.appOriginMetadataValue
            ]
        }

        static func plan(
            _ measurements: [Measurement],
            excluding excluded: Set<String>,
            probe: HealthKitServerMirrorProbe
        ) async -> Plan {
            var plan = Plan()
            var seen = excluded
            let eligible = measurements.filter(HealthKitService.shouldMirrorFromServer)
            guard !eligible.isEmpty else { return plan }
            // B5 (1.4) — the person's direction per kind. Not known now: write
            // nothing and say so, the next pass decides.
            guard let policy = await probe.writeBackPolicy() else {
                plan.decided = false
                return plan
            }
            let candidates = eligible.filter { policy.allowsWrite($0.kind) }
            guard !candidates.isEmpty else { return plan }
            // One question per pass, for every type a candidate would write.
            let readable = await probe.earliestAuthorizedDates(sampleTypes(of: candidates))
            for measurement in candidates {
                let ids = measurement.serverMirrorLinkageIDs
                guard seen.isDisjoint(with: ids) else { continue }
                seen.formUnion(ids)
                let built = HealthKitService.quantitySamples(for: measurement, metadata: metadata(for: measurement))
                guard let first = built.first else { continue }
                guard built.allSatisfy(probe.isShareAuthorized) else { continue }
                guard !built.contains(where: { isHidden($0, in: readable) }) else { continue }
                if await probe.existsWithExternalIDs(ids, first.sampleType) { continue }
                let own = await probe.ownSamplesNear(first.quantityType, measurement.recordedAt)
                if isAlreadyPresent(first, among: own) { continue }
                plan.samples.append(contentsOf: built)
                plan.objects.append(contentsOf: HealthKitService.healthObjects(
                    for: measurement,
                    samples: built,
                    metadata: metadata(for: measurement)
                ))
                plan.linkageIDs.append(contentsOf: ids)
            }
            return plan
        }

        /// Every sample type the candidates would write.
        private static func sampleTypes(of candidates: [Measurement]) -> Set<HKObjectType> {
            Set(candidates.flatMap { measurement in
                HealthKitService.quantitySamples(for: measurement, metadata: [:]).map { $0.sampleType as HKObjectType }
            })
        }

        /// Whether `sample` would land where an empty Health read proves
        /// nothing (1.4 / iOS 27 limited history).
        static func isHidden(_ sample: HKQuantitySample, in readable: [HKObjectType: Date]?) -> Bool {
            HealthReadWindow(sample.sampleType, in: readable).hidesAbsence(endingAt: sample.endDate)
        }

        /// True when `existing` holds a sample of the same type, within a
        /// second of the same instant, with the same value. The caller passes
        /// only samples this app authored, so a reading another app stored at
        /// the same moment never suppresses a write.
        static func isAlreadyPresent(_ candidate: HKQuantitySample, among existing: [HKQuantitySample]) -> Bool {
            let unit = HealthKitWireConverter.preferredUnit(for: candidate.quantityType.identifier)?.hkUnit
            return existing.contains { sample in
                guard sample.quantityType == candidate.quantityType,
                      abs(sample.startDate.timeIntervalSince(candidate.startDate)) < 1 else { return false }
                guard let unit,
                      sample.quantity.is(compatibleWith: unit),
                      candidate.quantity.is(compatibleWith: unit) else
                {
                    return sample.quantity.compare(candidate.quantity) == .orderedSame
                }
                return abs(sample.quantity.doubleValue(for: unit) - candidate.quantity.doubleValue(for: unit)) < 0.0001
            }
        }
    }

#endif
