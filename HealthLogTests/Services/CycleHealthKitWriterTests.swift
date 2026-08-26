import Foundation
@testable import HealthLog
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// **W-CYCLECRASH** — pins the writer's validated sample construction.
    ///
    /// `HKCategorySample.init` is exactly where HealthKit raises an uncatchable
    /// `NSInvalidArgumentException` for (a) a menstrual-flow sample missing the
    /// REQUIRED `HKMetadataKeyMenstrualCycleStart` key and (b) any out-of-range
    /// category value (`_validateForCreation`). `buildSamples` is pure (no store,
    /// no auth), so these tests execute the real crash path — a regression here
    /// crashes the test run instead of the operator's phone.
    @Suite("Cycle — HealthKit writer buildSamples (crash-fix)")
    struct CycleHealthKitWriterTests {
        private static let dayKey = "2026-06-10"
        private static let sampleDate = Date(timeIntervalSince1970: 1_780_000_000)

        private var metadata: [String: Any] {
            [
                HKMetadataKeyExternalUUID: "33333333-3333-3333-3333-333333333333",
                HKMetadataKeyWasUserEntered: true
            ]
        }

        /// Build a `CycleDayLogDTO` via its (only) decoder init.
        private func dayLog(
            flow: String? = nil,
            intermenstrualBleeding: Bool = false,
            sexualActivity: Bool = false,
            symptoms: [[String: Any]] = []
        ) throws -> CycleDayLogDTO {
            var obj: [String: Any] = [
                "id": "33333333-3333-3333-3333-333333333333",
                "date": Self.dayKey,
                "source": "MANUAL",
                "syncVersion": 1,
                "intermenstrualBleeding": intermenstrualBleeding,
                "sexualActivity": sexualActivity,
                "symptoms": symptoms
            ]
            if let flow { obj["flow"] = flow }
            let data = try JSONSerialization.data(withJSONObject: obj)
            return try JSONDecoder().decode(CycleDayLogDTO.self, from: data)
        }

        private func build(_ dto: CycleDayLogDTO, isCycleStart: Bool) -> [HKCategorySample] {
            CycleHealthKitWriter.buildSamples(
                for: dto,
                isCycleStart: isCycleStart,
                date: Self.sampleDate,
                metadata: metadata
            )
        }

        private func flowSamples(in samples: [HKCategorySample]) -> [HKCategorySample] {
            samples.filter { $0.categoryType.identifier == CycleHealthKitMapping.menstrualFlow }
        }

        // MARK: - (a)/(b) — REQUIRED menstrual-cycle-start metadata

        @Test("period-start day → flow sample carries menstrualCycleStart == true")
        func flowSampleCycleStartTrue() throws {
            let samples = try build(dayLog(flow: "MEDIUM"), isCycleStart: true)
            let flow = try #require(flowSamples(in: samples).first)
            #expect(flow.value == 3) // HKCategoryValueVaginalBleedingMedium
            #expect(flow.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool == true)
        }

        @Test("non-start flow day → menstrualCycleStart == false (key still present)")
        func flowSampleCycleStartFalse() throws {
            let samples = try build(dayLog(flow: "LIGHT"), isCycleStart: false)
            let flow = try #require(flowSamples(in: samples).first)
            #expect(flow.value == 2) // HKCategoryValueVaginalBleedingLight
            #expect(flow.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool == false)
        }

        @Test("SPOTTING maps to HK light (Q3 boundary), metadata present")
        func spottingMapsToLight() throws {
            let samples = try build(dayLog(flow: "SPOTTING"), isCycleStart: false)
            let flow = try #require(flowSamples(in: samples).first)
            #expect(flow.value == 2)
            #expect(flow.metadata?[HKMetadataKeyMenstrualCycleStart] != nil)
        }

        // MARK: - (c) — NONE flow writes no sample

        @Test("NONE flow → no menstrual-flow sample is mirrored")
        func noneFlowSkipped() throws {
            let samples = try build(dayLog(flow: "NONE"), isCycleStart: false)
            #expect(flowSamples(in: samples).isEmpty)
        }

        // MARK: - (d) — symptom values land in each type's OWN value enum

        @Test("severity-kind symptom maps into HKCategoryValueSeverity (0...4)")
        func severitySymptomMapped() throws {
            // cramps = AbdominalCramps (Severity): 1→mild(2), 3→severe(4),
            // nil→unspecified(0).
            let samples = try build(
                dayLog(symptoms: [
                    ["key": "cramps", "severity": 3],
                    ["key": "headache", "severity": 1],
                    ["key": "bloating"]
                ]),
                isCycleStart: false
            )
            let byID = Dictionary(uniqueKeysWithValues: samples.map { ($0.categoryType.identifier, $0.value) })
            #expect(byID["HKCategoryTypeIdentifierAbdominalCramps"] == 4)
            #expect(byID["HKCategoryTypeIdentifierHeadache"] == 2)
            #expect(byID["HKCategoryTypeIdentifierBloating"] == 0)
        }

        @Test("presence-kind symptom writes present(0), never a severity codepoint")
        func presenceSymptomMapped() throws {
            // mood_swings = MoodChanges (Presence 0...1) — the old writer wrote
            // 2...5 here, which crashed in HKCategorySample init.
            let samples = try build(
                dayLog(symptoms: [["key": "mood_swings", "severity": 3]]),
                isCycleStart: false
            )
            let mood = try #require(samples.first { $0.categoryType.identifier == "HKCategoryTypeIdentifierMoodChanges" })
            #expect(mood.value == 0) // HKCategoryValuePresencePresent
        }

        @Test("appetite-changes symptom writes increased(3)")
        func appetiteSymptomMapped() throws {
            let samples = try build(
                dayLog(symptoms: [["key": "food_cravings", "severity": 2]]),
                isCycleStart: false
            )
            let appetite = try #require(
                samples.first { $0.categoryType.identifier == "HKCategoryTypeIdentifierAppetiteChanges" }
            )
            #expect(appetite.value == 3) // HKCategoryValueAppetiteChangesIncreased
        }

        @Test("out-of-range symptom severity is skipped, not crashed")
        func outOfRangeSeveritySkipped() throws {
            let samples = try build(
                dayLog(symptoms: [
                    ["key": "cramps", "severity": 9],
                    ["key": "headache", "severity": 2]
                ]),
                isCycleStart: false
            )
            // The garbage severity drops its sample; the valid one survives.
            #expect(!samples.contains { $0.categoryType.identifier == "HKCategoryTypeIdentifierAbdominalCramps" })
            let headache = try #require(samples.first { $0.categoryType.identifier == "HKCategoryTypeIdentifierHeadache" })
            #expect(headache.value == 3) // moderate
        }

        // MARK: - (e) — intermenstrual bleeding uses notApplicable(0)

        @Test("intermenstrual bleeding writes HKCategoryValueNotApplicable (0)")
        func intermenstrualMapped() throws {
            let samples = try build(dayLog(intermenstrualBleeding: true), isCycleStart: false)
            let imb = try #require(
                samples.first { $0.categoryType.identifier == CycleHealthKitMapping.intermenstrualBleeding }
            )
            #expect(imb.value == 0)
        }

        // MARK: - defense-in-depth sweep

        @Test("every built sample stays inside its type's SDK-valid value range")
        func kitchenSinkAllValuesValid() throws {
            var obj: [String: Any] = [
                "id": "33333333-3333-3333-3333-333333333333",
                "date": Self.dayKey,
                "source": "MANUAL",
                "syncVersion": 1,
                "flow": "HEAVY",
                "intermenstrualBleeding": true,
                "sexualActivity": true,
                "protectedSex": true,
                "ovulationTest": "POSITIVE_LH_SURGE",
                "cervicalMucus": "EGG_WHITE",
                "pregnancyTest": "NEGATIVE",
                "progesteroneTest": "INDETERMINATE",
                "symptoms": [
                    ["key": "cramps", "severity": 4],
                    ["key": "insomnia", "severity": 1],
                    ["key": "food_cravings"],
                    ["key": "nausea", "severity": 2]
                ]
            ]
            // Tolerant decode keeps unknown enum members nil — also sweep one.
            obj["contraceptive"] = "IUD"
            let data = try JSONSerialization.data(withJSONObject: obj)
            let dto = try JSONDecoder().decode(CycleDayLogDTO.self, from: data)

            let samples = build(dto, isCycleStart: true)
            #expect(!samples.isEmpty)
            for sample in samples {
                let id = sample.categoryType.identifier
                let range = try #require(CycleHealthKitMapping.validWriteValueRange(forIdentifier: id))
                #expect(range.contains(sample.value), "\(id) value \(sample.value) outside \(range)")
                if id == CycleHealthKitMapping.menstrualFlow {
                    #expect(sample.metadata?[HKMetadataKeyMenstrualCycleStart] as? Bool == true)
                }
            }
        }

        // MARK: - pure mapping boundaries

        @Test("hkSymptomWriteValue severity boundaries")
        func symptomWriteValueBoundaries() {
            let cramps = "HKCategoryTypeIdentifierAbdominalCramps"
            #expect(CycleHealthKitMapping.hkSymptomWriteValue(identifier: cramps, severity: nil) == 0)
            #expect(CycleHealthKitMapping.hkSymptomWriteValue(identifier: cramps, severity: 1) == 2)
            #expect(CycleHealthKitMapping.hkSymptomWriteValue(identifier: cramps, severity: 2) == 3)
            #expect(CycleHealthKitMapping.hkSymptomWriteValue(identifier: cramps, severity: 3) == 4)
            #expect(CycleHealthKitMapping.hkSymptomWriteValue(identifier: cramps, severity: 4) == 4) // clamp
            #expect(CycleHealthKitMapping.hkSymptomWriteValue(identifier: cramps, severity: 0) == nil)
            #expect(CycleHealthKitMapping.hkSymptomWriteValue(identifier: cramps, severity: 5) == nil)
            #expect(CycleHealthKitMapping.hkSymptomWriteValue(identifier: "HKCategoryTypeIdentifierUnknown", severity: 1) == nil)
        }
    }

#endif
