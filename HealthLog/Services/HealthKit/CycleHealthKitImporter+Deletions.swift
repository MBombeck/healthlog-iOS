import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    // Deletions in Apple Health and the basal body temperature (#181,
    // contract #182 part B §4).
    //
    // A cycle day-log is one row per day under `cycle-hk:<day>`, folded from
    // every foreign sample of that day. A deleted sample comes back as a bare
    // UUID, so ``CycleSampleDayMap`` turns it into its day and type; a day
    // left without any sample is deleted on the server, a day that keeps one
    // gets the deleted type's fields rebuilt
    // (`CycleHealthKitImporter+DayRebuild.swift`). The delete goes out after
    // every queued upload for that day left the outbox, because a late
    // re-post of a deleted day revives it.

    extension CycleHealthKitImporter {
        // MARK: - Writes

        /// The writes of one page, reproductive categories and temperatures alike.
        func buildWrites(fromSamples samples: [HKSample], identifier: String) -> [CycleDayLogWrite] {
            if identifier == CycleBasalTemperature.identifier {
                return buildTemperatureWrites(from: samples.compactMap { $0 as? HKQuantitySample })
            }
            return buildWrites(from: samples.compactMap { $0 as? HKCategorySample }, identifier: identifier)
        }

        /// One write per day with the earliest plausible temperature among
        /// `samples`: the basal temperature is taken on waking, before
        /// anything else. The sweep hands it every sample of the touched days,
        /// not only the page (``temperatureWrites(forPage:)``).
        func buildTemperatureWrites(from samples: [HKQuantitySample]) -> [CycleDayLogWrite] {
            let timeZone = profileTimeZone()
            var earliest: [String: (at: Date, celsius: Double)] = [:]
            for sample in samples {
                guard let celsius = CycleBasalTemperature.celsius(of: sample) else { continue }
                let day = Self.dayKey(start: sample.startDate, end: sample.endDate, timeZone: timeZone)
                if let known = earliest[day], known.at <= sample.startDate { continue }
                earliest[day] = (sample.startDate, celsius)
            }
            return earliest.keys.sorted().compactMap { day in
                guard let reading = earliest[day] else { return nil }
                return CycleDayLogWrite(
                    date: day,
                    basalBodyTempC: reading.celsius,
                    loggedAt: Self.loggedAtFormatter.string(from: reading.at),
                    source: "APPLE_HEALTH",
                    externalId: CycleSampleDayMap.externalID(forDay: day)
                )
            }
        }

        private nonisolated(unsafe) static let loggedAtFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        // MARK: - Sample to day

        /// The (sample, day) pairs of the samples that become part of a
        /// day-log: foreign, mapped, plausible. Exactly the samples
        /// ``buildWrites(fromSamples:identifier:)`` folds in.
        func sampleDayPairs(_ samples: [HKSample], identifier: String) -> [(sample: String, day: String)] {
            let timeZone = profileTimeZone()
            return samples.compactMap { sample in
                guard Self.contributesToDayLog(sample, identifier: identifier) else { return nil }
                return (sample.uuid.uuidString, Self.dayKey(start: sample.startDate, end: sample.endDate, timeZone: timeZone))
            }
        }

        static func contributesToDayLog(_ sample: HKSample, identifier: String) -> Bool {
            if let quantity = sample as? HKQuantitySample {
                return identifier == CycleBasalTemperature.identifier && CycleBasalTemperature.celsius(of: quantity) != nil
            }
            guard let category = sample as? HKCategorySample, !HealthKitSampleOwnership.isOwnEcho(category) else { return false }
            let protection = category.metadata?[CycleHealthKitMapping.sexualActivityProtectionMeta] as? Bool
            if case .dayLog = CycleHealthKitMapping.route(identifier: identifier, value: category.value, protectionUsed: protection) {
                return true
            }
            return false
        }

        /// Adds one page's samples to the map. Synchronous on the actor, so
        /// two interleaved sweeps never lose each other's entries.
        func recordSampleDays(_ samples: [HKSample], identifier: String) {
            let pairs = sampleDayPairs(samples, identifier: identifier)
            guard !pairs.isEmpty else { return }
            var map = sampleDays.load(partitionToken: partitionToken)
            map.record(pairs, identifier: identifier)
            sampleDays.save(map, partitionToken: partitionToken)
        }

        /// Keeps the deleted UUIDs of a page the unseeded map cannot judge
        /// yet. `false` when the map could not be written: the caller then
        /// holds the anchor, so HealthKit reports them again.
        func parkDeletions(_ deletedIDs: [String]) -> Bool {
            guard !deletedIDs.isEmpty else { return true }
            var map = sampleDays.load(partitionToken: partitionToken)
            map.park(deletedIDs)
            return sampleDays.save(map, partitionToken: partitionToken)
        }

        /// `true` once the map knows every cycle sample of this account. An
        /// installation from before 1.7 reads every type once, locally; a
        /// failed read leaves the map unseeded and no deletion is judged.
        func ensureSampleDayMapSeeded() async -> Bool {
            if sampleDays.load(partitionToken: partitionToken).seeded { return true }
            if let running = sampleDaySeed { return await running.value }
            let task = Task { await self.seedSampleDayMap() }
            sampleDaySeed = task
            let seeded = await task.value
            sampleDaySeed = nil
            return seeded
        }

        private func seedSampleDayMap() async -> Bool {
            var pairs: [(identifier: String, pairs: [(sample: String, day: String)])] = []
            for type in Self.readSampleTypes() {
                guard !Task.isCancelled, let samples = try? await allSamples(of: type) else { return false }
                pairs.append((type.identifier, sampleDayPairs(samples, identifier: type.identifier)))
            }
            var map = sampleDays.load(partitionToken: partitionToken)
            for typePairs in pairs {
                map.record(typePairs.pairs, identifier: typePairs.identifier)
            }
            map.seeded = true
            return sampleDays.save(map, partitionToken: partitionToken)
        }

        private func allSamples(of type: HKSampleType) async throws -> [HKSample] {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: nil,
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
        }

        // MARK: - Deletions

        /// Sends the days `deletedIDs` emptied to the delete route, or keeps
        /// them for later (route closed, server out of reach, cycle tracking
        /// off on the server). Never holds the cursor: what cannot go now
        /// waits in ``AppleHealthPendingDeletions``.
        func forwardDeletions(_ deletedIDs: [String], requiring lease: HealthSyncAuthenticatedLease) async {
            var map = sampleDays.load(partitionToken: partitionToken)
            let before = map
            let emptied = deletedIDs.isEmpty && map.pendingDeleted.isEmpty ? [] : map.removeDeleted(deletedIDs)
            // Saved whenever a sample left, also when its day keeps another:
            // otherwise the next deletion of that day would still count it.
            if map != before {
                // A map that cannot be written would forget the deletion.
                guard sampleDays.save(map, partitionToken: partitionToken) else { return }
            }
            await sendEmptiedDays(emptied, requiring: lease)
            await correctTouchedDays(requiring: lease)
        }

        private func sendEmptiedDays(_ emptied: [String], requiring lease: HealthSyncAuthenticatedLease) async {
            let ids = AppleHealthPendingDeletions.toSend(
                emptied,
                .cycleDayLog,
                ownerID: lease.ownerID,
                routeOpen: AppleHealthIngestCapability.isAvailable(.appleHealthDeletes, defaults: defaults),
                defaults: defaults
            )
            guard !ids.isEmpty, lease.isCurrent else { return }
            // Contract: a queued day-log for a deleted day would revive it.
            _ = await retryQueue?()?.pruneQueuedAppleHealthUploads(.logCycleDayLog, removing: Set(ids), ownerUserID: lease.ownerID)
            do {
                for start in stride(from: 0, to: ids.count, by: AppleHealthDeleteDomain.maxIDsPerRequest) {
                    let end = min(start + AppleHealthDeleteDomain.maxIDsPerRequest, ids.count)
                    try lease.requireCurrent()
                    try await repo.deleteAppleHealthDayLogs(Array(ids[start ..< end]))
                }
                AppleHealthPendingDeletions.clear(.cycleDayLog, ownerID: lease.ownerID, defaults: defaults)
            } catch let error where !Self.isModuleOff(error) && AppleHealthDeleteRefusal.isFinal(error) {
                // The server read the request and said no for good.
                AppleHealthPendingDeletions.clear(.cycleDayLog, ownerID: lease.ownerID, defaults: defaults)
            } catch {
                AppleHealthPendingDeletions.keep(ids, .cycleDayLog, ownerID: lease.ownerID, defaults: defaults)
                HLLog.healthKit.info("cycle HK deletions kept for a later pass")
            }
        }
    }

    extension CycleRepository {
        /// `DELETE /api/cycle/day-logs/by-external-ids` (server 1.48.0): soft
        /// delete of this account's Apple Health day-logs. 403
        /// `cycle.disabled` while cycle tracking is off.
        func deleteAppleHealthDayLogs(_ externalIDs: [String]) async throws {
            guard !externalIDs.isEmpty else { return }
            let req: APIRequest<EmptyResponse> = try .delete(
                AppleHealthDeleteDomain.cycleDayLog.path,
                body: ExternalIDBatch(externalIds: externalIDs)
            )
            _ = try await api.send(req)
        }
    }

#endif
