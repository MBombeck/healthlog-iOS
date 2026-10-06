import Foundation
@testable import HealthLog
import Testing

// #115 · 1.7 — every server-owned enum decodes a value this build does not
// know into its neutral fallback, and the SURROUNDING payload still decodes.
//
// Each case feeds one enum an invented wire word (`"zz_from_the_future"`)
// inside the smallest real payload that carries it, decodes that payload the
// way the app does (`JSONDecoder.hlDefault` on the envelope's `data`), and
// checks both halves: the payload is there, and the field is the fallback —
// not a guess. Payload shapes follow `docs/api/openapi.yaml` at server tag
// v1.39.0 (field names per schema; the enum word is the only invention).

private let novel = "zz_from_the_future"

private func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
    try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
}

/// One enum's probe. `check` throws (decode failure) or records an issue.
struct ServerEnumProbe: Sendable, CustomTestStringConvertible {
    let name: String
    let check: @Sendable () throws -> Void

    var testDescription: String {
        name
    }
}

private let probes: [ServerEnumProbe] = [
    // MARK: Digest + dashboard + targets

    ServerEnumProbe(name: "TrendDirection (digest slope)") {
        let json = #"""
        {"summary":"s","summaries":{"weight":{"count":3,"latest":80,"min":79,"max":81,"mean":80,
         "slope7":{"slope":0.2,"direction":"\#(novel)","confidence":0.4}}},"bmi":24.2}
        """#
        let response = try decode(AIInsightResponse.self, json)
        let digest = try #require(response.digest)
        #expect(digest.summaries?["weight"]?.slope7?.direction == .unknown)
    },
    ServerEnumProbe(name: "TrendIndicator (dashboard tile)") {
        let json = #"""
        {"id":"m1","kind":"weight","title":"Weight","latestValue":80,"unit":"kg",
         "trend":"\#(novel)","sparkline":[80,81]}
        """#
        let metric = try decode(DashboardMetric.self, json)
        #expect(metric.trend == .unknown)
        #expect(metric.latestValue == 80)
    },
    ServerEnumProbe(name: "InsightsTargetsDTO.Trend + ConsistencyBucket") {
        let json = #"""
        {"type":"weight","label":"Weight","current":80,"average30":81,"trend":"\#(novel)","unit":"kg",
         "range":{"min":70,"max":78},"classification":null,"source":"target","daysInRange7d":1,
         "daysLogged7d":3,"daysInRange30d":4,"daysLogged30d":12,"lastMetGoalAt":null,"streakDays":0,
         "insufficientData":false,"consistency7d":["in",null,"\#(novel)"]}
        """#
        let item = try decode(InsightsTargetsResponseDTO.TargetItem.self, json)
        #expect(item.trend == .unknown)
        #expect(item.consistency7d == [.inBand, nil, .unknown])
    },

    // MARK: AI insight

    ServerEnumProbe(name: "RecommendationSeverity") {
        let json = #"""
        {"summary":"s","recommendations":[{"id":"r1","text":"Walk","severity":"\#(novel)"}]}
        """#
        let response = try decode(AIInsightResponse.self, json)
        #expect(response.recommendations.first?.severity == .unknown)
    },
    ServerEnumProbe(name: "WarningSeverity") {
        let json = #"""
        {"summary":"s","warnings":[{"topic":"bp","message":"m","severity":"\#(novel)"}]}
        """#
        let response = try decode(AIInsightResponse.self, json)
        #expect(response.warnings.first?.severity == .unknown)
    },
    ServerEnumProbe(name: "KeyFindingTone") {
        let json = #"""
        {"summary":"s","dailyBriefing":{"paragraph":"p",
         "keyFindings":[{"tone":"\#(novel)","headline":"h","detail":"d","sourceWindow":"7d","sourceMetric":"weight"}],
         "signalsOfDay":[{"sourceMetric":"pulse","tone":"\#(novel)","headline":"h","nudge":"n"}]}}
        """#
        let response = try decode(AIInsightResponse.self, json)
        let briefing = try #require(response.dailyBriefing)
        #expect(briefing.keyFindings.first?.tone == .unknown)
        #expect(briefing.signalsOfDay.first?.tone == .unknown)
    },
    ServerEnumProbe(name: "InsightSeverity") {
        let json = #"""
        {"id":"i1","title":"t","summary":"s","severity":"\#(novel)","recommendations":[],
         "generatedAt":"2026-09-24T08:00:00.000Z","provider":"anthropic"}
        """#
        let insight = try decode(Insight.self, json)
        #expect(insight.severity == .unknown)
    },

    // MARK: Records, mood, notifications

    ServerEnumProbe(name: "PersonalRecordDTO.Direction") {
        let json = #"""
        {"id":"pr1","userId":"u1","metricType":"STEPS","metricSlot":null,"direction":"\#(novel)","value":21000,
         "unit":"steps","achievedAt":"2026-09-20T00:00:00.000Z","sourceMeasurementId":null,"source":"APPLE_HEALTH",
         "externalId":null,"createdAt":"2026-09-20T00:00:00.000Z"}
        """#
        let record = try decode(PersonalRecordDTO.self, json)
        #expect(record.direction == .unknown)
        #expect(record.value == 21000)
    },
    ServerEnumProbe(name: "MoodTagKind") {
        let json = #"""
        {"key":"slept_well","labelKey":"mood.tag.slept_well","icon":null,"kind":"\#(novel)","scaleMin":1,"scaleMax":5}
        """#
        let tag = try decode(MoodTagDTO.self, json)
        #expect(tag.kind == .unknown)
        #expect(tag.isRated == false)
    },
    ServerEnumProbe(name: "BetterDayFactor.Direction + Source") {
        let json = #"""
        {"source":"\#(novel)","key":"sleep","direction":"\#(novel)","n":12,"confidence":"medium","r":0.4}
        """#
        let factor = try decode(BetterDayFactor.self, json)
        #expect(factor.direction == .unknown)
        #expect(factor.source == .unknown)
        #expect(factor.isPositive == false)
    },
    ServerEnumProbe(name: "NotificationChannelStatus.ChannelState") {
        let json = #"""
        {"channels":[{"id":"c1","type":"apns","label":"iPhone","enabled":true,"state":"\#(novel)",
          "disabledReason":null,"consecutiveFailures":0,"lastSuccessAt":null,"lastFailureAt":null,
          "lastFailureReason":null,"nextRetryAt":null}]}
        """#
        let payload = try decode(NotificationStatusPayload.self, json)
        #expect(payload.channels.first?.state == .unknown)
    },

    // MARK: Sync + ingest answers

    ServerEnumProbe(name: "SyncDirection (and the PATCH round-trip keeps the wire word)") {
        let json = #"""
        {"entries":[{"id":"e1","kind":"bodyMass","direction":"\#(novel)","enabled":true},
                    {"id":"e2","kind":"heartRate","direction":"readOnly","enabled":false}],"lastSyncedAt":null}
        """#
        let config = try decode(HealthKitSyncConfig.self, json)
        #expect(config.entries.map(\.direction) == [.unknown, .readOnly])
        let toggled = config.entries[0].withEnabled(false)
        let body = try JSONEncoder().encode(toggled)
        let echoed = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(echoed["direction"] as? String == novel)
    },
    ServerEnumProbe(name: "EcgIngestStatus (unknown is not confirmed storage)") {
        let json = #"""
        {"id":"ecg1","status":"\#(novel)","recordedAt":"2026-09-20T07:00:00.000Z","sampleCount":15360,"durationSeconds":30}
        """#
        let response = try decode(EcgIngestResponseDTO.self, json)
        #expect(response.status == .unknown)
        #expect(response.status.isConfirmedStored == false)
    },
    ServerEnumProbe(name: "NutrientEntryStatus") {
        let json = #"""
        {"processed":2,"inserted":1,"updated":0,"skipped":[],
         "entries":[{"index":0,"status":"inserted"},{"index":1,"status":"\#(novel)","reason":null}]}
        """#
        let response = try decode(NutrientBatchResponseDTO.self, json)
        #expect(response.entries.map(\.status) == [.inserted, .unknown])
    },
    ServerEnumProbe(name: "SleepRhythmDTO states (unknown block dropped, siblings kept)") {
        // Existing equivalent (SleepRhythmDecodeTests): a block whose state is
        // unknown is dropped on its own; the other blocks still render.
        let json = #"""
        {"sleepDebt":{"state":"\#(novel)","debtMinutes":40,"needMinutes":480,"nightsCounted":5,"windowNights":5,"nightsUntilReady":0},
         "averagePerNight":{"state":"ready","averageMinutes":430,"nightsCounted":20,"nightsUntilReady":0},
         "chronotype":{"state":"\#(novel)","freeNightsCounted":2,"workNightsCounted":5,"freeNightsUntilReady":2}}
        """#
        let rhythm = try decode(SleepRhythmDTO.self, json)
        #expect(rhythm.sleepDebt == nil)
        #expect(rhythm.chronotype == nil)
        #expect(rhythm.averagePerNight?.averageMinutes == 430)
    },
    ServerEnumProbe(name: "TourProgress.Status") {
        let json = #"""
        {"lastStopId":"mood","completedStopIds":["dashboard"],"status":"\#(novel)","updatedAt":"2026-09-20T07:00:00.000Z"}
        """#
        let progress = try decode(TourProgress.self, json)
        #expect(progress.status == .unknown)
        #expect(progress.lastStopId == "mood")
    },
    ServerEnumProbe(name: "AnamnesisFactKind (unknown kind row skipped, payload kept)") {
        let json = #"""
        {"current":{"SMOKING_STATUS":null,"\#(novel)":null},
         "history":[{"id":"f1","kind":"\#(novel)","value":"X","validFrom":"2026-09-01T00:00:00.000Z",
                     "validUntil":null,"recordedAt":"2026-09-01T00:00:00.000Z"}]}
        """#
        let payload = try decode(AnamnesisFactsPayload.self, json)
        #expect(payload.history.isEmpty)
        #expect(payload.current.isEmpty)
    },

    ServerEnumProbe(name: "IllnessDeviationDirection (was coerced to .above)") {
        let json = #"""
        {"type":"RESTING_HEART_RATE","day":"2026-09-20","value":71,"baselineCenter":58,"deviationSd":2.4,
         "direction":"\#(novel)","adverse":true}
        """#
        let deviation = try decode(IllnessVitalDeviation.self, json)
        #expect(deviation.direction == .unknown)
        #expect(deviation.deviationSd == 2.4)
    },

    // MARK: v1.39 weight-trend sentiment

    ServerEnumProbe(name: "TrendDirectionSentiment (hold known, novel word neutral)") {
        let known = try decode([TrendDirectionSentiment].self, #"["up-good","up-bad","hold","\#(novel)"]"#)
        #expect(known == [.upGood, .upBad, .hold, .unknown])
    },

    // MARK: v1.39.4 medication course

    ServerEnumProbe(name: "MedicationCourseStatus (R1)") {
        let json = #"""
        {"id":"m1","name":"Amoxicillin","dose":"500 mg","courseStatus":"\#(novel)","intakeActionable":true}
        """#
        let medication = try decode(MedicationWireDTO.self, json)
        #expect(medication.courseStatus == .unknown)
        #expect(medication.intakeActionable == true)
    }
]

@Suite("#115 1.7 — tolerant server enums")
struct TolerantServerEnumTests {
    @Test("An unknown value decodes to the fallback and keeps the payload", arguments: probes)
    func unknownValueKeepsPayload(_ probe: ServerEnumProbe) throws {
        try probe.check()
    }

    @Test("The helper maps an unknown word to the fallback and keeps known words")
    func helperBasics() throws {
        let values = try decode([TrendIndicator].self, #"["up","\#(novel)","flat","FLAT"]"#)
        #expect(values == [.up, .unknown, .flat, .unknown])
    }

    @Test("A non-string is schema drift, not a new value — it still throws")
    func helperRejectsNonString() {
        #expect(throws: DecodingError.self) {
            try decode([TrendIndicator].self, #"[42]"#)
        }
    }

    @Test("Lossy array keeps the good rows when one row is malformed")
    func lossyArraySkipsBadRow() throws {
        // `text` is present, `metricSource` is the wrong type in row 2.
        let json = #"""
        {"summary":"s","recommendations":[{"id":"a","text":"one"},{"id":"b","text":"two","metricSource":7},{"id":"c","text":"three"}]}
        """#
        let response = try decode(AIInsightResponse.self, json)
        #expect(response.recommendations.map(\.id) == ["a", "c"])
    }

    @Test("hold: level is progress, a move either way is neutral")
    func holdSentiment() {
        #expect(TrendDirectionSentiment.hold.tone(for: .level) == .favorable)
        #expect(TrendDirectionSentiment.hold.tone(for: .rising) == .neutral)
        #expect(TrendDirectionSentiment.hold.tone(for: .falling) == .neutral)
        #expect(TrendDirectionSentiment.upBad.tone(for: .falling) == .favorable)
        #expect(TrendDirectionSentiment.upGood.tone(for: .falling) == .adverse)
        #expect(TrendDirectionSentiment.unknown.tone(for: .rising) == .neutral)
    }
}

/// The digest regression on its own (#115 · 1.7): one unknown trend word used
/// to turn the WHOLE comprehensive digest into `nil` via the `try?` in
/// `AIInsightResponse.init(from:)`.
@Suite("#115 1.7 — comprehensive digest survives an unknown trend direction")
struct DigestUnknownTrendDirectionTests {
    @Test("Digest is not nil and keeps its other fields")
    func digestSurvives() throws {
        let json = #"""
        {"data":{"summary":"Weekly","bmi":24.2,"bpPctInTarget":71,
          "summaries":{"weight":{"count":14,"latest":80.1,"min":79.4,"max":81.0,"mean":80.2,"avg7":80.0,"avg30":80.4,
            "slope7":{"slope":-0.05,"direction":"sideways","confidence":0.3},
            "slope30":{"slope":-0.02,"direction":"down","confidence":0.6}}}},"error":null}
        """#
        let envelope = try JSONDecoder.hlDefault.decode(APIEnvelope<AIInsightResponse>.self, from: Data(json.utf8))
        let digest = try #require(envelope.data?.digest)
        #expect(digest.bmi == 24.2)
        #expect(digest.bpPctInTarget == 71)
        #expect(digest.summaries?["weight"]?.slope7?.direction == .unknown)
        #expect(digest.summaries?["weight"]?.slope30?.direction == .down)
    }
}
