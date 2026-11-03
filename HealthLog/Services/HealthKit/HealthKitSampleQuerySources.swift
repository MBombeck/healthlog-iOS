#if canImport(HealthKit)
    import Foundation
    import HealthKit

    // The production HealthKit reads behind the collector's two query seams.
    // Moved out of `AnchoredHealthSampleCollector.swift` in 1.3 (#127) when the
    // history read joined the anchored one.

    /// One bounded `HKAnchoredObjectQuery` per call. No update handler is
    /// installed, so the query is genuinely one-shot and the collector — not
    /// HealthKit — decides whether to ask again.
    struct HealthKitAnchoredPageSource: AnchoredHealthSampleQuerying {
        let store: HKHealthStore

        func page(
            typeIdentifier: String,
            resumingFrom anchor: HKQueryAnchor?,
            notBefore cutoff: Date,
            limit: Int
        ) async throws -> AnchoredHealthSamplePage {
            // The pre-1.3 form: the chosen window bounds the *first* walk only.
            try await page(
                typeIdentifier: typeIdentifier,
                resumingFrom: anchor,
                within: anchor == nil ? HealthSampleDateWindow(start: cutoff) : nil,
                limit: limit
            )
        }

        func page(
            typeIdentifier: String,
            resumingFrom anchor: HKQueryAnchor?,
            within window: HealthSampleDateWindow?,
            limit: Int
        ) async throws -> AnchoredHealthSamplePage {
            guard let sampleType = HealthKitSampleTypeResolver.sampleType(for: typeIdentifier) else {
                throw AnchoredHealthCollectionError.unknownSampleType
            }
            let predicate = window.flatMap(HealthSampleDatePredicate.make)

            return try await withCheckedThrowingContinuation { continuation in
                let query = HKAnchoredObjectQuery(
                    type: sampleType,
                    predicate: predicate,
                    anchor: anchor,
                    limit: limit
                ) { _, samples, deleted, newAnchor, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let collected = samples ?? []
                    let deletedCount = deleted?.count ?? 0
                    // A5 (1.4, R3 S4) — the same UUID the read path sends as
                    // `externalId`; A6 — unless the sync identifier, the one key
                    // a deletion keeps, names a HealthLog copy of a server row.
                    let split = HealthKitCopySyncIdentity.split((deleted ?? []).map { (uuid: $0.uuid, metadata: $0.metadata) })
                    continuation.resume(
                        returning: AnchoredHealthSamplePage(
                            samples: collected,
                            deletedObjectCount: deletedCount,
                            newAnchor: newAnchor,
                            mayHaveMore: collected.count + deletedCount >= limit,
                            deletedSampleIDs: split.sampleIDs,
                            deletedCopyServerIDs: split.copyServerIDs
                        )
                    )
                }
                store.execute(query)
            }
        }
    }

    /// 1.3 (#127) — the history leg's read: one `HKSampleQuery` per page,
    /// newest start date first, inside the walk's current date window.
    struct HealthKitHistoryPageSource: HealthSampleHistoryQuerying {
        let store: HKHealthStore

        func historyPage(
            typeIdentifier: String,
            within window: HealthSampleDateWindow,
            limit: Int?
        ) async throws -> [HKSample] {
            guard let sampleType = HealthKitSampleTypeResolver.sampleType(for: typeIdentifier) else {
                throw AnchoredHealthCollectionError.unknownSampleType
            }
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            return try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: sampleType,
                    predicate: HealthSampleDatePredicate.make(window),
                    limit: limit ?? HKObjectQueryNoLimit,
                    sortDescriptors: [sort]
                ) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: samples ?? [])
                    }
                }
                store.execute(query)
            }
        }

        /// B5 (1.4, R4 2.1) — A3's adapter, one question for all the types.
        func readWindows(typeIdentifiers: [String]) async -> [String: HealthReadWindow] {
            var types: [String: HKObjectType] = [:]
            for identifier in typeIdentifiers {
                types[identifier] = HealthKitSampleTypeResolver.sampleType(for: identifier)
            }
            let dates = await HealthKitAuthorizedHistory(store: store)
                .earliestAuthorizedSampleDates(for: Set(types.values))
            return types.mapValues { HealthReadWindow($0, in: dates) }
        }
    }

    /// Start-date predicates for a ``HealthSampleDateWindow``. Explicit
    /// comparisons on `HKPredicateKeyPathStartDate`, so the end can be
    /// inclusive or exclusive exactly as the walk needs it.
    enum HealthSampleDatePredicate {
        static func make(_ window: HealthSampleDateWindow) -> NSPredicate? {
            var parts: [NSPredicate] = []
            if let start = window.start {
                parts.append(NSPredicate(format: "%K >= %@", HKPredicateKeyPathStartDate, start as NSDate))
            }
            if let end = window.end {
                let format = window.endInclusive ? "%K <= %@" : "%K < %@"
                parts.append(NSPredicate(format: format, HKPredicateKeyPathStartDate, end as NSDate))
            }
            switch parts.count {
            case 0: return nil
            case 1: return parts[0]
            default: return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
            }
        }
    }
#endif
