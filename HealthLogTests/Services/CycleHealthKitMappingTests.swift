import Foundation
@testable import HealthLog
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

/// **Phase C2** — pins the HealthKit ↔ cycle mapping: flow value mapping
/// (incl. legacy menstrual-flow ↔ vaginal-bleeding parity + the SPOTTING↔light
/// write boundary), the echo-guard filter, the symptom key↔HK table, and the
/// reverse (day-log → HK) value map. Pure mapping — no live HealthKit store.
@Suite("Cycle — HealthKit mapping")
struct CycleHealthKitMappingTests {
    // MARK: - Flow value mapping (read) + legacy fallback parity

    @Test("menstrual-flow codepoints map to the contract flow enum (unspecified→LIGHT, none→NONE)")
    func menstrualFlowValues() {
        #expect(CycleHealthKitMapping.flow(forMenstrualFlowValue: 1) == .light) // unspecified
        #expect(CycleHealthKitMapping.flow(forMenstrualFlowValue: 2) == .light)
        #expect(CycleHealthKitMapping.flow(forMenstrualFlowValue: 3) == .medium)
        #expect(CycleHealthKitMapping.flow(forMenstrualFlowValue: 4) == .heavy)
        #expect(CycleHealthKitMapping.flow(forMenstrualFlowValue: 5) == CycleFlowLevel.none)
        #expect(CycleHealthKitMapping.flow(forMenstrualFlowValue: 9) == nil)
    }

    @Test("vaginal-bleeding (iOS 18) values share the legacy codepoint layout")
    func vaginalBleedingFallbackParity() {
        for value in 1 ... 5 {
            #expect(
                CycleHealthKitMapping.flow(forVaginalBleedingValue: value)
                    == CycleHealthKitMapping.flow(forMenstrualFlowValue: value)
            )
        }
    }

    // MARK: - Enum value tables

    @Test("ovulation-test codepoints map to the contract enum")
    func ovulationTestValues() {
        #expect(CycleHealthKitMapping.ovulationTest(forValue: 1) == .negative)
        #expect(CycleHealthKitMapping.ovulationTest(forValue: 2) == .positiveLHSurge)
        #expect(CycleHealthKitMapping.ovulationTest(forValue: 3) == .indeterminate)
        #expect(CycleHealthKitMapping.ovulationTest(forValue: 4) == .estrogenSurge)
        #expect(CycleHealthKitMapping.ovulationTest(forValue: 0) == nil)
    }

    @Test("cervical-mucus codepoints map to the contract enum")
    func cervicalMucusValues() {
        #expect(CycleHealthKitMapping.cervicalMucus(forValue: 1) == .dry)
        #expect(CycleHealthKitMapping.cervicalMucus(forValue: 5) == .eggWhite)
        #expect(CycleHealthKitMapping.cervicalMucus(forValue: 6) == nil)
    }

    @Test("home-test codepoints map negative/positive/indeterminate")
    func homeTestValues() {
        #expect(CycleHealthKitMapping.homeTest(forValue: 1) == .negative)
        #expect(CycleHealthKitMapping.homeTest(forValue: 2) == .positive)
        #expect(CycleHealthKitMapping.homeTest(forValue: 3) == .indeterminate)
        #expect(CycleHealthKitMapping.homeTest(forValue: 4) == nil)
    }

    // MARK: - Symptom key ↔ HK identifier table

    @Test("symptom identifiers map to seeded catalogue keys (round-trip)")
    func symptomKeyTable() {
        #expect(CycleHealthKitMapping.symptomKeyByIdentifier["HKCategoryTypeIdentifierAbdominalCramps"] == "cramps")
        #expect(CycleHealthKitMapping.symptomKeyByIdentifier["HKCategoryTypeIdentifierMoodChanges"] == "mood_swings")
        #expect(CycleHealthKitMapping.symptomIdentifier(forKey: "cramps") == "HKCategoryTypeIdentifierAbdominalCramps")
        #expect(CycleHealthKitMapping.symptomIdentifier(forKey: "nonexistent") == nil)
    }

    @Test("symptom presence: notPresent(1) is not present; everything else is")
    func symptomPresence() {
        #expect(CycleHealthKitMapping.symptomIsPresent(rawValue: 1) == false)
        #expect(CycleHealthKitMapping.symptomIsPresent(rawValue: 2) == true)
        #expect(CycleHealthKitMapping.symptomIsPresent(rawValue: nil) == true)
    }

    @Test("symptom severity maps HK mild/moderate/severe to 1..3; present→nil")
    func symptomSeverity() {
        #expect(CycleHealthKitMapping.symptomSeverity(rawValue: 3) == 1)
        #expect(CycleHealthKitMapping.symptomSeverity(rawValue: 4) == 2)
        #expect(CycleHealthKitMapping.symptomSeverity(rawValue: 5) == 3)
        #expect(CycleHealthKitMapping.symptomSeverity(rawValue: 2) == nil)
        #expect(CycleHealthKitMapping.symptomSeverity(rawValue: nil) == nil)
    }

    // MARK: - Routing

    @Test("menstrual-flow sample routes to a flow day-log field")
    func routeFlow() {
        let route = CycleHealthKitMapping.route(identifier: CycleHealthKitMapping.menstrualFlow, value: 4)
        #expect(route == .dayLog(.init(flow: .heavy)))
    }

    @Test("sexual-activity sample carries protection metadata when present")
    func routeSexualActivity() {
        let withProt = CycleHealthKitMapping.route(
            identifier: CycleHealthKitMapping.sexualActivity, value: nil, protectionUsed: true
        )
        #expect(withProt == .dayLog(.init(sexualActivity: true, protectedSex: true)))
        let noProt = CycleHealthKitMapping.route(identifier: CycleHealthKitMapping.sexualActivity, value: nil)
        #expect(noProt == .dayLog(.init(sexualActivity: true, protectedSex: nil)))
    }

    @Test("explicit not-present symptom routes to skip")
    func routeNotPresentSymptom() {
        let route = CycleHealthKitMapping.route(identifier: "HKCategoryTypeIdentifierHeadache", value: 1)
        #expect(route == .skip)
    }

    @Test("present symptom routes to a symptom day-log field with severity")
    func routePresentSymptom() {
        let route = CycleHealthKitMapping.route(identifier: "HKCategoryTypeIdentifierHeadache", value: 4)
        #expect(route == .dayLog(.init(symptom: CycleSymptomDTO(key: "headache", severity: 2))))
    }

    @Test("unrecognised flow codepoint and deferred status types skip")
    func routeSkips() {
        #expect(CycleHealthKitMapping.route(identifier: CycleHealthKitMapping.menstrualFlow, value: 99) == .skip)
        #expect(CycleHealthKitMapping.route(identifier: CycleHealthKitMapping.pregnancy, value: 1) == .skip)
        // v0.14.8 — an unrecognised contraceptive codepoint still skips…
        #expect(CycleHealthKitMapping.route(identifier: CycleHealthKitMapping.contraceptive, value: 99) == .skip)
        #expect(CycleHealthKitMapping.route(identifier: CycleHealthKitMapping.contraceptive, value: nil) == .skip)
    }

    // MARK: - v0.14.8 — contraceptive (day-log half of the former 2026-06-20 TODO)

    @Test("contraceptive codepoints map 1:1 to the server's HK_CONTRACEPTIVE_VALUES table")
    func contraceptiveValues() {
        #expect(CycleHealthKitMapping.contraceptive(forValue: 1) == .unspecified)
        #expect(CycleHealthKitMapping.contraceptive(forValue: 2) == .implant)
        #expect(CycleHealthKitMapping.contraceptive(forValue: 3) == .injection)
        #expect(CycleHealthKitMapping.contraceptive(forValue: 4) == .iud)
        #expect(CycleHealthKitMapping.contraceptive(forValue: 5) == .intravaginalRing)
        #expect(CycleHealthKitMapping.contraceptive(forValue: 6) == .oral)
        #expect(CycleHealthKitMapping.contraceptive(forValue: 7) == .patch)
        #expect(CycleHealthKitMapping.contraceptive(forValue: 8) == .emergency)
        #expect(CycleHealthKitMapping.contraceptive(forValue: 0) == nil)
        #expect(CycleHealthKitMapping.contraceptive(forValue: 9) == nil)
    }

    @Test("contraceptive sample routes onto the day-log timeline (no longer skipped)")
    func routeContraceptive() {
        let route = CycleHealthKitMapping.route(identifier: CycleHealthKitMapping.contraceptive, value: 6)
        #expect(route == .dayLog(.init(contraceptive: .oral)))
    }

    @Test("routedIdentifiers covers day-log + symptom types, excludes status + BBT")
    func routedIdentifierSet() {
        #expect(CycleHealthKitMapping.isCycleIdentifier(CycleHealthKitMapping.menstrualFlow))
        #expect(CycleHealthKitMapping.isCycleIdentifier("HKCategoryTypeIdentifierAbdominalCramps"))
        #expect(!CycleHealthKitMapping.isCycleIdentifier(CycleHealthKitMapping.pregnancy))
        #expect(!CycleHealthKitMapping.isCycleIdentifier("HKQuantityTypeIdentifierBasalBodyTemperature"))
    }

    // MARK: - Reverse map (day-log → HK write-back)

    @Test("flow write-back maps SPOTTING and LIGHT both to HK light(2), NONE→none(5)")
    func reverseFlowValues() {
        #expect(CycleHealthKitMapping.vaginalBleedingValue(for: .none) == 5)
        #expect(CycleHealthKitMapping.vaginalBleedingValue(for: .spotting) == 2)
        #expect(CycleHealthKitMapping.vaginalBleedingValue(for: .light) == 2)
        #expect(CycleHealthKitMapping.vaginalBleedingValue(for: .medium) == 3)
        #expect(CycleHealthKitMapping.vaginalBleedingValue(for: .heavy) == 4)
    }

    @Test("enum write-back values round-trip back through the read tables (except SPOTTING)")
    func reverseRoundTrip() {
        for test in CycleOvulationTest.allCases {
            #expect(CycleHealthKitMapping.ovulationTest(forValue: CycleHealthKitMapping.ovulationTestValue(for: test)) == test)
        }
        for mucus in CycleCervicalMucus.allCases {
            #expect(CycleHealthKitMapping.cervicalMucus(forValue: CycleHealthKitMapping.cervicalMucusValue(for: mucus)) == mucus)
        }
        for result in CycleTestResult.allCases {
            #expect(CycleHealthKitMapping.homeTest(forValue: CycleHealthKitMapping.homeTestValue(for: result)) == result)
        }
    }
}
