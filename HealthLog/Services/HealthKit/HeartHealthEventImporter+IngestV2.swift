#if canImport(HealthKit)
    import Foundation
    import HealthKit

    /// One anchored read of the event importer: a single type, or several
    /// read together under one cursor (the symptoms). `key` names the cursor
    /// partition and the legacy anchor; for a single type it is the type's
    /// identifier, so the seven older event anchors stay where they were.
    /// HealthKit types are immutable but not annotated `Sendable` on every
    /// supported SDK (same reasoning as `WorkoutAnchoredQueryPage`).
    struct EventSweepUnit: @unchecked Sendable {
        enum Route: Sendable, Equatable {
            /// The seven older events: measurement batch, deletions not forwarded.
            case legacyEvent
            /// New measurement-batch types; deletions go to the measurement route
            /// when `forwardsDeletes`.
            case measurement(forwardsDeletes: Bool)
            /// The symptom batch and its delete route.
            case symptoms
        }

        let key: String
        let types: [HKSampleType]
        let route: Route
        /// The record module the server stores the unit under, when it has one.
        var module: ModuleKey?

        var descriptors: [HKQueryDescriptor] {
            types.map { HKQueryDescriptor(sampleType: $0, predicate: nil) }
        }

        /// The cursor key of the symptom unit.
        static let symptomsKey = "AppleHealthSymptoms.v1"
    }

    /// A symptom the server refused, with where it sat and why.
    struct SymptomRefusal {
        let index: Int
        let entry: AppleHealthSymptomEntryDTO
        let reason: String
    }

    /// What a symptom page's posts proved, index by index.
    struct SymptomRun {
        var held = Set<Int>()
        var refused: [SymptomRefusal] = []
        var transportThrew = false
        var paused = false
        var refusedWhole = false

        /// One answered chunk: landed rows are done, a skip is a refusal with
        /// its reason, anything unanswered or `failed` holds.
        mutating func absorb(_ response: HealthKitBatchResponseDTO, chunk: [AppleHealthSymptomEntryDTO], offset: Int) {
            var reasons: [Int: String] = [:]
            for skipped in response.skipped where chunk.indices.contains(skipped.index) {
                reasons[skipped.index] = skipped.reason
            }
            for entry in response.entries where chunk.indices.contains(entry.index) && entry.status == .skipped {
                reasons[entry.index] = reasons[entry.index] ?? entry.reason ?? "unknown"
            }
            let open = AppleHealthSymptomAcceptance.nonterminalIndexes(postedCount: chunk.count, response: response)
            held.formUnion(open.map { $0 + offset })
            for (index, reason) in reasons where !open.contains(index) {
                refused.append(SymptomRefusal(index: index + offset, entry: chunk[index], reason: reason))
            }
        }

        mutating func refuse(_ chunk: [AppleHealthSymptomEntryDTO], offset: Int, reason: String) {
            for (index, entry) in chunk.enumerated() {
                refused.append(SymptomRefusal(index: index + offset, entry: entry, reason: reason))
            }
        }
    }

    /// What one anchored read returned. Immutable after delivery.
    struct EventSweepPage: @unchecked Sendable {
        let samples: [HKSample]
        let deletedIDs: [String]
        let newAnchor: HKQueryAnchor?
    }

    extension HeartHealthEventImporter {
        // MARK: - Units

        /// The units this sweep reads now: the seven older events first, then
        /// every new type this system has and the configured server takes. New
        /// types run behind the old ones, so they never delay them.
        func sweepUnits() -> [EventSweepUnit] {
            Self.legacyUnits() + Self.ingestV2Units(defaults: defaults, onlyAccepted: true)
        }

        /// Every unit this build knows, for the logout reset.
        static func allSweepUnits() -> [EventSweepUnit] {
            legacyUnits() + ingestV2Units(defaults: .standard, onlyAccepted: false)
        }

        static func legacyUnits() -> [EventSweepUnit] {
            eventCategoryTypes().map { EventSweepUnit(key: $0.identifier, types: [$0], route: .legacyEvent) }
        }

        static func ingestV2Units(defaults: UserDefaults, onlyAccepted: Bool) -> [EventSweepUnit] {
            let open: (String) -> Bool = { identifier in
                AppleHealthIngestTypes.isAvailableOnThisSystem(identifier)
                    && (!onlyAccepted || AppleHealthIngestTypes.serverAccepts(identifier, defaults: defaults))
            }
            var units: [EventSweepUnit] = []
            for identifier in AppleHealthIngestTypes.eventIdentifiers where open(identifier) {
                guard let type = AppleHealthIngestHKTypes.sampleType(for: identifier) else { continue }
                units.append(EventSweepUnit(key: identifier, types: [type], route: .measurement(forwardsDeletes: true)))
            }
            for identifier in AppleHealthIngestTypes.assessmentIdentifiers where open(identifier) {
                guard let type = AppleHealthIngestHKTypes.sampleType(for: identifier) else { continue }
                // No delete route exists for a screener administration.
                units.append(EventSweepUnit(
                    key: identifier,
                    types: [type],
                    route: .measurement(forwardsDeletes: false),
                    module: .mentalHealth
                ))
            }
            let symptoms = AppleHealthSymptomCatalog.identifiers.filter(open).compactMap(AppleHealthIngestHKTypes.sampleType(for:))
            if !symptoms.isEmpty {
                units.append(EventSweepUnit(key: EventSweepUnit.symptomsKey, types: symptoms, route: .symptoms, module: .illness))
            }
            return units
        }

        /// Whether `unit` may be read: no module, or its module is on. Without
        /// a module answer the module units stay unread.
        func moduleAllows(_ unit: EventSweepUnit) async -> Bool {
            guard let module = unit.module else { return true }
            guard let moduleProbe else { return false }
            return await moduleProbe(module)
        }

        // MARK: - Page

        /// Posts one read page on its unit's route, then its deletions where the
        /// route forwards them. A deletion neither sent nor kept holds the page.
        func transmitPage(
            _ page: EventSweepPage,
            of unit: EventSweepUnit,
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            let outcome: HealthSyncPageOutcome
            let deleteDomain: AppleHealthDeleteDomain?
            switch unit.route {
            case .legacyEvent:
                let entries = page.samples.compactMap { ($0 as? HKCategorySample).flatMap(Self.entry(from:)) }
                return await transmit(entries, requiring: lease)
            case let .measurement(forwardsDeletes):
                outcome = await transmit(page.samples.compactMap(AppleHealthIngestHKTypes.measurementEntry(from:)), requiring: lease)
                deleteDomain = forwardsDeletes ? .measurement : nil
            case .symptoms:
                outcome = await transmitSymptoms(
                    page.samples.compactMap { AppleHealthIngestHKTypes.symptomEntry(from: $0) },
                    requiring: lease
                )
                deleteDomain = .symptoms
            }
            guard let deleteDomain, !page.deletedIDs.isEmpty,
                  HealthSyncCursorPolicy.installed.decide(outcome) == .commit else { return outcome }
            if deleteDomain == .symptoms {
                // A queued page must not re-send a symptom deleted since.
                await retry?.pruneQueuedAppleHealthUploads(
                    .uploadAppleHealthSymptoms,
                    removing: Set(page.deletedIDs),
                    ownerUserID: lease.ownerID
                )
            }
            let sender = AppleHealthDeletionSender(
                send: { [uploader] ids, domain in try await uploader.deleteAppleHealthRecords(ids, domain: domain) },
                queue: retry
            )
            guard let held = await sender.forward(page.deletedIDs, to: deleteDomain, requiring: lease) else { return outcome }
            return outcome.holding(held)
        }

        // MARK: - Symptoms

        /// Posts the symptom rows in pages of at most 500 and reports what the
        /// server proved. A row the server refused goes into the skip register
        /// with its reason; a row it did not answer waits in the outbox, one row
        /// per page of at most 500, under a key derived from its records. A
        /// module that is off pauses the page with the cursor held.
        func transmitSymptoms(
            _ entries: [AppleHealthSymptomEntryDTO],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> HealthSyncPageOutcome {
            guard !entries.isEmpty else { return Self.emptyPage }
            var run = SymptomRun()
            let bound = AppleHealthDeleteDomain.maxIDsPerRequest
            for start in stride(from: 0, to: entries.count, by: bound) {
                let chunk = Array(entries[start ..< min(start + bound, entries.count)])
                do {
                    try lease.requireCurrent()
                    let response = try await uploader.uploadSymptoms(chunk)
                    try lease.requireCurrent()
                    defaults.removeObject(forKey: symptomHeldKey)
                    run.absorb(response, chunk: chunk, offset: start)
                } catch let refusal as HealthSyncLeaseRefusal {
                    return Self.refusedPage(refusal, postedCount: entries.count)
                } catch where HealthSampleConsumption.isCancellation(error) {
                    return Self.refusedPage(.cancelled, postedCount: entries.count)
                } catch where HealthSampleConsumption.isUnreachable(error) || AppleHealthDeleteRefusal.isModuleOff(error) {
                    // Offline, backoff, 429, or the module off: hold, never park.
                    run.paused = true
                    run.held.formUnion(start ..< start + chunk.count)
                } catch where HealthKitBatchRejection.classify(error) != .retry {
                    absorbWholeRefusal(error, chunk: chunk, offset: start, into: &run)
                } catch {
                    run.transportThrew = true
                    run.held.formUnion(start ..< start + chunk.count)
                }
            }
            let registered = await registerRefused(run.refused, requiring: lease)
            if !registered { run.held.formUnion(run.refused.map(\.index)) }
            var persisted = false
            let parked = run.held.subtracting(run.refused.map(\.index))
            if !parked.isEmpty, !run.paused, !run.refusedWhole {
                persisted = await persistSymptomRetry(parked.sorted().map { entries[$0] }, requiring: lease)
            }
            var page = HealthSyncPageOutcome(
                postedCount: entries.count,
                entries: entries.indices.map { index in
                    HealthSyncEntryOutcome(
                        index: index,
                        stableIdentity: entries[index].externalId,
                        classification: run.held.contains(index) ? .nonterminal : .terminalAccepted
                    )
                },
                transportThrew: run.transportThrew,
                durableRetryPersisted: persisted && registered,
                durableRetryFailed: !run.held.isEmpty && !run.paused && !persisted,
                leaseIsCurrent: lease.isCurrent,
                wasCancelled: Task.isCancelled
            )
            page.serverUnreachable = run.paused
            return page
        }

        /// A whole-call refusal: a named one goes into the skip register at
        /// once; any other holds for a bounded run of sweeps, then the rows are
        /// registered with the status.
        private func absorbWholeRefusal(
            _ error: Error,
            chunk: [AppleHealthSymptomEntryDTO],
            offset: Int,
            into run: inout SymptomRun
        ) {
            let held = defaults.integer(forKey: symptomHeldKey) + 1
            if case let .refused(reason) = HealthKitBatchRejection.classify(error) {
                run.refuse(chunk, offset: offset, reason: reason)
            } else if held < HealthKitBatchRejection.maxHeldSweeps {
                run.refusedWhole = true
                defaults.set(held, forKey: symptomHeldKey)
                run.held.formUnion(offset ..< offset + chunk.count)
            } else {
                defaults.removeObject(forKey: symptomHeldKey)
                run.refuse(chunk, offset: offset, reason: HealthKitBatchRejection.individuallyRefusedReason(status: Self.status(of: error)))
            }
        }

        private static func status(of error: Error) -> Int {
            if case let .server(status, _, _) = error as? HLError { return status }
            return 400
        }

        /// Writes refused symptoms into the account's skip register. `false`
        /// when the write did not happen; the rows then hold.
        private func registerRefused(
            _ refused: [SymptomRefusal],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> Bool {
            guard !refused.isEmpty else { return true }
            do {
                try await HealthKitSkippedRowRegister.current.record(
                    refused.map { HealthKitSkippedEntry(symptom: $0.entry, reason: $0.reason) },
                    ownerID: lease.ownerID,
                    build: HealthKitSkipRegisterBuild.current
                )
                return true
            } catch {
                HLLog.healthKit.error("symptom refusals could not be registered — page holds")
                return false
            }
        }

        private var symptomHeldKey: String {
            "hl.hkevent.heldRejections." + partitionToken + "." + EventSweepUnit.symptomsKey
        }

        private func persistSymptomRetry(
            _ entries: [AppleHealthSymptomEntryDTO],
            requiring lease: HealthSyncAuthenticatedLease
        ) async -> Bool {
            guard let retry else { return false }
            // One outbox row per page of at most 500: the replay sends a row
            // whole, and the route refuses more.
            let bound = AppleHealthDeleteDomain.maxIDsPerRequest
            for start in stride(from: 0, to: entries.count, by: bound) {
                let chunk = Array(entries[start ..< min(start + bound, entries.count)])
                guard let envelope = HealthSyncRetryEnvelope(
                    ownerID: lease.ownerID,
                    source: lease.source,
                    stableIdentity: "symptoms:" + chunk.map(\.externalId).sorted().joined(separator: "|")
                ) else { return false }
                if await retry.hasPendingHealthKitRetry(idempotencyKey: envelope.idempotencyKey) { continue }
                do {
                    try lease.requireCurrent()
                    try await retry.enqueueAppleHealthSymptoms(
                        chunk,
                        idempotencyKey: envelope.idempotencyKey,
                        requiringCurrentOwner: lease.ownerID
                    )
                    try lease.requireCurrent()
                } catch {
                    HLLog.healthKit.error("symptom durable retry write failed — cursor holds")
                    return false
                }
            }
            return true
        }
    }
#endif
