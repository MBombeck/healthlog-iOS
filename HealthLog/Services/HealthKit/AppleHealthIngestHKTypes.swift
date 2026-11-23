#if canImport(HealthKit)
    import Foundation
    import HealthKit

    /// The HealthKit half of the ingest v2 types: resolving them on this
    /// system and turning a sample into its wire row.
    enum AppleHealthIngestHKTypes {
        /// The sample type for a registry identifier, or `nil` where this
        /// system's HealthKit does not have it (Hypertension before 26.2, the
        /// menopause types before 27).
        static func sampleType(for identifier: String) -> HKSampleType? {
            if AppleHealthIngestTypes.assessmentIdentifiers.contains(identifier) {
                return HKScoredAssessmentType(HKScoredAssessmentTypeIdentifier(rawValue: identifier))
            }
            if let quantity = AppleHealthIngestQuantityTypes.sampleType(for: identifier) {
                return quantity
            }
            if identifier == CycleBasalTemperature.identifier {
                return CycleBasalTemperature.sampleType
            }
            guard AppleHealthIngestTypes.isAvailableOnThisSystem(identifier) else { return nil }
            return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier))
        }

        /// A measurement-batch row: a category event like the older heart
        /// events, or a PHQ-9 / GAD-7 result. `nil` for this app's own writes.
        static func measurementEntry(from sample: HKSample) -> HealthKitBatchEntryDTO? {
            if let event = sample as? HKCategorySample {
                return HeartHealthEventImporter.entry(from: event)
            }
            guard sample.sourceRevision.source != HKSource.default() else { return nil }
            if let phq9 = sample as? HKPHQ9Assessment {
                return assessmentEntry(phq9, score: phq9.score, answers: phq9.answers.map(\.rawValue))
            }
            if let gad7 = sample as? HKGAD7Assessment {
                return assessmentEntry(gad7, score: gad7.score, answers: gad7.answers.map(\.rawValue))
            }
            return nil
        }

        static func assessmentEntry(_ sample: HKSample, score: Int, answers: [Int]) -> HealthKitBatchEntryDTO {
            let entry = HealthKitBatchEntryDTO(
                hkIdentifier: sample.sampleType.identifier,
                value: Double(score),
                unit: "count",
                startDate: sample.startDate,
                endDate: sample.startDate,
                externalId: sample.uuid.uuidString,
                externalSourceVersion: sample.sourceRevision.productType,
                deviceType: HealthKitWireConverter.deviceType(for: sample.device),
                assessmentAnswers: AppleHealthAssessmentAnswers.wire(answers, score: score)
            )
            return HealthKitReadingTimeZone.stamp([entry], from: sample).first ?? entry
        }

        /// A symptom-batch row, or `nil` for a "not present" sample, an
        /// unknown type and this app's own writes.
        static func symptomEntry(from sample: HKSample, now: Date = Date()) -> AppleHealthSymptomEntryDTO? {
            guard let symptom = sample as? HKCategorySample,
                  !HealthKitSampleOwnership.isOwnEcho(symptom),
                  AppleHealthSymptomTimestamps.arePlausible(start: symptom.startDate, end: symptom.endDate, now: now) else { return nil }
            let identifier = symptom.categoryType.identifier
            guard let code = AppleHealthSymptomCatalog.code(for: identifier),
                  let intensity = AppleHealthSymptomCatalog.intensity(forValue: symptom.value, identifier: identifier) else { return nil }
            return AppleHealthSymptomEntryDTO(
                code: code,
                occurredAt: symptom.startDate,
                endAt: symptom.endDate,
                intensity: intensity,
                externalId: symptom.uuid.uuidString
            )
        }
    }

    /// Sends Apple Health deletions to one ingest-v2 delete route, or keeps them
    /// in the outbox when the server is out of reach. `nil` when every id is
    /// accounted for (sent, kept, or refused for good); otherwise why the cursor
    /// must hold.
    struct AppleHealthDeletionSender: Sendable {
        let send: @Sendable ([String], AppleHealthDeleteDomain) async throws -> Void
        let queue: (any HealthSyncBatchRetryEnqueuing)?

        func forward(
            _ externalIDs: [String],
            to domain: AppleHealthDeleteDomain,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncHoldReason? {
            var seen = Set<String>()
            let ids = externalIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
            let bound = AppleHealthDeleteDomain.maxIDsPerRequest
            for start in stride(from: 0, to: ids.count, by: bound) {
                let batch = Array(ids[start ..< min(start + bound, ids.count)])
                if let held = await forwardBatch(batch, to: domain, requiring: lease) { return held }
            }
            return nil
        }

        private func forwardBatch(
            _ ids: [String],
            to domain: AppleHealthDeleteDomain,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncHoldReason? {
            if let refusal = lease.refusal { return refusal.holdReason }
            do {
                try await lease.admitting { try await send(ids, domain) }
                return nil
            } catch let refusal as HealthSyncLeaseRefusal {
                return refusal.holdReason
            } catch let error where HealthSampleConsumption.isCancellation(error) {
                return .cancelled
            } catch let error where AppleHealthDeleteRefusal.isModuleOff(error) {
                // Contract §1: a module that is off pauses; the cursor holds.
                return .serverUnreachable
            } catch let error where AppleHealthDeleteRefusal.isFinal(error) {
                // The server read the request and said no; the same body would
                // earn the same answer.
                return nil
            } catch {
                return await keep(ids, domain: domain, requiring: lease)
            }
        }

        private func keep(
            _ ids: [String],
            domain: AppleHealthDeleteDomain,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncHoldReason? {
            guard let queue, let envelope = HealthSyncRetryEnvelope(
                ownerID: lease.ownerID,
                source: lease.source,
                stableIdentity: "delete:\(domain.rawValue):" + ids.sorted().joined(separator: "|")
            ) else { return .retryPersistenceFailed }
            if await queue.hasPendingHealthKitRetry(idempotencyKey: envelope.idempotencyKey) { return nil }
            do {
                try await lease.admitting {
                    try await queue.enqueueAppleHealthDeletion(
                        ids,
                        domain: domain,
                        idempotencyKey: envelope.idempotencyKey,
                        requiringCurrentOwner: lease.ownerID
                    )
                }
                return nil
            } catch let refusal as HealthSyncLeaseRefusal {
                return refusal.holdReason
            } catch {
                HLLog.healthKit.error("ingest deletions could not be kept — cursor holds")
                return .retryPersistenceFailed
            }
        }
    }
#endif

/// The item answers a PHQ-9 / GAD-7 row may carry. The server takes them
/// only as integers 0-3 that add up to the score; "prefer not to answer" on
/// PHQ-9 item 9 does not fit, so such a row goes out with the score alone.
enum AppleHealthAssessmentAnswers {
    static func wire(_ answers: [Int], score: Int) -> [Int]? {
        guard !answers.isEmpty, answers.allSatisfy({ (0 ... 3).contains($0) }),
              answers.reduce(0, +) == score else { return nil }
        return answers
    }
}

/// The server answers `implausible_timestamp` for a symptom that starts or
/// ends beyond the shared five-minute skew, or before 1900; the app does not
/// send such a row. An end before the start is dropped from the row instead.
enum AppleHealthSymptomTimestamps {
    static let skew: TimeInterval = 5 * 60
    static let earliest = Date(timeIntervalSince1970: -2_208_988_800) // 1900-01-01

    static func arePlausible(start: Date, end: Date, now: Date) -> Bool {
        let limit = now.addingTimeInterval(skew)
        return start >= earliest && start <= limit && end <= limit
    }
}
