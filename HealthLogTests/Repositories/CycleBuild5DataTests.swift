import Foundation
@testable import HealthLog
import Testing

@Suite("Cycle Build 5 wire contracts")
struct CycleBuild5DataTests {
    @Test("Profile patch preserves absent, clear, and set priors without enabled")
    func profilePatchTriState() throws {
        let patch = CyclePrefsPatch(
            goal: .generalHealth,
            rawChartMode: true,
            typicalCycleLength: .clear,
            typicalPeriodLength: .set(6),
            lutealPhaseLength: .unchanged,
            predictionEnabled: false,
            discreetNotifications: true,
            sensitiveCategoryEncryption: true,
            secondarySymptom: .cervix
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any]
        )
        #expect(object["enabled"] == nil)
        #expect(object["typicalCycleLength"] is NSNull)
        #expect(object["typicalPeriodLength"] as? Int == 6)
        #expect(object["lutealPhaseLength"] == nil)
        #expect(object["sensitiveCategoryEncryption"] as? Bool == true)
        #expect(object.count == 8)
    }

    @Test("Build 9 (9.3) — CyclePrefsPatch(enabled:) serialises exactly {\"enabled\":…} (deep-merge safety)")
    func enabledWriteLegIsIsolated() throws {
        // A bare enabled toggle must carry ONLY `enabled` — the deep-merge route
        // touches nothing else.
        let onObject = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(CyclePrefsPatch(enabled: true))
            ) as? [String: Any]
        )
        #expect(onObject["enabled"] as? Bool == true)
        #expect(onObject.count == 1)

        let offObject = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(CyclePrefsPatch(enabled: false))
            ) as? [String: Any]
        )
        #expect(offObject["enabled"] as? Bool == false)
        #expect(offObject.count == 1)

        // A patch that does not set `enabled` omits the key entirely.
        let absentObject = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(CyclePrefsPatch(goal: .generalHealth))
            ) as? [String: Any]
        )
        #expect(absentObject.keys.contains("enabled") == false)
    }

    @Test("Day-log patch sends null clears and an empty symptom array")
    func dayLogPatchClears() throws {
        let patch = CycleDayLogPatch(
            flow: .clear,
            intermenstrualBleeding: false,
            basalBodyTempC: .clear,
            temperatureExcluded: false,
            ovulationTest: .clear,
            cervicalMucus: .clear,
            cervixPosition: .clear,
            cervixFirmness: .clear,
            cervixOpening: .clear,
            sexualActivity: false,
            protectedSex: .clear,
            pregnancyTest: .clear,
            progesteroneTest: .clear,
            contraceptive: .set(.none),
            symptoms: .set([]),
            note: .clear,
            loggedAt: "2026-07-20T08:00:00Z"
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any]
        )
        #expect(object["flow"] is NSNull)
        #expect(object["basalBodyTempC"] is NSNull)
        #expect(object["protectedSex"] is NSNull)
        #expect(object["note"] is NSNull)
        #expect(object["contraceptive"] as? String == "NONE")
        #expect((object["symptoms"] as? [Any])?.isEmpty == true)
        #expect(object["date"] == nil)
        #expect(object["source"] == nil)
        #expect(object["externalId"] == nil)
    }

    @Test("Custom symptom DTO tolerates nulls and unknown additive fields")
    func customSymptomFixture() throws {
        let data = Data(
            #"{"symptoms":[{"key":"custom:7ef4","label":"Migräne","icon":"UnknownFutureIcon","custom":true,"future":1},{"key":"custom:empty","label":null,"icon":null}]}"#
                .utf8
        )
        let response = try JSONDecoder.hlDefault.decode(CycleCustomSymptomsResponse.self, from: data)
        #expect(response.symptoms.count == 2)
        #expect(response.symptoms[0].label == "Migräne")
        #expect(response.symptoms[0].safeSystemImage == "tag")
        #expect(response.symptoms[1].displayLabel == nil)
        #expect(response.symptoms[1].custom)
    }

    @Test("Insights fixture tolerates unknown metric, display, confidence, and phase")
    func insightsFixtureTolerance() throws {
        let data = Data(#"""
        {
          "rows":[{"metricKey":"futureMetric","display":"futureUnit","lutealDays":9,"follicularDays":10,"lutealAvg":1.2,"follicularAvg":1.0,"delta":0.2,"pValue":0.01,"qValue":0.07,"confidence":"future"}],
          "headline":null,
          "lagged":{"discovered":[],"pairsTested":6,"fdrQ":0.1,"minPairs":8},
          "symptomPatterns":[{"symptomKey":"custom:deadbeef","counts":{"MENSTRUAL":1,"FOLLICULAR":2,"OVULATORY":0,"LUTEAL":3,"FUTURE":9},"total":6,"topPhase":"FUTURE","topShare":0.5}],
          "contrast":{"high":"LUTEAL","low":"FOLLICULAR"},
          "windowDays":365,"cyclesObserved":5,"future":true
        }
        """#.utf8)
        let response = try JSONDecoder.hlDefault.decode(CycleInsightsDTO.self, from: data)
        #expect(response.rows.first?.metricKey == "futureMetric")
        #expect(response.rows.first?.displayValue == .unknown)
        #expect(response.rows.first?.confidenceValue == .unknown)
        #expect(response.symptomPatterns.first?.topPhaseValue == nil)
        #expect(response.symptomPatterns.first?.counts.luteal == 3)
        #expect(response.headline == nil)
    }

    @Test("Empty FDR payload is a valid learning state")
    func emptyInsightsFixture() throws {
        let data = Data(
            #"{"rows":[],"headline":null,"lagged":{"discovered":[],"pairsTested":0,"fdrQ":0.1,"minPairs":8},"symptomPatterns":[],"contrast":{"high":"LUTEAL","low":"FOLLICULAR"},"windowDays":365,"cyclesObserved":1}"#
                .utf8
        )
        let response = try JSONDecoder.hlDefault.decode(CycleInsightsDTO.self, from: data)
        #expect(response.isLearning)
    }

    @Test("Cycle edit outbox preserves tri-state patch and decodes legacy write payload")
    func cycleEditOutboxPayload() throws {
        let payload = OutboxQueue.Payloads.UpdateCycleDayLog(
            id: "row-1",
            patch: CycleDayLogPatch(flow: .clear, symptoms: .set([]), note: .clear)
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        #expect(object["write"] == nil)
        let patchObject = try #require(object["patch"] as? [String: Any])
        #expect(patchObject["flow"] is NSNull)
        #expect((patchObject["symptoms"] as? [Any])?.isEmpty == true)

        let legacy = Data(#"""
        {
          "id":"row-1",
          "write":{"date":"2026-07-20","flow":null,"symptoms":[],"note":null,
                   "loggedAt":"2026-07-20T08:00:00Z","source":"MANUAL"}
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(OutboxQueue.Payloads.UpdateCycleDayLog.self, from: legacy)
        #expect(decoded.patch.flow == .clear)
        #expect(decoded.patch.symptoms == .set([]))
        #expect(decoded.patch.note == .clear)
    }
}
