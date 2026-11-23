import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping file_length large_tuple

#if canImport(HealthKit)

    private func ingest17Body(_ req: URLRequest) -> Data? {
        guard let stream = req.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.ingest-17.\(UUID().uuidString)")!
    }

    /// The sixteen quantity types 1.7 adds: who opens them, how they go on
    /// the wire, and what an older server and an existing installation see.
    @Suite("Apple Health 1.7: new quantity types")
    struct AppleHealthIngestQuantityTypeTests {
        private let respiratory = AppleHealthIngestQuantityTypes.respiratoryIdentifiers
        private let gatedByList = AppleHealthIngestQuantityTypes.effortIdentifiers + AppleHealthIngestQuantityTypes.trainingIdentifiers

        @Test("every new type resolves on this system, is in the registry and in the first sheet")
        func registryAndReadSet() {
            let read = Set(HealthKitService.defaultReadTypes.map(\.identifier))
            for identifier in AppleHealthIngestQuantityTypes.allIdentifiers {
                #expect(AppleHealthIngestQuantityTypes.sampleType(for: identifier) != nil, "\(identifier)")
                let dayTotal = AppleHealthIngestQuantityTypes.dayTotalIdentifiers.contains(identifier)
                #expect(HealthLogSampleTypeRegistry.contains(identifier) == !dayTotal, "per sample or day total: \(identifier)")
                #expect(HealthKitCumulativeTypeConfig.cumulativeIdentifiers.contains(identifier) == dayTotal, "\(identifier)")
                #expect(read.contains(identifier), "\(identifier)")
                #expect(AppleHealthIngestHKTypes.sampleType(for: identifier) != nil, "card resolves \(identifier)")
                #expect(AppleHealthIngestTypes.allIdentifiers.contains(identifier), "announced \(identifier)")
                #expect(HealthAccessTypeNaming.localizationKey(for: identifier) != nil, "named \(identifier)")
            }
            #expect(AppleHealthIngestQuantityTypes.allIdentifiers.count == 16)
        }

        @Test("old server: nothing new is collected; 1.48.2 opens insulin and breathing only")
        func olderServerSeesNothing() {
            let d = isolatedDefaults()
            let all = AppleHealthIngestQuantityTypes.allIdentifiers
            let gate = { (id: String) in HealthKitServerTypeGate.serverAccepts(id, defaults: d) }
            #expect(AppOwnedHealthCollectionCoordinator.serverCollectable(all, serverAccepts: gate).isEmpty, "never probed")
            KnownServerVersion.record(ServerVersionInfo(version: "1.48.1"), defaults: d)
            #expect(AppOwnedHealthCollectionCoordinator.serverCollectable(all, serverAccepts: gate).isEmpty)
            KnownServerVersion.record(ServerVersionInfo(version: "1.48.2"), defaults: d)
            #expect(AppOwnedHealthCollectionCoordinator.serverCollectable(all, serverAccepts: gate) == respiratory)
            KnownServerVersion.record(ServerVersionInfo(version: "1.99.0"), defaults: d)
            for identifier in gatedByList {
                #expect(!gate(identifier), "\(identifier) waits for acceptedTypes, never a version")
            }
        }

        @Test("the capability `apple-health.types-2026-11` opens the eight training types, not the effort ones")
        func trainingCapability() {
            let d = isolatedDefaults()
            KnownServerVersion.record(
                ServerVersionInfo(version: "1.49.0", features: [AppleHealthIngestQuantityTypes.trainingCapability]),
                defaults: d
            )
            HealthKitAcceptedTypes.record(["HKQuantityTypeIdentifierBodyMass"], defaults: d)
            let open = AppOwnedHealthCollectionCoordinator.serverCollectable(
                AppleHealthIngestQuantityTypes.allIdentifiers
            ) { HealthKitServerTypeGate.serverAccepts($0, defaults: d) }
            #expect(open == AppleHealthIngestQuantityTypes.trainingIdentifiers)
        }

        @Test("effort opens by `apple-health.effort-scores`, with `acceptedTypes` as the fallback")
        func effortCapability() {
            let d = isolatedDefaults()
            let gate = { (id: String) in HealthKitServerTypeGate.serverAccepts(id, defaults: d) }
            let effort = AppleHealthIngestQuantityTypes.effortIdentifiers
            KnownServerVersion.record(ServerVersionInfo(version: "1.49.0", features: ["apple-health.types-2026-11"]), defaults: d)
            #expect(AppOwnedHealthCollectionCoordinator.serverCollectable(effort, serverAccepts: gate).isEmpty)
            KnownServerVersion.record(
                ServerVersionInfo(version: "1.49.0", features: [AppleHealthIngestQuantityTypes.effortCapability]),
                defaults: d
            )
            #expect(AppOwnedHealthCollectionCoordinator.serverCollectable(effort, serverAccepts: gate) == effort)
            KnownServerVersion.record(ServerVersionInfo(version: "1.49.0"), defaults: d)
            HealthKitAcceptedTypes.record([AppleHealthIngestQuantityTypes.physicalEffort], defaults: d)
            #expect(AppOwnedHealthCollectionCoordinator
                .serverCollectable(effort, serverAccepts: gate) == [AppleHealthIngestQuantityTypes.physicalEffort])
        }

        @Test("cycling and rowing distance are day totals behind the training capability, with their own history one-shot")
        func distancesAreDayTotals() {
            let d = isolatedDefaults()
            let distances = Set(AppleHealthIngestQuantityTypes.dayTotalIdentifiers)
            let configs = HealthKitCumulativeTypeConfig.defaults.filter { distances.contains($0.identifier) }
            #expect(configs.map(\.wireUnit) == ["m", "m"])
            #expect(AppContainer.lateDailyStatsTypes.contains(AppleHealthIngestQuantityTypes.distanceCycling))
            #expect(AppContainer.lateDailyStatsTypes.contains(AppleHealthIngestQuantityTypes.distanceRowing))
            let gate = { (id: String) in HealthKitServerTypeGate.serverAccepts(id, defaults: d) }
            KnownServerVersion.record(ServerVersionInfo(version: "1.48.2"), defaults: d)
            #expect(HealthKitCumulativeTypeConfig.serverCollectable(serverAccepts: gate).allSatisfy { !distances.contains($0.identifier) })
            KnownServerVersion.record(
                ServerVersionInfo(version: "1.49.0", features: [AppleHealthIngestQuantityTypes.trainingCapability]),
                defaults: d
            )
            #expect(Set(HealthKitCumulativeTypeConfig.serverCollectable(serverAccepts: gate).map(\.identifier)).isSuperset(of: distances))
            let collected = AppOwnedHealthCollectionCoordinator.serverCollectable(
                AppOwnedHealthCollectionCoordinator.collectedTypeIdentifiers, serverAccepts: gate
            )
            #expect(Set(collected).isDisjoint(with: distances), "never also per sample")
        }

        @Test("`acceptedTypes` decides alone once the server publishes it")
        func acceptedTypesDecides() {
            let d = isolatedDefaults()
            KnownServerVersion.record(ServerVersionInfo(version: "1.49.0"), defaults: d)
            HealthKitAcceptedTypes.record(
                [AppleHealthIngestQuantityTypes.workoutEffortScore, AppleHealthIngestQuantityTypes.distanceCycling],
                defaults: d
            )
            let open = AppOwnedHealthCollectionCoordinator.serverCollectable(
                AppleHealthIngestQuantityTypes.allIdentifiers
            ) { HealthKitServerTypeGate.serverAccepts($0, defaults: d) }
            #expect(open == [AppleHealthIngestQuantityTypes.workoutEffortScore, AppleHealthIngestQuantityTypes.distanceCycling])
        }

        @Test(
            "wire rows carry the server's unit and the raw value",
            arguments: [
                (AppleHealthIngestQuantityTypes.insulinDelivery, HKUnit.internationalUnit(), 4.5, "IU", 4.5),
                (AppleHealthIngestQuantityTypes.inhalerUsage, HKUnit.count(), 2, "count", 2),
                (AppleHealthIngestQuantityTypes.forcedExpiratoryVolume1, HKUnit.liter(), 3.1, "L", 3.1),
                (AppleHealthIngestQuantityTypes.forcedVitalCapacity, HKUnit.literUnit(with: .milli), 4200, "L", 4.2),
                (AppleHealthIngestQuantityTypes.peakExpiratoryFlowRate, HKUnit.liter().unitDivided(by: .minute()), 480, "L/min", 480),
                (AppleHealthIngestQuantityTypes.workoutEffortScore, HKUnit.appleEffortScore(), 7, "count", 7),
                (AppleHealthIngestQuantityTypes.estimatedWorkoutEffortScore, HKUnit.appleEffortScore(), 6, "count", 6),
                (
                    AppleHealthIngestQuantityTypes.physicalEffort,
                    HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour())),
                    8.2, "kcal/(hr*kg)", 8.2
                ),
                (AppleHealthIngestQuantityTypes.distanceCycling, HKUnit.meterUnit(with: .kilo), 12.5, "m", 12500),
                (AppleHealthIngestQuantityTypes.runningSpeed, HKUnit.meter().unitDivided(by: .second()), 3.2, "m/s", 3.2),
                (AppleHealthIngestQuantityTypes.runningPower, HKUnit.watt(), 250, "W", 250),
                (AppleHealthIngestQuantityTypes.runningGroundContactTime, HKUnit.secondUnit(with: .milli), 240, "ms", 240),
                (AppleHealthIngestQuantityTypes.runningVerticalOscillation, HKUnit.meterUnit(with: .centi), 8.4, "cm", 8.4),
                (AppleHealthIngestQuantityTypes.runningStrideLength, HKUnit.meter(), 1.2, "m", 1.2),
                (AppleHealthIngestQuantityTypes.distanceRowing, HKUnit.meter(), 2000, "m", 2000),
                (AppleHealthIngestQuantityTypes.rowingSpeed, HKUnit.meter().unitDivided(by: .second()), 4, "m/s", 4)
            ] as [(String, HKUnit, Double, String, Double)]
        )
        func wireRow(identifier: String, unit: HKUnit, value: Double, wire: String, expected: Double) throws {
            let type = try #require(HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)))
            let start = Date(timeIntervalSince1970: 1_790_000_000)
            // Insulin delivery needs its reason (basal or bolus) to exist at all.
            let metadata: [String: Any]? = identifier == AppleHealthIngestQuantityTypes.insulinDelivery
                ? [HKMetadataKeyInsulinDeliveryReason: HKInsulinDeliveryReason.bolus.rawValue] : nil
            let sample = HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: start,
                end: start.addingTimeInterval(60),
                metadata: metadata
            )
            let entries = HealthKitWireConverter.entries(from: sample)
            #expect(entries.count == 1)
            #expect(entries.first?.hkIdentifier == identifier)
            #expect(entries.first?.unit == wire)
            #expect(abs((entries.first?.value ?? .nan) - expected) < 0.0001)
            #expect(entries.first?.externalId == sample.uuid.uuidString)
        }

        @Test("Sync Diagnostics shows the new groups and their state")
        func statusRows() {
            let d = isolatedDefaults()
            let state = { (group: AppleHealthIngestStatusRow.Group) in
                AppleHealthIngestStatusRow.current(defaults: d).first { $0.group == group }?.state
            }
            #expect(state(.insulinAndBreathing) == .waitingForServer)
            #expect(state(.effort) == .waitingForServer)
            #expect(state(.training) == .waitingForServer)
            #expect(state(.readingTimeZone) == .waitingForServer)
            #expect(state(.basalTemperature) == .areaOff)
            KnownServerVersion.record(ServerVersionInfo(version: "1.48.2"), defaults: d)
            #expect(state(.insulinAndBreathing) == .active)
            #expect(state(.effort) == .waitingForServer)
            KnownServerVersion.record(
                ServerVersionInfo(version: "1.49.0", features: [HealthKitReadingTimeZone.capability]),
                defaults: d
            )
            #expect(state(.readingTimeZone) == .active)
            CycleBasalTemperature.recordCycleImport(active: true, defaults: d)
            #expect(state(.basalTemperature) == .active)
            #expect(AppleHealthIngestTypes.serverAccepts(CycleBasalTemperature.identifier, defaults: d))
            CycleBasalTemperature.recordCycleImport(active: false, defaults: d)
            #expect(!AppleHealthIngestTypes.serverAccepts(CycleBasalTemperature.identifier, defaults: d), "no card while cycle is off")
        }
    }

    /// `timeZone` on batch rows (#181, #191), behind the capability
    /// `measurement.reading-timezone` on `GET /api/version`.
    @Suite("Apple Health 1.7: time zone per reading", .serialized)
    struct AppleHealthReadingTimeZoneTests {
        @Test("`/api/version` features decode as a list of strings; an older answer has none")
        func capabilitiesDecode() throws {
            let decode = { (json: String) throws -> ServerVersionInfo in
                try JSONDecoder().decode(ServerVersionInfo.self, from: Data(json.utf8))
            }
            let list = try decode(#"{"version":"1.49.0","features":["measurement.reading-timezone","apple-health.types-2026-11"]}"#)
            #expect(list.features == ["measurement.reading-timezone", "apple-health.types-2026-11"])
            let other = try decode(#"{"version":"1.49.0","features":{"measurement.reading-timezone":true}}"#)
            #expect(other.features.isEmpty, "features is a list of strings; another shape reads as none")
            let old = try decode(#"{"version":"1.48.2","buildSha":"abc","builtAt":null}"#)
            #expect(old.features.isEmpty && old.buildSha == "abc")

            let d = isolatedDefaults()
            KnownServerVersion.record(list, defaults: d)
            #expect(HealthKitReadingTimeZone.isSent(defaults: d))
            KnownServerVersion.record(old, defaults: d)
            #expect(!HealthKitReadingTimeZone.isSent(defaults: d), "a newer answer without the capability closes it")
            KnownServerVersion.record(list, defaults: d)
            HealthKitServerTypeGate.forget(defaults: d)
            #expect(!HealthKitReadingTimeZone.isSent(defaults: d), "another server: forgotten")
        }

        @Test("metadata zone wins; an abbreviation, an offset or a broken name falls back to the device zone")
        func zoneChoice() throws {
            let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
            #expect(HealthKitReadingTimeZone.identifier(metadataValue: "Asia/Tokyo", fallback: berlin) == "Asia/Tokyo")
            #expect(HealthKitReadingTimeZone.identifier(metadataValue: nil, fallback: berlin) == "Europe/Berlin")
            #expect(HealthKitReadingTimeZone.identifier(metadataValue: "Not/AZone", fallback: berlin) == "Europe/Berlin")
            #expect(HealthKitReadingTimeZone.identifier(metadataValue: 42, fallback: berlin) == "Europe/Berlin")
            #expect(HealthKitReadingTimeZone.identifier(metadataValue: "CET", fallback: berlin) == "Europe/Berlin")
            #expect(HealthKitReadingTimeZone.identifier(metadataValue: "GMT+0200", fallback: berlin) == "Europe/Berlin")
            let offset = try #require(TimeZone(secondsFromGMT: 7200))
            #expect(HealthKitReadingTimeZone.identifier(metadataValue: nil, fallback: offset) == nil, "no zone rather than an offset")
            #expect(HealthKitReadingTimeZone.validated(String(repeating: "A/", count: 40)) == nil)
        }

        @Test("the device zone stands in only for a reading of the last 48 hours; an older one goes without")
        func deviceZoneOnlyLive() throws {
            let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
            let now = Date(timeIntervalSince1970: 1_795_000_000)
            let recent = now.addingTimeInterval(-47 * 3600)
            let old = now.addingTimeInterval(-90 * 86400)
            #expect(HealthKitReadingTimeZone
                .identifier(metadataValue: nil, readingEnd: recent, now: now, fallback: berlin) == "Europe/Berlin")
            #expect(HealthKitReadingTimeZone.identifier(metadataValue: nil, readingEnd: old, now: now, fallback: berlin) == nil)
            #expect(
                HealthKitReadingTimeZone
                    .identifier(metadataValue: "Asia/Tokyo", readingEnd: old, now: now, fallback: berlin) == "Asia/Tokyo",
                "a zone the reading carries holds at any age"
            )

            let d = isolatedDefaults()
            KnownServerVersion.record(
                ServerVersionInfo(version: "1.49.0", features: [HealthKitReadingTimeZone.capability]),
                defaults: d
            )
            let sample = HKQuantitySample(
                type: HKQuantityType(.bodyMass),
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 80),
                start: old,
                end: old
            )
            let rows = HealthKitWireConverter.unstampedEntries(from: sample)
            #expect(HealthKitReadingTimeZone.stamp(rows, from: sample, defaults: d, fallback: berlin, now: now).first?.timeZone == nil)
            #expect(
                HealthKitReadingTimeZone.stamp(rows, from: sample, defaults: d, fallback: berlin, now: old.addingTimeInterval(3600))
                    .first?.timeZone == "Europe/Berlin"
            )
        }

        @Test("a `stats:` day total carries the zone it was summed in, only with the capability")
        func statsRowZone() {
            let d = isolatedDefaults()
            let row = HealthKitBatchEntryDTO(
                hkIdentifier: "HKQuantityTypeIdentifierStepCount",
                value: 9000,
                unit: "steps",
                startDate: Date(timeIntervalSince1970: 0),
                endDate: Date(timeIntervalSince1970: 0),
                externalId: "stats:HKQuantityTypeIdentifierStepCount:2026-11-21"
            )
            #expect(HealthKitReadingTimeZone.stamp(row, dayZone: "Europe/Berlin", defaults: d).timeZone == nil)
            KnownServerVersion.record(ServerVersionInfo(version: "1.49.0", features: [HealthKitReadingTimeZone.capability]), defaults: d)
            #expect(HealthKitReadingTimeZone.stamp(row, dayZone: "Europe/Berlin", defaults: d).timeZone == "Europe/Berlin")
            #expect(HealthKitReadingTimeZone.stamp(row, dayZone: "GMT+0100", defaults: d).timeZone == nil)
            let a = HealthKitDailyStatRow(hkIdentifier: "x", dayStart: .distantPast, dayKey: "k", value: 1, unit: "u")
            let b = HealthKitDailyStatRow(
                hkIdentifier: "x", dayStart: .distantPast, dayKey: "k", value: 1, unit: "u", timeZoneIdentifier: "Europe/Berlin"
            )
            #expect(a == b, "the zone is not part of a row's identity")
        }

        @Test("rows carry the zone only while the server reports the flag")
        func stampedOnlyWithFlag() {
            let d = isolatedDefaults()
            let type = HKQuantityType(.bodyMass)
            let start = Date(timeIntervalSince1970: 1_790_000_000)
            let sample = HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 80),
                start: start,
                end: start,
                metadata: [HKMetadataKeyTimeZone: "America/New_York"]
            )
            let rows = HealthKitWireConverter.unstampedEntries(from: sample)
            #expect(HealthKitReadingTimeZone.stamp(rows, from: sample, defaults: d).first?.timeZone == nil, "old server")
            KnownServerVersion.record(ServerVersionInfo(version: "1.49.0"), defaults: d)
            #expect(HealthKitReadingTimeZone.stamp(rows, from: sample, defaults: d).first?.timeZone == nil, "version alone is not enough")
            KnownServerVersion.record(
                ServerVersionInfo(version: "1.49.0", features: [HealthKitReadingTimeZone.capability]),
                defaults: d
            )
            #expect(HealthKitReadingTimeZone.stamp(rows, from: sample, defaults: d).first?.timeZone == "America/New_York")
        }

        @Test("a row without a zone encodes without the key; a 1.6 outbox page still decodes")
        func wireShape() throws {
            let row = HealthKitBatchEntryDTO(
                hkIdentifier: "HKQuantityTypeIdentifierBodyMass",
                value: 80,
                unit: "kg",
                startDate: Date(timeIntervalSince1970: 0),
                endDate: Date(timeIntervalSince1970: 0),
                externalId: "A"
            )
            let plain = try #require(String(data: JSONEncoder().encode(row), encoding: .utf8))
            #expect(!plain.contains("timeZone"))
            let zoned = try #require(String(data: JSONEncoder().encode(row.withTimeZone("Europe/Berlin")), encoding: .utf8))
            #expect(zoned.contains(#""timeZone":"Europe\/Berlin""#))
            #expect(row.withTimeZone("Europe/Berlin").withServerWireName().timeZone == "Europe/Berlin")
            let legacy = Data(
                #"{"entries":[{"hkIdentifier":"HKQuantityTypeIdentifierBodyMass","value":80,"unit":"kg","startDate":0,"endDate":0,"externalId":"A"}]}"#
                    .utf8
            )
            let decoded = try JSONDecoder().decode(HealthKitBatchPayload.self, from: legacy)
            #expect(decoded.entries.first?.timeZone == nil)
        }
    }

    /// Deleted cycle samples find their day, and only an emptied day goes.
    @Suite("Apple Health 1.7: cycle sample to day")
    struct CycleSampleDayMapTests {
        @Test("an edit keeps the day; deleting the last sample empties it; unknown ids change nothing")
        func dayResolution() {
            var map = CycleSampleDayMap()
            map.record([("flow-1", "2026-11-01"), ("symptom-1", "2026-11-01"), ("flow-2", "2026-11-02")])
            #expect(map.removeDeleted(["flow-1"]).isEmpty, "the symptom keeps the day")
            #expect(map.removeDeleted(["unknown"]).isEmpty)
            #expect(map.removeDeleted(["symptom-1", "flow-2"]) == ["cycle-hk:2026-11-01", "cycle-hk:2026-11-02"])
            #expect(map.dayBySample.isEmpty)
        }

        @Test("a deletion on a day that keeps a sample asks for that type's fields to be rebuilt")
        func keptDayAsksForCorrection() throws {
            var map = CycleSampleDayMap()
            map.record([("flow-1", "2026-11-01")], identifier: CycleHealthKitMapping.menstrualFlow)
            map.record([("cramps-1", "2026-11-01")], identifier: "HKCategoryTypeIdentifierAbdominalCramps")
            map.record([("legacy", "2026-11-03"), ("legacy-2", "2026-11-03")])
            #expect(map.removeDeleted(["flow-1"]).isEmpty)
            #expect(map.pendingCorrections == ["2026-11-01": [CycleHealthKitMapping.menstrualFlow]])
            #expect(map.removeDeleted(["legacy"]).isEmpty)
            #expect(map.pendingCorrections["2026-11-03"] == [CycleSampleDayMap.allTypes], "a sample of unknown type rebuilds the whole day")
            #expect(map.removeDeleted(["cramps-1"]) == ["cycle-hk:2026-11-01"])
            #expect(map.pendingCorrections["2026-11-01"] == nil, "an emptied day is deleted, not rebuilt")

            // A map written before the types were kept still reads, seeded.
            let old = Data(#"{"version":1,"seeded":true,"dayBySample":{"a":"2026-11-05"}}"#.utf8)
            let decoded = try JSONDecoder().decode(CycleSampleDayMap.self, from: old)
            #expect(decoded.seeded && decoded.dayBySample == ["a": "2026-11-05"] && decoded.typeBySample.isEmpty)
        }

        @Test("deletions the unseeded map could not judge wait and are judged once it can")
        func parkedDeletionsAreJudgedLater() {
            var map = CycleSampleDayMap()
            map.record([("a", "2026-11-06")], identifier: CycleHealthKitMapping.menstrualFlow)
            map.park(["a", "a", "unknown"])
            #expect(map.pendingDeleted == ["a", "unknown"])
            #expect(map.removeDeleted([]) == ["cycle-hk:2026-11-06"])
            #expect(map.pendingDeleted.isEmpty)
        }

        @Test("the rebuild clears what no remaining sample writes and keeps other fields")
        func correctionPatch() throws {
            let row = try JSONDecoder().decode(
                CycleDayLogDTO.self,
                from: Data(#"{"id":"r1","date":"2026-11-01","flow":"HEAVY","symptoms":[{"key":"cramps","severity":2},{"key":"headache"}]}"#
                    .utf8)
            )
            let cramps = "HKCategoryTypeIdentifierAbdominalCramps"
            let patch = CycleHealthKitImporter.correctionPatch(
                types: [CycleHealthKitMapping.menstrualFlow, cramps],
                rebuilt: [:],
                current: row
            )
            let json = try #require(String(data: JSONEncoder().encode(patch), encoding: .utf8))
            #expect(json.contains(#""flow":null"#), "the deleted flow goes")
            #expect(patch.symptoms == .set([CycleSymptomDTO(key: "headache")]), "the other symptom stays")
            #expect(!json.contains("note") && !json.contains("basalBodyTempC"), "untouched fields are not sent")

            let kept = CycleDayLogWrite(date: "2026-11-01", flow: .light, loggedAt: "x", source: "APPLE_HEALTH")
            let rebuilt = CycleHealthKitImporter.correctionPatch(
                types: [CycleHealthKitMapping.menstrualFlow],
                rebuilt: [CycleHealthKitMapping.menstrualFlow: kept],
                current: row
            )
            #expect(rebuilt.flow == .set(.light), "a remaining flow sample of the day wins")
            #expect(rebuilt.symptoms == .unchanged)
        }

        @Test("the store round-trips per partition; a missing file reads unseeded")
        func storeRoundTrip() {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cycle-days-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CycleSampleDayStore(directory: dir)
            #expect(!store.load(partitionToken: "a").seeded)
            var map = CycleSampleDayMap()
            map.seeded = true
            map.record([("s", "2026-11-03")])
            #expect(store.save(map, partitionToken: "a"))
            #expect(store.load(partitionToken: "a") == map)
            #expect(!store.load(partitionToken: "b").seeded, "partitions stay apart")
            store.remove(partitionToken: "a")
            #expect(!store.load(partitionToken: "a").seeded)
        }

        @Test("a queued Apple Health day-log for a deleted day leaves the outbox; a manual one stays")
        func outboxPrune() async throws {
            let owner = "owner-1"
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { owner })
            let apple = CycleDayLogWrite(
                date: "2026-11-01",
                loggedAt: "2026-11-01T08:00:00Z",
                source: "APPLE_HEALTH",
                externalId: "cycle-hk:2026-11-01"
            )
            let other = CycleDayLogWrite(
                date: "2026-11-02",
                loggedAt: "2026-11-02T08:00:00Z",
                source: "APPLE_HEALTH",
                externalId: "cycle-hk:2026-11-02"
            )
            let manual = CycleDayLogWrite(date: "2026-11-01", loggedAt: "2026-11-01T08:00:00Z", externalId: "cycle-hk:2026-11-01")
            for (index, write) in [apple, other, manual].enumerated() {
                try await outbox.enqueue(
                    .init(
                        kind: .logCycleDayLog,
                        payload: JSONEncoder().encode(OutboxQueue.Payloads.LogCycleDayLog(write: write)),
                        idempotencyKey: "k\(index)",
                        ownerUserID: owner
                    ),
                    requiringCurrentOwner: owner
                )
            }
            let removed = await outbox.pruneQueuedAppleHealthUploads(.logCycleDayLog, removing: ["cycle-hk:2026-11-01"], ownerUserID: owner)
            #expect(removed == 1)
            #expect(await outbox.snapshot.map(\.idempotencyKey).sorted() == ["k1", "k2"])
        }
    }

    /// Basal body temperature onto the day-log, and the cycle delete route.
    @Suite("Apple Health 1.7: cycle temperature and deletions", .serialized, .mockURLSession)
    struct CycleIngest17Tests {
        private final class Calls: @unchecked Sendable {
            private let lock = OSAllocatedUnfairLock(initialState: [(String, String, Data)]())
            func add(_ req: URLRequest) {
                let body = req.httpBody ?? ingest17Body(req) ?? Data()
                lock.withLock { $0.append((req.httpMethod ?? "", req.url?.path ?? "", body)) }
            }

            var count: Int {
                lock.withLock { $0.count }
            }

            func bodies(method: String, path: String) -> [Data] {
                lock.withLock { calls in calls.filter { $0.0 == method && $0.1 == path }.map(\.2) }
            }

            var deletes: [[String]] {
                lock.withLock { calls in
                    calls.filter { $0.0 == "DELETE" && $0.1 == AppleHealthDeleteDomain.cycleDayLog.path }.compactMap {
                        (try? JSONSerialization.jsonObject(with: $0.2) as? [String: [String]])?["externalIds"]
                    }
                }
            }
        }

        private static let sessions = AuthenticatedSessionLeaseRegistry()

        private static func lease() throws -> HealthSyncAuthenticatedLease {
            _ = sessions.activate(ownerID: MedFixtures.ownerID)
            return try HealthSyncAuthenticatedLease.admit(
                from: sessions,
                ownerID: MedFixtures.ownerID,
                source: .cycle,
                bearerProvider: { "bearer-abc" }
            )
        }

        /// The importer keeps its own `UserDefaults` instance of `suite`; the
        /// test reads the same suite through another instance.
        private func makeImporter(
            suite: String,
            dir: URL,
            health: @escaping @Sendable (HKSampleType) -> [HKSample] = { _ in [] }
        ) throws -> CycleHealthKitImporter {
            let (api, _) = MedFixtures.makeAPI()
            let repo = try CycleRepository(api: api, outbox: OutboxQueue(inMemory: true))
            return CycleHealthKitImporter(
                store: HKHealthStore(),
                repo: repo,
                userID: MedFixtures.ownerID,
                defaults: UserDefaults(suiteName: suite)!,
                profileTimeZone: { TimeZone(identifier: "Europe/Berlin")! },
                sampleDays: CycleSampleDayStore(directory: dir),
                rangeSamples: { type, from, to in
                    health(type).filter { $0.startDate >= from && $0.startDate < to }
                }
            )
        }

        private func temperature(_ celsius: Double, at iso: String) throws -> HKQuantitySample {
            let at = try #require(ISO8601DateFormatter().date(from: iso))
            return HKQuantitySample(
                type: HKQuantityType(.basalBodyTemperature),
                quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: celsius),
                start: at,
                end: at
            )
        }

        @Test("one write per day with the earliest plausible temperature")
        func temperatureWrites() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cycle-t-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let importer = try makeImporter(suite: "test.ingest-17.\(UUID().uuidString)", dir: dir)
            let samples = try [
                temperature(36.71, at: "2026-11-01T07:30:00Z"),
                temperature(36.45, at: "2026-11-01T05:10:00Z"),
                temperature(97.9, at: "2026-11-02T05:00:00Z"),
                temperature(36.9, at: "2026-11-03T05:00:00Z")
            ]
            let writes = await importer.buildWrites(fromSamples: samples, identifier: CycleBasalTemperature.identifier)
            #expect(writes.map(\.date) == ["2026-11-01", "2026-11-03"], "a Fahrenheit slip is not sent")
            #expect(writes.first?.basalBodyTempC == 36.45)
            #expect(writes.first?.externalId == "cycle-hk:2026-11-01")
            #expect(writes.first?.source == "APPLE_HEALTH")
            #expect(writes.allSatisfy { $0.flow == nil && $0.symptoms == nil })
            let pairs = await importer.sampleDayPairs(samples, identifier: CycleBasalTemperature.identifier)
            #expect(pairs.count == 3)
        }

        @Test("a later, warmer reading of a day does not replace its waking temperature")
        func temperatureIsTheWholeDaysEarliest() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cycle-t2-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let waking = try temperature(36.42, at: "2026-11-04T05:30:00Z")
            let afternoon = try temperature(37.1, at: "2026-11-04T13:00:00Z")
            let importer = try makeImporter(suite: "test.ingest-17.\(UUID().uuidString)", dir: dir) { type in
                type.identifier == CycleBasalTemperature.identifier ? [waking, afternoon] : []
            }
            // A later page brings only the afternoon reading of that day.
            let writes = try await importer.pageWrites(fromSamples: [afternoon], identifier: CycleBasalTemperature.identifier)
            #expect(writes.map(\.date) == ["2026-11-04"])
            #expect(writes.first?.basalBodyTempC == 36.42)
        }

        @Test("a flow deleted in Health leaves the day it shared with a symptom")
        func keptDayIsRebuilt() async throws {
            let calls = Calls()
            let failPatch = OSAllocatedUnfairLock(initialState: true)
            MockURLProtocol.install { req in
                calls.add(req)
                if req.httpMethod == "GET" {
                    let row = #"{"data":{"id":"row-1","date":"2026-11-01","flow":"HEAVY","source":"APPLE_HEALTH","symptoms":[{"key":"cramps","severity":2}]},"error":null}"#
                    return (MedFixtures.ok(req), Data(row.utf8))
                }
                if failPatch.withLock({ $0 }) { return (MedFixtures.status(503, req), Data()) }
                return (MedFixtures.ok(req), Data(#"{"data":{"id":"row-1"},"error":null}"#.utf8))
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cycle-r-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let suite = "test.ingest-17.\(UUID().uuidString)"
            let cramps = try #require(HKObjectType.categoryType(forIdentifier: .abdominalCramps))
            let day = try #require(ISO8601DateFormatter().date(from: "2026-10-31T23:00:00Z"))
            let symptom = HKCategorySample(type: cramps, value: 4, start: day, end: day.addingTimeInterval(86400))
            let importer = try makeImporter(suite: suite, dir: dir) { type in
                type.identifier == cramps.identifier ? [symptom] : []
            }
            let token = HealthKitService.partitionToken(for: MedFixtures.ownerID)
            var map = CycleSampleDayMap()
            map.seeded = true
            map.record([("flow-1", "2026-11-01")], identifier: CycleHealthKitMapping.menstrualFlow)
            map.record([(symptom.uuid.uuidString, "2026-11-01")], identifier: cramps.identifier)
            CycleSampleDayStore(directory: dir).save(map, partitionToken: token)
            let lease = try Self.lease()

            // The server is out of reach: the correction waits.
            await importer.forwardDeletions(["flow-1"], requiring: lease)
            #expect(calls.deletes.isEmpty, "the day keeps its symptom, so it is not deleted")
            #expect(CycleSampleDayStore(directory: dir).load(partitionToken: token).pendingCorrections.keys.sorted() == ["2026-11-01"])

            failPatch.withLock { $0 = false }
            await importer.forwardDeletions([], requiring: lease)
            #expect(CycleSampleDayStore(directory: dir).load(partitionToken: token).pendingCorrections.isEmpty)
            let patches = calls.bodies(method: "PATCH", path: "/api/cycle/day-logs/row-1")
            #expect(patches.count >= 2, "the failed attempt (with the client's own retries) and the one that landed")
            let body = try #require(patches.last.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            #expect(body["flow"] is NSNull, "the deleted flow is cleared")
            #expect(body["symptoms"] == nil, "the symptom's type was not touched")
        }

        @Test("a symptom goes out with the day's whole list: typed-in and other Health symptoms stay")
        func symptomWritesCarryTheWholeDay() async throws {
            let serverDown = OSAllocatedUnfairLock(initialState: false)
            MockURLProtocol.install { req in
                if serverDown.withLock({ $0 }) { return (MedFixtures.status(403, req), Data()) }
                let row = #"{"data":{"id":"row-2","date":"2026-11-01","source":"MANUAL","symptoms":[{"key":"headache"},{"key":"cramps","severity":1}]},"error":null}"#
                return (MedFixtures.ok(req), Data(row.utf8))
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cycle-s-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let cramps = try #require(HKObjectType.categoryType(forIdentifier: .abdominalCramps))
            let bloating = try #require(HKObjectType.categoryType(forIdentifier: .bloating))
            let day = try #require(ISO8601DateFormatter().date(from: "2026-10-31T23:00:00Z"))
            let crampsSample = HKCategorySample(type: cramps, value: 4, start: day, end: day.addingTimeInterval(86400))
            let bloatingSample = HKCategorySample(type: bloating, value: 2, start: day, end: day.addingTimeInterval(86400))
            let importer = try makeImporter(suite: "test.ingest-17.\(UUID().uuidString)", dir: dir) { type in
                type.identifier == bloating.identifier ? [bloatingSample] : []
            }
            let writes = try await importer.pageWrites(fromSamples: [crampsSample], identifier: cramps.identifier)
            let symptoms = try #require(writes.first?.symptoms)
            #expect(symptoms.map(\.key) == ["headache", "cramps", "bloating"], "the typed-in headache and Health's bloating stay")
            #expect(
                symptoms.first { $0.key == "cramps" }?.severity == CycleHealthKitMapping.symptomSeverity(rawValue: 4),
                "this sweep's own value wins"
            )

            // Without the server's list no symptom goes out: the page holds.
            serverDown.withLock { $0 = true }
            await #expect(throws: (any Error).self) {
                _ = try await importer.pageWrites(fromSamples: [crampsSample], identifier: cramps.identifier)
            }
        }

        @Test("deletions parked while the map was unseeded go out once it is seeded")
        func parkedDeletionsGoOut() async throws {
            let calls = Calls()
            MockURLProtocol.install { req in
                calls.add(req)
                return (MedFixtures.ok(req), Data(#"{"data":{"deletedCount":1},"error":null}"#.utf8))
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cycle-p-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let suite = "test.ingest-17.\(UUID().uuidString)"
            try KnownServerVersion.record(ServerVersionInfo(version: "1.48.0"), defaults: #require(UserDefaults(suiteName: suite)))
            let importer = try makeImporter(suite: suite, dir: dir)
            let token = HealthKitService.partitionToken(for: MedFixtures.ownerID)
            var map = CycleSampleDayMap()
            map.record([("a", "2026-11-07")], identifier: CycleHealthKitMapping.menstrualFlow)
            CycleSampleDayStore(directory: dir).save(map, partitionToken: token)

            // The seed failed: the page's deletion is parked, not dropped with the anchor.
            #expect(await importer.parkDeletions(["a"]))
            var seeded = CycleSampleDayStore(directory: dir).load(partitionToken: token)
            #expect(seeded.pendingDeleted == ["a"])
            seeded.seeded = true
            CycleSampleDayStore(directory: dir).save(seeded, partitionToken: token)

            try await importer.forwardDeletions([], requiring: Self.lease())
            #expect(calls.deletes == [["cycle-hk:2026-11-07"]])
            #expect(CycleSampleDayStore(directory: dir).load(partitionToken: token).pendingDeleted.isEmpty)
        }

        @Test("a deleted last sample sends its day; the route closed keeps it until it opens")
        func deletionsFollowTheRoute() async throws {
            let calls = Calls()
            MockURLProtocol.install { req in
                calls.add(req)
                return (MedFixtures.ok(req), Data(#"{"data":{"deletedCount":1},"error":null}"#.utf8))
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cycle-d-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let suite = "test.ingest-17.\(UUID().uuidString)"
            let d = try #require(UserDefaults(suiteName: suite))
            let importer = try makeImporter(suite: suite, dir: dir)
            let token = HealthKitService.partitionToken(for: MedFixtures.ownerID)
            var map = CycleSampleDayMap()
            map.seeded = true
            map.record([("a", "2026-11-01"), ("b", "2026-11-01"), ("c", "2026-11-02")])
            CycleSampleDayStore(directory: dir).save(map, partitionToken: token)
            let lease = try Self.lease()

            // Old server: no route yet, the day waits.
            await importer.forwardDeletions(["c"], requiring: lease)
            #expect(calls.deletes.isEmpty)
            #expect(AppleHealthPendingDeletions.pending(.cycleDayLog, ownerID: lease.ownerID, defaults: d) == ["cycle-hk:2026-11-02"])

            // 1.48.0: an edit (one of two samples) keeps its day, the waiting one goes.
            KnownServerVersion.record(ServerVersionInfo(version: "1.48.0"), defaults: d)
            await importer.forwardDeletions(["a"], requiring: lease)
            #expect(calls.deletes == [["cycle-hk:2026-11-02"]])
            #expect(AppleHealthPendingDeletions.pending(.cycleDayLog, ownerID: lease.ownerID, defaults: d).isEmpty)

            await importer.forwardDeletions(["b"], requiring: lease)
            #expect(AppleHealthPendingDeletions.pending(.cycleDayLog, ownerID: lease.ownerID, defaults: d).isEmpty)
            // The two deletes and the read of the day "a" left behind.
            #expect(calls.count == 3)
            #expect(calls.deletes.last == ["cycle-hk:2026-11-01"])
        }

        @Test("cycle tracking off on the server keeps the day for later")
        func moduleOffKeeps() async throws {
            MockURLProtocol.install { req in
                let body = #"{"data":null,"error":{"message":"off"},"meta":{"errorCode":"cycle.disabled"}}"#
                return (MedFixtures.status(403, req), Data(body.utf8))
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cycle-m-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let suite = "test.ingest-17.\(UUID().uuidString)"
            let d = try #require(UserDefaults(suiteName: suite))
            KnownServerVersion.record(ServerVersionInfo(version: "1.48.0"), defaults: d)
            let importer = try makeImporter(suite: suite, dir: dir)
            var map = CycleSampleDayMap()
            map.seeded = true
            map.record([("a", "2026-11-05")])
            CycleSampleDayStore(directory: dir).save(map, partitionToken: HealthKitService.partitionToken(for: MedFixtures.ownerID))
            let lease = try Self.lease()
            await importer.forwardDeletions(["a"], requiring: lease)
            #expect(AppleHealthPendingDeletions.pending(.cycleDayLog, ownerID: lease.ownerID, defaults: d) == ["cycle-hk:2026-11-05"])
        }

        @Test("the importer's start and stop say whether the card may ask for the temperature")
        func activeFlag() async throws {
            let suite = "test.ingest-17.\(UUID().uuidString)"
            let d = try #require(UserDefaults(suiteName: suite))
            CycleBasalTemperature.recordCycleImport(active: true, defaults: d)
            #expect(CycleBasalTemperature.isCycleImportActive(defaults: d))
            let importer = try makeImporter(suite: suite, dir: FileManager.default.temporaryDirectory)
            await importer.stop()
            #expect(!CycleBasalTemperature.isCycleImportActive(defaults: d))
            #expect(CycleHealthKitImporter.readSampleTypes().map(\.identifier).contains(CycleBasalTemperature.identifier))
            #expect(
                !CycleHealthKitImporter.readCategoryTypes().map(\.identifier).contains(CycleBasalTemperature.identifier),
                "not in the reproductive sheet the cycle store asks for at launch"
            )
        }
    }

    /// A reader with a scripted deletion feed.
    final class DeletingMedicationReader: AppleHealthMedicationReading, AppleHealthDoseDeletionReading, @unchecked Sendable {
        private let pages = OSAllocatedUnfairLock(initialState: [AppleHealthDoseDeletionPage]())
        private let anchors = OSAllocatedUnfairLock(initialState: [Data?]())

        func script(_ page: AppleHealthDoseDeletionPage) {
            pages.withLock { $0.append(page) }
        }

        var anchorsAsked: [Data?] {
            anchors.withLock { $0 }
        }

        var isAvailable: Bool {
            true
        }

        func requestAuthorization() async throws {}

        func readMedications() async throws -> [AppleHealthMedicationRecord] {
            []
        }

        func readDoseEvents(since _: Date?) async throws -> [AppleHealthDoseRecord] {
            []
        }

        func readDoseDeletions(after anchor: Data?) async throws -> AppleHealthDoseDeletionPage {
            anchors.withLock { $0.append(anchor) }
            return pages.withLock { $0.isEmpty ? AppleHealthDoseDeletionPage(deletedIDs: [], anchor: anchor) : $0.removeFirst() }
        }
    }

    /// Doses deleted in Apple Health (`/api/medications/intake/by-external-ids`).
    @Suite("Apple Health 1.7: dose deletions", .serialized, .mockURLSession)
    struct AppleHealthDoseDeletionTests {
        private final class Deletes: @unchecked Sendable {
            let bodies = OSAllocatedUnfairLock(initialState: [[String]]())
            let failing = OSAllocatedUnfairLock(initialState: false)
        }

        private func install(_ deletes: Deletes) {
            MockURLProtocol.install { req in
                let path = req.url?.path ?? ""
                if path == AppleHealthDeleteDomain.medicationIntake.path, req.httpMethod == "DELETE" {
                    if deletes.failing.withLock({ $0 }) { return (MedFixtures.status(503, req), Data()) }
                    let body = req.httpBody ?? ingest17Body(req) ?? Data()
                    let ids = (try? JSONSerialization.jsonObject(with: body) as? [String: [String]])?["externalIds"] ?? []
                    deletes.bodies.withLock { $0.append(ids) }
                    return (MedFixtures.ok(req), Data(#"{"data":{"deletedCount":1},"error":null}"#.utf8))
                }
                if path == "/api/medications" {
                    return (MedFixtures.ok(req), Data(MedFixtures.medListEnvelope([]).utf8))
                }
                return (MedFixtures.ok(req), Data(MedFixtures.emptyBulk.utf8))
            }
        }

        @Test("update path: the first pass only sets the anchor; later deletions go out once")
        func firstPassSetsAnchor() async throws {
            let deletes = Deletes()
            install(deletes)
            let (api, kc) = MedFixtures.makeAPI()
            let reader = DeletingMedicationReader()
            let fixture = try MedFixtures.makeImporter(api: api, keychain: kc, reader: reader, deletesRouteOpen: { true })
            reader.script(AppleHealthDoseDeletionPage(deletedIDs: [], anchor: Data("A1".utf8)))
            _ = await fixture.importer.sync()
            #expect(deletes.bodies.withLock { $0 }.isEmpty)
            reader.script(AppleHealthDoseDeletionPage(deletedIDs: ["DOSE-1", "DOSE-2"], anchor: Data("A2".utf8)))
            _ = await fixture.importer.sync()
            #expect(deletes.bodies.withLock { $0 } == [["DOSE-1", "DOSE-2"]])
            _ = await fixture.importer.sync()
            #expect(deletes.bodies.withLock { $0 }.count == 1, "sent once")
            #expect(reader.anchorsAsked == [nil, Data("A1".utf8), Data("A2".utf8)])
        }

        @Test("old server: deletions wait while the route is closed; a failed send keeps them")
        func keptUntilSent() async throws {
            let deletes = Deletes()
            install(deletes)
            let open = OSAllocatedUnfairLock(initialState: false)
            let (api, kc) = MedFixtures.makeAPI()
            let reader = DeletingMedicationReader()
            let fixture = try MedFixtures.makeImporter(
                api: api, keychain: kc, reader: reader, deletesRouteOpen: { open.withLock { $0 } }
            )
            reader.script(AppleHealthDoseDeletionPage(deletedIDs: ["DOSE-9"], anchor: Data("B1".utf8)))
            _ = await fixture.importer.sync()
            #expect(deletes.bodies.withLock { $0 }.isEmpty)
            open.withLock { $0 = true }
            deletes.failing.withLock { $0 = true }
            _ = await fixture.importer.sync()
            #expect(deletes.bodies.withLock { $0 }.isEmpty)
            deletes.failing.withLock { $0 = false }
            _ = await fixture.importer.sync()
            #expect(deletes.bodies.withLock { $0 } == [["DOSE-9"]])
        }

        @Test("a deleted dose leaves the ledger's pending set before its delete")
        func ledgerForgets() throws {
            let storage = HealthSyncCursorStorage.userDefaults(isolatedDefaults())
            let key = try #require(HealthSyncCursorKey(
                ownerID: "account-a",
                source: .appleMedication,
                typeIdentifier: AppleHealthDoseLedger.typeIdentifier
            ))
            let ledger = AppleHealthDoseLedger(storage: storage, key: key)
            let sessions = AuthenticatedSessionLeaseRegistry()
            _ = sessions.activate(ownerID: "account-a")
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: sessions,
                ownerID: "account-a",
                source: .appleMedication,
                bearerProvider: { "t" }
            )
            let at = Date(timeIntervalSince1970: 1_790_000_000)
            try ledger.commit(observed: ["DOSE-1": at, "DOSE-2": at], accountedFor: [], requiring: lease)
            try ledger.forget(["DOSE-1"], requiring: lease)
            #expect(ledger.pendingIdentities() == ["DOSE-2"])
        }
    }

#endif

// swiftlint:enable force_unwrapping file_length large_tuple
