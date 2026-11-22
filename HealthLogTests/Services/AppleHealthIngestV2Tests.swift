import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping file_length type_body_length

/// The app half of `CONTRACT-apple-health-v2`: what the server must report
/// before anything is read, how a sample becomes a wire row, and the update
/// path of an installation that already holds anchors, outbox rows and
/// feature records in the 1.6 format.
@Suite("Apple Health ingest v2: capability gate and wire rows")
struct AppleHealthIngestV2GateTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "test.ingest-v2.\(UUID().uuidString)")!
    }

    // MARK: - Capability

    @Test("`/api/auth/me` features carry the three flags; absent reads false")
    func featuresDecode() throws {
        let decode = { (json: String) throws -> ServerFeatures in
            try JSONDecoder().decode(ServerFeatures.self, from: Data(json.utf8))
        }
        let all = try decode(#"{"appleHealthSymptoms":true,"appleHealthDeletes":true,"nutrientMacros":true}"#)
        #expect(all.appleHealthSymptoms && all.appleHealthDeletes && all.nutrientMacros)
        #expect(ServerFeatures.recorded(all).isSuperset(of: [.appleHealthSymptoms, .appleHealthDeletes, .nutrientMacros]))
        let none = try decode(#"{"trackIntake":true,"appleHealthSymptoms":"yes"}"#)
        #expect(!none.appleHealthSymptoms && !none.appleHealthDeletes && !none.nutrientMacros)
        #expect(none.trackIntake)
    }

    @Test("symptoms need the flag; deletes and macros also open from server 1.48.0")
    func capabilityRule() {
        let d = defaults()
        for feature in [KnownServerVersion.Feature.appleHealthSymptoms, .appleHealthDeletes, .nutrientMacros] {
            #expect(!AppleHealthIngestCapability.isAvailable(feature, defaults: d), "never probed: closed")
        }
        KnownServerVersion.record(ServerVersionInfo(version: "1.48.1"), defaults: d)
        #expect(!AppleHealthIngestCapability.isAvailable(.appleHealthSymptoms, defaults: d))
        #expect(AppleHealthIngestCapability.isAvailable(.appleHealthDeletes, defaults: d))
        #expect(AppleHealthIngestCapability.isAvailable(.nutrientMacros, defaults: d))
        KnownServerVersion.recordFeatures([.appleHealthSymptoms], defaults: d)
        #expect(AppleHealthIngestCapability.isAvailable(.appleHealthSymptoms, defaults: d))
        KnownServerVersion.record(ServerVersionInfo(version: "1.47.6"), defaults: d)
        #expect(!AppleHealthIngestCapability.isAvailable(.appleHealthDeletes, defaults: d))
        #expect(AppleHealthIngestCapability.isAvailable(.appleHealthSymptoms, defaults: d), "a reported flag counts")
        // Another server: everything forgotten.
        HealthKitServerTypeGate.forget(defaults: d)
        #expect(!AppleHealthIngestCapability.isAvailable(.appleHealthSymptoms, defaults: d))
    }

    @Test("new measurement types: 1.48 types by version, the rest only by `acceptedTypes`")
    func measurementTypeGate() {
        let d = defaults()
        let hypertension = AppleHealthIngestTypes.hypertensionEvent
        let lowCardio = AppleHealthIngestTypes.lowCardioFitnessEvent
        #expect(!HealthKitServerTypeGate.serverAccepts(hypertension, defaults: d))
        KnownServerVersion.record(ServerVersionInfo(version: "1.48.0"), defaults: d)
        #expect(HealthKitServerTypeGate.serverAccepts(hypertension, defaults: d))
        #expect(HealthKitServerTypeGate.serverAccepts(AppleHealthIngestTypes.phq9, defaults: d))
        #expect(!HealthKitServerTypeGate.serverAccepts(lowCardio, defaults: d), "no release maps it")
        #expect(!HealthKitServerTypeGate.serverAccepts(AppleHealthIngestTypes.menopausalState, defaults: d))
        HealthKitAcceptedTypes.record([lowCardio], defaults: d)
        #expect(HealthKitServerTypeGate.serverAccepts(lowCardio, defaults: d))
        #expect(!HealthKitServerTypeGate.serverAccepts(hypertension, defaults: d), "a published list decides alone")
    }

    @Test("the diagnostics rows say waiting until the server takes a group")
    func statusRows() {
        let d = defaults()
        let ios18 = OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0)
        let before = AppleHealthIngestStatusRow.current(defaults: d, version: ios18)
        #expect(before.count == AppleHealthIngestStatusRow.Group.allCases.count)
        #expect(before.first { $0.group == .hypertension }?.state == .notOnThisSystem)
        #expect(before.first { $0.group == .menopause }?.state == .notOnThisSystem)
        #expect(before.first { $0.group == .symptoms }?.state == .waitingForServer)
        #expect(before.first { $0.group == .assessments }?.state == .waitingForServer)
        KnownServerVersion.record(ServerVersionInfo(version: "1.48.2"), defaults: d)
        KnownServerVersion.recordFeatures([.appleHealthSymptoms], defaults: d)
        let after = AppleHealthIngestStatusRow.current(
            defaults: d,
            version: OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        )
        #expect(after.first { $0.group == .symptoms }?.state == .active)
        #expect(after.first { $0.group == .deletes }?.state == .active)
        #expect(after.first { $0.group == .macros }?.state == .active)
        #expect(after.first { $0.group == .hypertension }?.state == .active)
        #expect(after.first { $0.group == .lowCardioFitness }?.state == .waitingForServer)
    }

    // MARK: - Symptom catalogue

    @Test("39 symptom codes, unique, the eleven cycle symptoms included")
    func symptomCatalogue() {
        let codes = AppleHealthSymptomCatalog.codesBySuffix.map(\.code)
        #expect(codes.count == 39)
        #expect(Set(codes).count == 39)
        #expect(Set(AppleHealthSymptomCatalog.identifiers).count == 39)
        for identifier in CycleHealthKitMapping.symptomKeyByIdentifier.keys {
            #expect(AppleHealthSymptomCatalog.code(for: identifier) != nil, "\(identifier)")
        }
        #expect(AppleHealthSymptomCatalog.code(for: "HKCategoryTypeIdentifierHeadache") == "HEADACHE")
        #expect(AppleHealthSymptomCatalog.code(for: "HKCategoryTypeIdentifierMenstrualFlow") == nil)
    }

    @Test("severity maps to the diary scale; not present is never sent")
    func severityScale() {
        let fever = "HKCategoryTypeIdentifierFever"
        #expect(AppleHealthSymptomCatalog.intensity(forValue: 0, identifier: fever) == 5)
        #expect(AppleHealthSymptomCatalog.intensity(forValue: 1, identifier: fever) == nil)
        #expect(AppleHealthSymptomCatalog.intensity(forValue: 2, identifier: fever) == 3)
        #expect(AppleHealthSymptomCatalog.intensity(forValue: 3, identifier: fever) == 6)
        #expect(AppleHealthSymptomCatalog.intensity(forValue: 4, identifier: fever) == 9)
        #expect(AppleHealthSymptomCatalog.intensity(forValue: 9, identifier: fever) == nil)
        let mood = "HKCategoryTypeIdentifierMoodChanges"
        #expect(AppleHealthSymptomCatalog.intensity(forValue: 0, identifier: mood) == 5)
        #expect(AppleHealthSymptomCatalog.intensity(forValue: 1, identifier: mood) == nil)
        let appetite = "HKCategoryTypeIdentifierAppetiteChanges"
        #expect(AppleHealthSymptomCatalog.intensity(forValue: 1, identifier: appetite) == nil)
        #expect(AppleHealthSymptomCatalog.intensity(forValue: 3, identifier: appetite) == 5)
    }

    @Test("a symptom row: APPLE_HEALTH, sample UUID, no endAt without a duration")
    func symptomWireRow() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let point = AppleHealthSymptomEntryDTO(code: "FEVER", occurredAt: start, endAt: start, intensity: 6, externalId: "uuid-1")
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder.hlBatch.encode(point)) as? [String: Any])
        #expect(Set(json.keys) == ["code", "occurredAt", "intensity", "externalId", "source"])
        #expect(json["source"] as? String == "APPLE_HEALTH")
        let span = AppleHealthSymptomEntryDTO(
            code: "FEVER",
            occurredAt: start,
            endAt: start.addingTimeInterval(3600),
            intensity: 6,
            externalId: "uuid-2"
        )
        #expect(span.endAt != nil)
    }

    @Test("assessment answers go out only when they fit the server's rule")
    func assessmentAnswers() {
        #expect(AppleHealthAssessmentAnswers.wire([1, 1, 1, 1, 1, 0, 0, 1, 1], score: 7) == [1, 1, 1, 1, 1, 0, 0, 1, 1])
        #expect(AppleHealthAssessmentAnswers.wire([1, 1, 1, 1, 1, 0, 0, 1, 4], score: 6) == nil, "prefer not to answer")
        #expect(AppleHealthAssessmentAnswers.wire([1, 1, 1], score: 2) == nil, "sum differs")
        #expect(AppleHealthAssessmentAnswers.wire([], score: 0) == nil)
    }

    @Test("every delete domain names its contract route")
    func deleteRoutes() {
        #expect(AppleHealthDeleteDomain.symptoms.path == "/api/symptoms/events/by-external-ids")
        #expect(AppleHealthDeleteDomain.workout.path == "/api/workouts/by-external-ids")
        #expect(AppleHealthDeleteDomain.ecg.path == "/api/insights/ecg/by-external-ids")
        #expect(AppleHealthDeleteDomain.cycleDayLog.path == "/api/cycle/day-logs/by-external-ids")
        #expect(AppleHealthDeleteDomain.mood.path == "/api/mood-entries/by-external-ids")
        #expect(AppleHealthDeleteDomain.medicationIntake.path == "/api/medications/intake/by-external-ids")
        #expect(AppleHealthDeleteDomain.measurement.path == "/api/measurements/by-external-ids")
    }

    // MARK: - Macros

    @Test("the macros join the nutrient sync only while the server takes them")
    func macroCatalogue() {
        #expect(NutrientCatalog.syncItems(includingMacros: false) == NutrientCatalog.all)
        let with = NutrientCatalog.syncItems(includingMacros: true)
        #expect(with.count == NutrientCatalog.all.count + 12)
        #expect(Set(with.map(\.hkIdentifier)).count == with.count)
        let energy = NutrientCatalog.macros.first { $0.code == .energy }
        #expect(energy?.unit == "kcal")
        #expect(NutrientCatalog.macros.allSatisfy { ["g", "mg", "kcal"].contains($0.unit) })
        #expect(NutrientCode(rawValue: "saturated_fat") == .saturatedFat)
        #expect(!NutrientDisplay.missingReferenceMeansNoSex(for: .protein))
        #expect(NutrientDisplay.missingReferenceMeansNoSex(for: .vitaminC))
    }

    // MARK: - Update path

    @Test("a 1.6 outbox row without `assessmentAnswers` decodes, and the key is omitted on the wire")
    func oldOutboxRowDecodes() throws {
        let old = #"""
        {"entries":[{"hkIdentifier":"HKCategoryTypeIdentifierHighHeartRateEvent","value":1,"unit":"event",
        "startDate":"2026-11-01T10:00:00Z","endDate":"2026-11-01T10:00:00Z","categoryValue":1,"externalId":"evt-1"}]}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(HealthKitBatchPayload.self, from: Data(old.utf8))
        #expect(payload.entries.first?.assessmentAnswers == nil)
        let reencoded = try String(data: JSONEncoder.hlBatch.encode(payload), encoding: .utf8) ?? ""
        #expect(!reencoded.contains("assessmentAnswers"))
    }

    @Test("a 1.6 feature record keeps working; the new flags read as absent")
    func oldFeatureRecord() {
        let d = defaults()
        d.set(["cumulativeHourBuckets", "syncTriggerBackfill"], forKey: KnownServerVersion.featuresDefaultsKey)
        KnownServerVersion.record(ServerVersionInfo(version: "1.47.6"), defaults: d)
        #expect(KnownServerVersion.supports(.cumulativeHourBuckets, defaults: d))
        #expect(!AppleHealthIngestCapability.isAvailable(.appleHealthSymptoms, defaults: d))
        #expect(!AppleHealthIngestCapability.isAvailable(.appleHealthDeletes, defaults: d))
    }

    @Test("a mood entry carries its Apple Health source pair only when it has one; old rows decode")
    func moodSourcePair() throws {
        let manual = MoodEntry(id: "m-1", recordedAt: Date(timeIntervalSince1970: 1_700_000_000), score: 4)
        let manualJSON = try String(data: JSONEncoder.hlDefault.encode(manual), encoding: .utf8) ?? ""
        #expect(!manualJSON.contains("externalId"))
        #expect(manualJSON.contains("\"MANUAL\""))
        var imported = MoodEntry(
            id: "m-2",
            mood: manual.mood,
            tags: [],
            moodLoggedAt: manual.moodLoggedAt,
            source: "APPLE_HEALTH"
        )
        imported.externalId = "som-uuid"
        let importedJSON = try JSONSerialization.jsonObject(with: JSONEncoder.hlDefault.encode(imported)) as? [String: Any]
        #expect(importedJSON?["externalId"] as? String == "som-uuid")
        #expect(importedJSON?["source"] as? String == "APPLE_HEALTH")
        let old = #"{"id":"m-3","mood":"GUT","tags":[],"moodLoggedAt":"2026-11-01T10:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(MoodEntry.self, from: Data(old.utf8)).externalId == nil)
    }

    @Test("an ECG fetch without deletions keeps its old shape")
    func ecgFetchDefault() {
        let result = EcgSourceFetchResult(recordings: [], anchor: nil)
        #expect(result.deletedIDs.isEmpty)
    }

    @Test("an outbox row of a kind this build added survives as data in an older build's sentinel")
    func newKindsHaveStableRawValues() {
        #expect(OutboxQueue.Operation.Kind.uploadAppleHealthSymptoms.rawValue == "uploadAppleHealthSymptoms")
        #expect(OutboxQueue.Operation.Kind.deleteAppleHealthRecords.rawValue == "deleteAppleHealthRecords")
        #expect(OutboxReplayService.externalIdDedupedKinds.contains(.uploadAppleHealthSymptoms))
        #expect(OutboxReplayService.deleteKinds.contains(.deleteAppleHealthRecords))
    }
}

#if canImport(HealthKit)

    @Suite("Apple Health ingest v2: event units and HealthKit rows")
    struct AppleHealthIngestV2UnitTests {
        private func defaults() -> UserDefaults {
            UserDefaults(suiteName: "test.ingest-v2.units.\(UUID().uuidString)")!
        }

        @Test("the seven older event anchors keep their keys; new units come after them")
        func legacyAnchorsUnchanged() {
            let legacy = HeartHealthEventImporter.legacyUnits()
            #expect(legacy.map(\.key) == HeartHealthEventImporter.eventCategoryTypes().map(\.identifier))
            #expect(legacy.allSatisfy { $0.route == .legacyEvent && $0.types.count == 1 })
            let all = HeartHealthEventImporter.allSweepUnits()
            #expect(Array(all.prefix(legacy.count)).map(\.key) == legacy.map(\.key))
        }

        @Test("nothing new is swept before the server reports it")
        func noUnitsWithoutServer() {
            let d = defaults()
            #expect(HeartHealthEventImporter.ingestV2Units(defaults: d, onlyAccepted: true).isEmpty)
            KnownServerVersion.record(ServerVersionInfo(version: "1.48.2"), defaults: d)
            let units = HeartHealthEventImporter.ingestV2Units(defaults: d, onlyAccepted: true)
            #expect(!units.contains { $0.route == .symptoms }, "symptoms need the flag")
            KnownServerVersion.recordFeatures([.appleHealthSymptoms], defaults: d)
            let open = HeartHealthEventImporter.ingestV2Units(defaults: d, onlyAccepted: true)
            let symptoms = open.first { $0.route == .symptoms }
            #expect(symptoms?.key == EventSweepUnit.symptomsKey)
            #expect(symptoms?.module == .illness)
            #expect(symptoms?.types.count == 39)
            #expect(open.first { $0.key == AppleHealthIngestTypes.phq9 }?.module == .mentalHealth)
        }

        @Test("a headache becomes a symptom row; the cycle way reads it under its own cursor")
        func headacheGoesToSymptomBatch() throws {
            let type = HKCategoryType(.headache)
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let sample = HKCategorySample(type: type, value: HKCategoryValueSeverity.moderate.rawValue, start: start, end: start)
            let row = try #require(AppleHealthIngestHKTypes.symptomEntry(from: sample))
            #expect(row.code == "HEADACHE")
            #expect(row.intensity == 6)
            #expect(row.externalId == sample.uuid.uuidString)
            // The cycle way reads the same type on its own (only while cycle
            // tracking is on) and keeps its own partition.
            #expect(CycleHealthKitMapping.symptomKeyByIdentifier[type.identifier] == "headache")
            let symptomKey = HealthSyncCursorKey(ownerID: "account-a", source: .heartEvent, typeIdentifier: EventSweepUnit.symptomsKey)
            let cycleKey = HealthSyncCursorKey(ownerID: "account-a", source: .cycle, typeIdentifier: type.identifier)
            #expect(symptomKey?.storageKey != cycleKey?.storageKey)
            let absent = HKCategorySample(type: type, value: HKCategoryValueSeverity.notPresent.rawValue, start: start, end: start)
            #expect(AppleHealthIngestHKTypes.symptomEntry(from: absent) == nil)
        }

        @Test("PHQ-9 and GAD-7 resolve under the identifiers the server maps")
        func assessmentIdentifiers() {
            #expect(AppleHealthIngestHKTypes.sampleType(for: AppleHealthIngestTypes.phq9)?.identifier == AppleHealthIngestTypes.phq9)
            #expect(AppleHealthIngestHKTypes.sampleType(for: AppleHealthIngestTypes.gad7)?.identifier == AppleHealthIngestTypes.gad7)
        }
    }

#endif

// swiftlint:enable force_unwrapping file_length type_body_length
