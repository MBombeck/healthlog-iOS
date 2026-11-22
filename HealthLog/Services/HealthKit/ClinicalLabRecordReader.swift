import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// Reads `HKClinicalTypeIdentifierLabResultRecord` from Health Records.
    ///
    /// The only HealthKit-aware part of the lab sync. Asks for lab results
    /// alone, in a request of its own, never in the onboarding sheet. A fresh
    /// `HKHealthStore` per call keeps the reader free of non-`Sendable` state
    /// (the `AppleHealthMedicationReader` precedent).
    struct ClinicalLabRecordReader: ClinicalLabRecordReading {
        private static let label = "clinical.labResultRecord"

        private var labType: HKClinicalType {
            HKClinicalType(.labResultRecord)
        }

        var supportsHealthRecords: Bool {
            HKHealthStore.isHealthDataAvailable() && HKHealthStore().supportsHealthRecords()
        }

        func requestAuthorization() async throws {
            guard supportsHealthRecords else { return }
            try await HKHealthStore().requestAuthorization(toShare: [], read: [labType])
        }

        func changes(after anchor: Data?, limit: Int) async throws -> ClinicalLabChangesPage {
            let start = HealthKitAnchorArchive.decodeAnchor(anchor, label: Self.label)
            let store = HKHealthStore()
            let type = labType
            let (samples, next) = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<([HKSample], HKQueryAnchor?), Error>) in
                let query = HKAnchoredObjectQuery(
                    type: type,
                    predicate: nil,
                    anchor: start,
                    limit: limit
                ) { _, samples, _, newAnchor, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (samples ?? [], newAnchor))
                    }
                }
                store.execute(query)
            }
            let records = samples.compactMap { ($0 as? HKClinicalRecord).flatMap(Self.record(from:)) }
            return ClinicalLabChangesPage(
                records: records,
                anchor: HealthKitAnchorArchive.encodeAnchor(next, label: Self.label) ?? anchor,
                read: samples.count
            )
        }

        func records(withIDs ids: [UUID]) async throws -> [ClinicalLabRecord] {
            guard !ids.isEmpty else { return [] }
            let store = HKHealthStore()
            let type = labType
            let predicate = HKQuery.predicateForObjects(with: Set(ids))
            let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
                let query = HKSampleQuery(
                    sampleType: type,
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
            return samples.compactMap { ($0 as? HKClinicalRecord).flatMap(Self.record(from:)) }
        }

        /// A record without a FHIR resource carries nothing the route reads.
        private static func record(from clinical: HKClinicalRecord) -> ClinicalLabRecord? {
            guard let resource = clinical.fhirResource else { return nil }
            return ClinicalLabRecord(
                sampleID: clinical.uuid,
                resource: resource.data,
                fhirVersion: resource.fhirVersion.stringRepresentation,
                identifier: resource.identifier,
                sourceURL: resource.sourceURL?.absoluteString,
                sourceName: clinical.sourceRevision.source.name
            )
        }
    }

#endif
