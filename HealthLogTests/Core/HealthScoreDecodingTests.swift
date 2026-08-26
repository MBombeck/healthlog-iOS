import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **CU-31 — locks the Health Score v2 decode (server v1.34.0).**
///
/// The wire is `GET /api/dashboard/snapshot` → `healthScore`, whose eleven keys
/// the live builder always sends but whose TypeScript type marks eight of them
/// optional so stale cached snapshot cells stay valid
/// (`src/lib/dashboard/snapshot.ts:326-364`). Only `score` / `band` / `delta`
/// are contractual here; everything else decodes strictly optional, and both
/// growable enums (`ScorePillarId`, `ScoreDeltaReason`) tolerate an unknown
/// token instead of throwing the score away.
@Suite("HealthScore v2 decoding")
struct HealthScoreDecodingTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractional
        return d
    }()

    // MARK: - Acceptance: the full and the minimal fixture

    /// The FULL fixture: every one of the eleven keys the live v1.34 builder
    /// sends, with values taken from the shapes in `WIRE-SHAPES-v134.md §6`.
    private static let fullFixture = #"""
    {
      "score": 71,
      "band": "yellow",
      "delta": null,
      "confidence": { "score": 82, "band": "high" },
      "composition": ["BLOOD_PRESSURE","GLYCAEMIA","ACTIVITY","SLEEP","ADIPOSITY","WELLBEING","FITNESS","LIPIDS"],
      "deltaReason": "algorithm_changed",
      "scoreVersion": 2,
      "bandSetter": "SLEEP",
      "restMode": { "active": true, "since": "2026-07-24T06:00:00.000Z", "episodeCount": 2 },
      "tension": { "band": "yellow", "positive": ["hrv"], "negative": ["rhr","sleep"] },
      "returnToBand": { "metricType": "RESTING_HEART_RATE", "daysInside": 3 }
    }
    """#

    /// The MINIMAL fixture: only the three contractual fields.
    private static let minimalFixture = #"""
    { "score": 64, "band": "yellow", "delta": -2 }
    """#

    @Test("the FULL v1.34 fixture decodes every optional field")
    func fullFixtureDecodes() throws {
        let score = try decoder.decode(HealthScore.self, from: Data(Self.fullFixture.utf8))

        #expect(score.score == 71)
        #expect(score.band == .yellow)
        // `delta` and `deltaReason` are mutually exclusive on the wire.
        #expect(score.delta == nil)
        #expect(score.deltaReason == .algorithmChanged)
        #expect(score.scoreVersion == 2)

        let confidence = try #require(score.confidence)
        #expect(confidence.score == 82)
        #expect(confidence.band == .high)

        // All eight pillars, in the server's declared registry order.
        #expect(score.composition == HealthScorePillar.known)
        #expect(score.bandSetter == .sleep)

        let rest = try #require(score.activeRestMode)
        #expect(rest.episodeCount == 2)
        #expect(rest.since != nil)
    }

    /// The two undocumented-but-shipped keys (`tension` / `returnToBand`,
    /// missing from the OpenAPI schema which is `additionalProperties: false`)
    /// must be ignored, not rejected. The full fixture above carries both.
    @Test("undocumented extra keys never fail the decode")
    func toleratesUndocumentedKeys() throws {
        let score = try decoder.decode(HealthScore.self, from: Data(Self.fullFixture.utf8))
        #expect(score.score == 71)
    }

    @Test("the MINIMAL fixture decodes with every optional field nil")
    func minimalFixtureDecodes() throws {
        let score = try decoder.decode(HealthScore.self, from: Data(Self.minimalFixture.utf8))

        #expect(score.score == 64)
        #expect(score.band == .yellow)
        #expect(score.delta == -2)
        #expect(score.confidence == nil)
        #expect(score.composition == nil)
        #expect(score.deltaReason == nil)
        #expect(score.scoreVersion == nil)
        #expect(score.bandSetter == nil)
        #expect(score.restMode == nil)
        // A real delta is present, so it IS narratable.
        #expect(score.suppressesDeltaNarrative == false)
        #expect(score.narratableDelta == -2)
    }

    @Test("explicit JSON nulls on the optional fields decode as nil, not as a failure")
    func explicitNullsDecode() throws {
        let json = Data(#"""
        {
          "score": 55, "band": "yellow", "delta": 1,
          "confidence": null, "composition": null, "deltaReason": null,
          "scoreVersion": null, "bandSetter": null, "restMode": null
        }
        """#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.score == 55)
        #expect(score.deltaReason == nil)
        #expect(score.bandSetter == nil)
        #expect(score.restMode == nil)
    }

    // MARK: - Tolerant enums

    @Test("all six deltaReason literals decode", arguments: [
        ("algorithm_changed", HealthScoreDeltaReason.algorithmChanged),
        ("composition_changed", .compositionChanged),
        ("first_eligibility_window", .firstEligibilityWindow),
        ("below_noise_floor", .belowNoiseFloor),
        ("no_previous_window", .noPreviousWindow),
        ("no_current_score", .noCurrentScore)
    ])
    func deltaReasonLiterals(raw: String, expected: HealthScoreDeltaReason) throws {
        let json = Data(#"{"score":50,"band":"red","delta":null,"deltaReason":"\#(raw)"}"#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.deltaReason == expected)
    }

    @Test("an unknown deltaReason falls back to .unknown and keeps the score")
    func unknownDeltaReason() throws {
        let json = Data(#"{"score":50,"band":"red","delta":null,"deltaReason":"planet_alignment"}"#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.score == 50)
        #expect(score.deltaReason == .unknown("planet_alignment"))
        // An unknown reason is not claimed to be a measurement artefact.
        #expect(score.deltaReason?.isMeasurementArtefact == false)
        // But it still suppresses the week-over-week narrative — we do not
        // invent a story for a reason we cannot read.
        #expect(score.suppressesDeltaNarrative)
    }

    @Test("all eight pillar literals decode", arguments: [
        ("BLOOD_PRESSURE", HealthScorePillar.bloodPressure),
        ("GLYCAEMIA", .glycaemia),
        ("ACTIVITY", .activity),
        ("SLEEP", .sleep),
        ("ADIPOSITY", .adiposity),
        ("WELLBEING", .wellbeing),
        ("FITNESS", .fitness),
        ("LIPIDS", .lipids)
    ])
    func pillarLiterals(raw: String, expected: HealthScorePillar) throws {
        let json = Data(#"{"score":80,"band":"green","delta":0,"composition":["\#(raw)"]}"#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.composition == [expected])
    }

    @Test("an unknown pillar keeps its place instead of poisoning the composition")
    func unknownPillar() throws {
        let json = Data(#"""
        {"score":80,"band":"green","delta":0,
         "composition":["ACTIVITY","IMMUNITY","SLEEP"],
         "bandSetter":"IMMUNITY"}
        """#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.composition == [.activity, .unknown("IMMUNITY"), .sleep])
        #expect(score.bandSetter == .unknown("IMMUNITY"))
    }

    @Test("an unknown band token decodes as nil and the score survives")
    func unknownBandToken() throws {
        let json = Data(#"{"score":90,"band":"turquoise","delta":2}"#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.score == 90)
        #expect(score.band == nil)
        // The local colour thresholds take over for the UI only.
        #expect(score.displayBand == .green)
    }

    @Test("an unknown confidence band decodes as .unknown, never as a known one")
    func unknownConfidenceBand() throws {
        let json = Data(#"{"score":90,"band":"green","delta":2,"confidence":{"score":40,"band":"provisional"}}"#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.confidence?.band == .unknown("provisional"))
        #expect(score.confidence?.score == 40)
    }

    @Test("all four confidence bands decode", arguments: [
        ("high", HealthScoreConfidenceBand.high),
        ("medium", .medium),
        ("low", .low),
        ("draft", .draft)
    ])
    func confidenceBands(raw: String, expected: HealthScoreConfidenceBand) throws {
        let json = Data(#"{"score":90,"band":"green","delta":2,"confidence":{"score":70,"band":"\#(raw)"}}"#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.confidence?.band == expected)
    }

    @Test("all three score-band tokens decode")
    func bandTokens() throws {
        for raw in ["green", "yellow", "red"] {
            let band = try decoder.decode(HealthScoreBand.self, from: Data("\"\(raw)\"".utf8))
            #expect(band.rawValue == raw)
        }
    }

    // MARK: - "The measurement changed, not you"

    /// The rule this ticket exists for. `algorithm_changed` — plus the other
    /// three reasons rooted in *how* the number is produced — must be
    /// classified as measurement artefacts so no surface narrates them as a
    /// change in the person. `no_previous_window` / `no_current_score` are
    /// plain absences and are not dressed up as method changes.
    @Test("measurement-artefact classification", arguments: [
        (HealthScoreDeltaReason.algorithmChanged, true),
        (.compositionChanged, true),
        (.firstEligibilityWindow, true),
        (.belowNoiseFloor, true),
        (.noPreviousWindow, false),
        (.noCurrentScore, false),
        (.unknown("x"), false)
    ])
    func measurementArtefacts(reason: HealthScoreDeltaReason, isArtefact: Bool) {
        #expect(reason.isMeasurementArtefact == isArtefact)
    }

    /// Belt-and-braces: even if a future server sent BOTH a delta and a reason
    /// (the current one never does), the reason wins and the delta is not told
    /// as a change in the user.
    @Test("a deltaReason suppresses the narrative even next to a non-null delta")
    func reasonBeatsDelta() throws {
        let json = Data(#"{"score":80,"band":"green","delta":9,"deltaReason":"algorithm_changed"}"#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.delta == 9)
        #expect(score.narratableDelta == nil)
        #expect(score.suppressesDeltaNarrative)
    }

    // MARK: - Rest Mode (v1.18.3, server-authoritative annotation)

    @Test("Decodes an active Rest Mode annotation on the score object")
    func restModeActive() throws {
        let json = Data(#"""
        {
            "score": 64, "band": "yellow", "delta": -2,
            "restMode": { "active": true, "since": "2026-06-14T09:00:00.000Z", "episodeCount": 1 }
        }
        """#.utf8)

        let score = try decoder.decode(HealthScore.self, from: json)
        let rest = try #require(score.restMode)
        #expect(rest.active == true)
        #expect(rest.episodeCount == 1)
        #expect(rest.since != nil)
        // The score itself is NEVER penalised by the annotation — mirror only.
        #expect(score.score == 64)
        #expect(score.activeRestMode != nil)
    }

    @Test("An inactive Rest Mode annotation does not surface via activeRestMode")
    func restModeInactive() throws {
        let json = Data(#"""
        {
            "score": 80, "band": "green", "delta": 3,
            "restMode": { "active": false, "since": null, "episodeCount": 0 }
        }
        """#.utf8)

        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.restMode?.active == false)
        #expect(score.activeRestMode == nil)
    }

    @Test("A null Rest Mode field decodes to nil — no Rest Mode")
    func restModeNull() throws {
        let json = Data(#"{"score":80,"band":"green","delta":3,"restMode":null}"#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.restMode == nil)
        #expect(score.activeRestMode == nil)
    }

    @Test("An absent Rest Mode field is tolerated (older servers) — nil, no throw")
    func restModeAbsent() throws {
        let json = Data(#"{"score":80,"band":"green","delta":3}"#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        #expect(score.restMode == nil)
        #expect(score.activeRestMode == nil)
    }

    @Test("A shapeless Rest Mode object stays tolerant (missing since / episodeCount)")
    func restModeShapeless() throws {
        let json = Data(#"{"score":70,"band":"yellow","delta":null,"restMode":{"active":true}}"#.utf8)
        let score = try decoder.decode(HealthScore.self, from: json)
        let rest = try #require(score.restMode)
        #expect(rest.active == true)
        #expect(rest.since == nil)
        #expect(rest.episodeCount == 0)
        #expect(score.activeRestMode != nil)
    }
}
