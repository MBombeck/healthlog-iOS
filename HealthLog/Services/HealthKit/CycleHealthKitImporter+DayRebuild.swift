import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    // A day read whole from Apple Health (#181, contract #182 part B §4).
    //
    // Two things need every sample of a day rather than the page an anchored
    // query handed in. The basal temperature is the day's earliest reading,
    // and a later page may bring a later reading of a day an earlier page
    // already sent. And a day that keeps a sample after another was deleted
    // in Health must lose what the deleted one wrote: the server's upsert
    // (`upsertCycleDayLog`, release/v1.49.0) merges field by field and its
    // create body takes no `null`, and a soft-deleted row it revives keeps its
    // old values, so neither a re-post nor a delete and re-post clears a
    // field. The day is rebuilt for the deleted sample's type from what Health
    // still holds and sent as a `PATCH`, whose body takes an explicit `null`.

    extension CycleHealthKitImporter {
        /// Days rebuilt per pass; the rest wait in the map for the next one.
        static let correctionsPerPass = 20

        // MARK: - Page writes

        /// The writes of one page. The temperature reads its days whole; a
        /// symptom write carries the day's whole symptom list.
        func pageWrites(fromSamples samples: [HKSample], identifier: String) async throws -> [CycleDayLogWrite] {
            if identifier == CycleBasalTemperature.identifier {
                return try await temperatureWrites(forPage: samples.compactMap { $0 as? HKQuantitySample })
            }
            let writes = buildWrites(fromSamples: samples, identifier: identifier)
            guard CycleHealthKitMapping.symptomKeyByIdentifier[identifier] != nil else { return writes }
            return try await withWholeDaySymptoms(writes, identifier: identifier)
        }

        /// The server replaces a day's symptom links with the list a write
        /// carries (`replaceSymptomLinks`, release/v1.49.0), whatever their
        /// source. A symptom type's sweep alone would therefore wipe the
        /// day's other symptoms, from Health and typed in by hand. So each
        /// write goes out with the day's list as the server holds it, the
        /// other symptom types Health holds for that day (a sibling sweep may
        /// still wait in the outbox) and this type's own symptom last, which
        /// wins for its key. A day the server cannot be asked about holds the
        /// page (the anchor stays) rather than send a short list.
        private func withWholeDaySymptoms(_ writes: [CycleDayLogWrite], identifier: String) async throws -> [CycleDayLogWrite] {
            let days = Set(writes.filter { $0.symptoms?.isEmpty == false }.map(\.date))
            guard !days.isEmpty else { return writes }
            let timeZone = profileTimeZone()
            var fromHealth: [String: [CycleSymptomDTO]] = [:]
            for type in Self.readCategoryTypes() where type.identifier != identifier
                && CycleHealthKitMapping.symptomKeyByIdentifier[type.identifier] != nil
            {
                let samples = try await samples(of: type, onDays: days, timeZone: timeZone)
                for write in buildWrites(fromSamples: samples, identifier: type.identifier) {
                    fromHealth[write.date, default: []] += write.symptoms ?? []
                }
            }
            var merged: [CycleDayLogWrite] = []
            for var write in writes {
                if let own = write.symptoms, !own.isEmpty {
                    let stored = try await repo.dayLog(date: write.date)?.symptoms ?? []
                    write.symptoms = Self.union(stored, fromHealth[write.date] ?? [], own)
                }
                merged.append(write)
            }
            return merged
        }

        /// The lists in order, one entry per key, a later list winning.
        static func union(_ lists: [CycleSymptomDTO]...) -> [CycleSymptomDTO] {
            var result: [CycleSymptomDTO] = []
            for symptom in lists.joined() {
                if let index = result.firstIndex(where: { $0.key == symptom.key }) {
                    result[index] = symptom
                } else {
                    result.append(symptom)
                }
            }
            return result
        }

        /// One write per day the page touches, with the earliest plausible
        /// temperature of that whole day in Health.
        func temperatureWrites(forPage page: [HKQuantitySample]) async throws -> [CycleDayLogWrite] {
            let timeZone = profileTimeZone()
            let days = Set(page.filter { CycleBasalTemperature.celsius(of: $0) != nil }.map {
                Self.dayKey(start: $0.startDate, end: $0.endDate, timeZone: timeZone)
            })
            guard !days.isEmpty, let type = CycleBasalTemperature.sampleType else { return [] }
            let read = try await samples(of: type, onDays: days, timeZone: timeZone).compactMap { $0 as? HKQuantitySample }
            let known = Set(read.map(\.uuid))
            let all = read + page.filter { !known.contains($0.uuid) }
            return buildTemperatureWrites(from: all).filter { days.contains($0.date) }
        }

        /// Every sample of `type` whose day is one of `days`, in one read. A
        /// whole-day sample is keyed by its midpoint, so the read reaches half
        /// a day past either end.
        func samples(of type: HKSampleType, onDays days: Set<String>, timeZone: TimeZone) async throws -> [HKSample] {
            let starts = days.compactMap { ProfileDay.startOfDay(forKey: $0, timeZone: timeZone) }
            guard let first = starts.min(), let last = starts.max() else { return [] }
            let from = first.addingTimeInterval(-14 * 3600)
            let to = last.addingTimeInterval(38 * 3600)
            let read: [HKSample] = if let rangeSamples {
                try await rangeSamples(type, from, to)
            } else {
                try await healthKitSamples(of: type, from: from, to: to)
            }
            return read.filter { days.contains(Self.dayKey(start: $0.startDate, end: $0.endDate, timeZone: timeZone)) }
        }

        private func healthKitSamples(of type: HKSampleType, from: Date, to: Date) async throws -> [HKSample] {
            try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate),
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

        // MARK: - Days that kept a sample

        /// Rebuilds the days in ``CycleSampleDayMap/pendingCorrections``. A day
        /// whose correction could not go out stays there for the next pass.
        func correctTouchedDays(requiring lease: HealthSyncAuthenticatedLease) async {
            let pending = sampleDays.load(partitionToken: partitionToken).pendingCorrections
            for day in pending.keys.sorted().prefix(Self.correctionsPerPass) {
                guard lease.isCurrent, !Task.isCancelled, let types = pending[day] else { return }
                guard await correct(day: day, types: types, requiring: lease) else { return }
                // Read again: a sweep of another type may have written meanwhile.
                var map = sampleDays.load(partitionToken: partitionToken)
                let left = (map.pendingCorrections[day] ?? []).subtracting(types)
                map.pendingCorrections[day] = left.isEmpty ? nil : left
                guard sampleDays.save(map, partitionToken: partitionToken) else { return }
            }
        }

        /// `true` once the day is settled: corrected, or nothing to correct.
        private func correct(day: String, types: Set<String>, requiring lease: HealthSyncAuthenticatedLease) async -> Bool {
            let timeZone = profileTimeZone()
            let wanted = Self.readSampleTypes().filter {
                types.contains(CycleSampleDayMap.allTypes) || types.contains($0.identifier)
            }
            do {
                var rebuilt: [String: CycleDayLogWrite] = [:]
                for type in wanted {
                    let samples = try await samples(of: type, onDays: [day], timeZone: timeZone)
                    rebuilt[type.identifier] = buildWrites(fromSamples: samples, identifier: type.identifier).first { $0.date == day }
                }
                try lease.requireCurrent()
                guard let row = try await repo.dayLog(date: day), !row.id.isEmpty else { return true }
                try lease.requireCurrent()
                let patch = Self.correctionPatch(types: Set(wanted.map(\.identifier)), rebuilt: rebuilt, current: row)
                try await repo.patchAppleHealthDayLog(id: row.id, patch)
                return true
            } catch let error where !Self.isModuleOff(error) && AppleHealthDeleteRefusal.isFinal(error) {
                // The row is gone or the server refused for good.
                return true
            } catch {
                HLLog.healthKit.info("cycle HK day correction kept for a later pass")
                return false
            }
        }

        /// The `PATCH` that makes the day what Health still holds for
        /// `types`: a rebuilt value is set, a field no remaining sample of its
        /// type writes is cleared. Fields of other types, the manual ones and
        /// the note stay as they are. Symptoms are one list on the server, so
        /// the list goes back whole, without the deleted type's symptom
        /// unless a remaining sample still has it.
        static func correctionPatch(types: Set<String>, rebuilt: [String: CycleDayLogWrite], current: CycleDayLogDTO) -> CycleDayLogPatch {
            var patch = CycleDayLogPatch()
            var symptoms = current.symptoms
            var symptomsTouched = false
            for identifier in types.sorted() {
                let write = rebuilt[identifier]
                if let key = CycleHealthKitMapping.symptomKeyByIdentifier[identifier] {
                    symptoms.removeAll { $0.key == key }
                    if let kept = write?.symptoms?.first(where: { $0.key == key }) { symptoms.append(kept) }
                    symptomsTouched = true
                    continue
                }
                apply(identifier, write, to: &patch)
            }
            if symptomsTouched { patch.symptoms = .set(symptoms) }
            return patch
        }

        private static func apply(_ identifier: String, _ write: CycleDayLogWrite?, to patch: inout CycleDayLogPatch) {
            switch identifier {
            case CycleHealthKitMapping.menstrualFlow: patch.flow = field(write?.flow)
            case CycleHealthKitMapping.intermenstrualBleeding: patch.intermenstrualBleeding = write?.intermenstrualBleeding ?? false
            case CycleHealthKitMapping.cervicalMucus: patch.cervicalMucus = field(write?.cervicalMucus)
            case CycleHealthKitMapping.ovulationTest: patch.ovulationTest = field(write?.ovulationTest)
            case CycleHealthKitMapping.sexualActivity:
                patch.sexualActivity = write?.sexualActivity ?? false
                patch.protectedSex = field(write?.protectedSex)
            case CycleHealthKitMapping.pregnancyTest: patch.pregnancyTest = field(write?.pregnancyTest)
            case CycleHealthKitMapping.progesteroneTest: patch.progesteroneTest = field(write?.progesteroneTest)
            case CycleHealthKitMapping.contraceptive: patch.contraceptive = field(write?.contraceptive)
            case CycleBasalTemperature.identifier: patch.basalBodyTempC = field(write?.basalBodyTempC)
            default: break
            }
        }

        private static func field<Value>(_ value: Value?) -> RecordPatchField<Value> {
            value.map { .set($0) } ?? .clear
        }
    }

    extension CycleRepository {
        /// `PATCH /api/cycle/day-logs/{id}` for a day the import rebuilt. Sent
        /// directly, not through the outbox: the correction waits in the
        /// account's own map until the server took it.
        func patchAppleHealthDayLog(id: String, _ patch: CycleDayLogPatch) async throws {
            let req: APIRequest<EmptyResponse> = try .patch("/api/cycle/day-logs/\(id)", body: patch)
            _ = try await api.send(req)
        }
    }

#endif
