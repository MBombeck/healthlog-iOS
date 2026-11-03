// App-target symbols (`WellnessScorePresentation`) are not in the SPM
// library; the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **A4 (iOS 1.4) — the sleep score says why a sub-score is missing (#145).**
    ///
    /// Shape from `SleepScoreValue` in `docs/api/openapi.yaml` at `v1.43.10`:
    /// `subScores[]` rows `{ key, value, weight, gap? }` with `gap` only on a
    /// null `consistency` / `timing` (`few_nights` | `no_main_sleep`), plus the
    /// required `rhythmNights` and `rhythmMinNights`. Before this build the
    /// score sheet dropped such a row without a word.
    @Suite("A4: sleep score gaps (#145)")
    struct A4SleepScoreGapTests {
        static func sleepScore(consistencyGap: String, rhythmNights: Int = 2, rhythmMinNights: Int = 3) -> String {
            """
            {"metric":"SLEEP_SCORE","status":"ok",
             "value":{"score":71,"band":"green","night":"2026-10-20","asleepMinutes":410,"inBedMinutes":470,
                      "subScores":[
                        {"key":"sufficiency","value":88,"weight":0.4},
                        {"key":"efficiency","value":80,"weight":0.3},
                        {"key":"consistency","value":null,"weight":0,"gap":"\(consistencyGap)"},
                        {"key":"timing","value":null,"weight":0,"gap":"\(consistencyGap)"},
                        {"key":"composition","value":70,"weight":0.3}],
                      "windowNights":2,"rhythmNights":\(rhythmNights),"rhythmMinNights":\(rhythmMinNights),
                      "series":[69,71]},
             "coverage":{"requiredInputs":3,"presentInputs":3,"historyDays":2,"missing":[]},
             "confidence":{"score":40,"band":"low"},
             "provenance":{"inputs":["SLEEP_DURATION"],"source":"DAY","windowDays":30,
                           "computedAt":"2026-10-20T08:00:00+02:00"},
             "reason":null}
            """
        }

        static func decode(_ json: String) throws -> DerivedMetricDTO {
            try JSONDecoder.hlDefault.decode(DerivedMetricDTO.self, from: Data(json.utf8))
        }

        @Test("gap and the rhythm counts decode off the v1.43.10 shape")
        func decodes() throws {
            let dto = try Self.decode(Self.sleepScore(consistencyGap: "few_nights"))
            #expect(dto.value?.rhythmNights == 2)
            #expect(dto.value?.rhythmMinNights == 3)
            #expect(dto.value?.contributors?.first { $0.key == "consistency" }?.gap == "few_nights")
            #expect(dto.value?.contributors?.first { $0.key == "sufficiency" }?.gap == nil)
        }

        @Test("too few nights: the row stays and says how many it needs and has")
        func fewNightsRow() throws {
            let ranked = try WellnessScorePresentation.rankedContributors(Self.decode(Self.sleepScore(consistencyGap: "few_nights")))
            let consistency = try #require(ranked.first { $0.key == "consistency" })
            #expect(consistency.value == nil)
            #expect(consistency.gapReason == String(localized: "sleep.score.gap.fewNights \(3) \(2)"))
            #expect(consistency.valueText.isEmpty, "no dash in place of a value")
            #expect(ranked.contains { $0.key == "timing" })
            // Scored rows first, by weight; the withheld rows after them.
            #expect(ranked.count == 5)
            #expect(ranked.first?.key == "sufficiency")
            #expect(ranked.prefix(3).allSatisfy { $0.value != nil && $0.gapReason == nil })
            #expect(ranked.suffix(2).allSatisfy { $0.gapReason != nil })
        }

        @Test("only a nap last time: the row says so")
        func noMainSleepRow() throws {
            let ranked = try WellnessScorePresentation.rankedContributors(Self.decode(Self.sleepScore(consistencyGap: "no_main_sleep")))
            let timing = try #require(ranked.first { $0.key == "timing" })
            #expect(timing.gapReason == String(localized: "sleep.score.gap.noMainSleep"))
        }

        @Test("counts that do not explain the gap fall back to the plain sentence")
        func fewNightsWithoutUsableCounts() {
            #expect(SleepScoreGap.fewNights.reasonLine(nights: nil, minimum: 3) == String(localized: "sleep.score.gap.fewNightsPlain"))
            #expect(SleepScoreGap.fewNights.reasonLine(nights: 3, minimum: 3) == String(localized: "sleep.score.gap.fewNightsPlain"))
        }

        @Test("an unknown gap token, and a null without a gap, stay hidden as before")
        func unknownStaysHidden() throws {
            let unknown = try WellnessScorePresentation.rankedContributors(Self.decode(Self.sleepScore(consistencyGap: "future_reason")))
            #expect(!unknown.contains { $0.key == "consistency" || $0.key == "timing" })
            let readiness = DerivedMetricDTO.Value(
                score: 78, band: "green",
                components: [.init(key: "respiratory", value: nil, weight: 0), .init(key: "rhr", value: 90, weight: 0.5)]
            )
            let dto = DerivedMetricDTO(
                metric: "READINESS", status: "ok", value: readiness,
                coverage: .init(requiredInputs: 2, presentInputs: 1, historyDays: 30, missing: []),
                confidence: nil,
                provenance: .init(inputs: [], source: "DAY", windowDays: 30, computedAt: Date(timeIntervalSince1970: 0)),
                reason: nil
            )
            #expect(WellnessScorePresentation.rankedContributors(dto).map(\.key) == ["rhr"])
        }
    }
#endif
