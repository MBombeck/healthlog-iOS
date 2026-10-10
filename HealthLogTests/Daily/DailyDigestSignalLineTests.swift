import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **1.2 V5 (#121, server v1.40.2 / v1.40.3)** — the Today lead and the muted
/// line under it are decided on the server, so the hero renders them as
/// delivered and only an older server keeps the line built from `topSignal`.
///
/// Fixture texts are the server's own (`src/lib/daily/__tests__/today-overview.test.ts`
/// and `docs/api/openapi.yaml` `DailyDigest` on `release/v1.42.0` @ `f8dab58bc`).
@Suite("DailyDigest — signalLine, lead and v1.40 fields (1.2 V5)")
struct DailyDigestSignalLineTests {
    static let headline = "Your latest blood pressure is sitting in the optimal band."
    static let delta = "↓ ~10 mmHg systolic vs the start of the window"
    static let briefingLead =
        "Your most recent blood pressure sits comfortably in the optimal band, and resting heart rate is low."

    private func decode(_ json: String) throws -> DailyDigest {
        try JSONDecoder().decode(DailyDigest.self, from: Data(json.utf8))
    }

    /// A v1.40.3-shaped body; `extra` is spliced in after `line`.
    private func body(_ extra: String, ai: String? = nil) -> String {
        let aiField = ai.map { #","ai":\#($0)"# } ?? ""
        return #"""
        {"generatedAt":"2026-10-09T06:00:00.000Z","phase":"final","sleepPending":false,
         "score":{"value":81,"band":"green","delta":null},
         "topSignal":{"sourceMetric":"BLOOD_PRESSURE","tone":"good","headline":"\#(Self.headline)",
                      "nudge":"Keep it up.","delta":"\#(Self.delta)"},
         "briefingLead":"\#(Self.briefingLead)",
         "line":"Blood pressure is in range."\#(extra),
         "worthALook":[]\#(aiField)}
        """#
    }

    // MARK: - signalLine (#121)

    @Test("signalLine with only a delta renders the delta, not the topSignal headline")
    func deltaOnlyLine() throws {
        let digest = try decode(body(#","signalLine":{"headline":null,"delta":"\#(Self.delta)"}"#))
        #expect(digest.deliversSignalLine)
        #expect(digest.signalText == Self.delta)
        #expect(digest.signalText?.contains(Self.headline) == false, "the lead already talks about blood pressure")
    }

    @Test("signalLine null renders no line, although topSignal is present")
    func nullLineMeansNoLine() throws {
        let digest = try decode(body(#","signalLine":null"#))
        #expect(digest.deliversSignalLine)
        #expect(digest.topSignal != nil)
        #expect(digest.signalText == nil)
    }

    @Test("signalLine with headline and delta renders both, verbatim, comma-joined")
    func fullLine() throws {
        let digest = try decode(body(#","signalLine":{"headline":"\#(Self.headline)","delta":"\#(Self.delta)"}"#))
        #expect(digest.signalText == "\(Self.headline), \(Self.delta)")
    }

    @Test("A server without signalLine keeps the line built from topSignal")
    func olderServerFallsBackToTopSignal() throws {
        let digest = try decode(body(""))
        #expect(digest.deliversSignalLine == false)
        #expect(digest.signalText == "\(Self.headline), \(Self.delta)")
    }

    @Test("briefing unavailable hides a delivered signalLine")
    func briefingUnavailableHidesLine() throws {
        let ai = #"{"briefing":{"available":false,"reason":"operator_disabled","onDeviceAllowed":false}}"#
        let digest = try decode(body(#","signalLine":{"headline":"\#(Self.headline)","delta":null}"#, ai: ai))
        #expect(digest.signalText == nil)
    }

    @Test("A malformed signalLine reads as no line and does not fail the digest")
    func malformedLineIsTolerated() throws {
        let digest = try decode(body(#","signalLine":{"headline":7,"delta":["x"]}"#))
        #expect(digest.deliversSignalLine)
        #expect(digest.signalText == nil)
        #expect(digest.score?.value == 81)
    }

    // MARK: - lead (v1.40)

    @Test("lead.text is rendered as delivered")
    func resolvedLeadWins() throws {
        let digest = try decode(body(#","lead":{"text":"Pulse is settling","source":"signal"}"#))
        #expect(digest.lead == "Pulse is settling")
    }

    @Test("A null or absent lead keeps the previous chain")
    func nullOrAbsentLeadFallsBack() throws {
        #expect(try decode(body(#","lead":null"#)).lead == Self.briefingLead)
        #expect(try decode(body("")).lead == Self.briefingLead)
    }

    @Test("A briefing-sourced lead is not shown while briefing is unavailable")
    func briefingLeadRespectsCapability() throws {
        let ai = #"{"briefing":{"available":false,"reason":"operator_disabled","onDeviceAllowed":false}}"#
        let digest = try decode(body(#","lead":{"text":"Model sentence.","source":"briefing"}"#, ai: ai))
        #expect(digest.lead == "Blood pressure is in range.")
    }

    // MARK: - v1.40.2 fields, tolerant

    @Test("today[], restMode and score.steadyWeeks decode; unknown kinds and bad rows are tolerated")
    func v1402FieldsDecode() throws {
        let json = #"""
        {"generatedAt":"2026-10-09T06:00:00.000Z","phase":"final","sleepPending":false,
         "score":{"value":81,"band":"green","delta":null,"steadyWeeks":5,"steadyAtLeast":true},
         "topSignal":null,"briefingLead":null,"lead":null,"signalLine":null,
         "today":[{"kind":"sleep","label":"Sleep","value":"7 h 20 min","href":"/sleep"},
                  {"kind":"weather_mood","label":"New","value":"later","href":"/x"},
                  "not-an-object"],
         "restMode":{"day":2},"line":"","worthALook":[],"justIn":null,"reactionLine":null}
        """#
        let digest = try decode(json)
        #expect(digest.score?.steadyWeeks == 5)
        #expect(digest.score?.steadyAtLeast == true)
        #expect(digest.today.map(\.kind) == ["sleep", "weather_mood"])
        #expect(digest.restMode == DailyDigest.RestMode(day: 2))
    }

    @Test("A malformed restMode and steadyWeeks read as absent")
    func malformedV1402FieldsAreTolerated() throws {
        let json = #"""
        {"generatedAt":"","phase":"final","sleepPending":false,
         "score":{"value":60,"band":"yellow","delta":null,"steadyWeeks":"five"},
         "topSignal":null,"briefingLead":null,"line":"x","worthALook":[],"restMode":{"day":"two"},"today":7}
        """#
        let digest = try decode(json)
        #expect(digest.score?.value == 60)
        #expect(digest.score?.steadyWeeks == nil)
        #expect(digest.restMode == nil)
        #expect(digest.today.isEmpty)
    }

    @Test("A delivered null signalLine survives an encode/decode round trip as null")
    func roundTripKeepsDeliveredNull() throws {
        let digest = try decode(body(#","signalLine":null,"lead":{"text":"Pulse is settling","source":"signal"}"#))
        let again = try JSONDecoder().decode(DailyDigest.self, from: JSONEncoder().encode(digest))
        #expect(again == digest)
        #expect(again.deliversSignalLine)
        #expect(again.signalText == nil)
        #expect(again.lead == "Pulse is settling")
    }

    // MARK: - Personal bands as delivered (#121)

    /// v1.40.3 gives personal bands a minimum width per metric, so `low`/`high`
    /// need not sit symmetrically around `center`. The app reads them as sent.
    @Test("A personal band keeps low/high as delivered, even off-centre")
    func bandEdgesAsDelivered() throws {
        let json = #"""
        {"type":"RESTING_HEART_RATE","value":71,"center":58,"low":55,"high":63,"direction":"above"}
        """#
        let deviation = try JSONDecoder().decode(InsightsHealthStatusDTO.Deviation.self, from: Data(json.utf8))
        #expect(deviation.low == 55)
        #expect(deviation.high == 63)
        #expect(deviation.center == 58)
    }
}
