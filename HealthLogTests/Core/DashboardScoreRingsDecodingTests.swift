import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **v1.27.7 — locks the hero score-ring decode off `GET /api/dashboard/snapshot`.**
///
/// 1. `scoreRings[]` decodes in SELECTION ORDER (the render order on the hero).
/// 2. MED_COMPLIANCE carries `doses{taken,scheduled}`; the derived rings don't.
/// 3. A ring whose `id` is outside this client's closed set (a future server
///    ring) is SKIPPED — never poisons the whole array (missing-entry contract).
/// 4. An absent `scoreRings` field (older server) decodes to `[]`.
@Suite("DashboardScoreRing decode")
struct DashboardScoreRingsDecodingTests {
    private let decoder = JSONDecoder.hlDefault

    private func snapshot(scoreRings: String?) -> Data {
        var fields = [
            "\"user\": {\"username\": \"anna\"}",
            "\"tiles\": {}",
            "\"briefingState\": \"ready\"",
            "\"generatedAt\": \"2026-07-08T06:00:00.000Z\""
        ]
        if let scoreRings {
            fields.append("\"scoreRings\": \(scoreRings)")
        }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    @Test("scoreRings decode in selection order with per-ring fields")
    func decodesInOrder() throws {
        let slot = try decoder.decode(DashboardSnapshotBriefing.self, from: snapshot(scoreRings: #"""
        [
          {"id":"SLEEP_SCORE","score":82,"band":"green"},
          {"id":"READINESS","score":54,"band":"yellow"},
          {"id":"MED_COMPLIANCE","score":33,"band":"yellow","doses":{"taken":1,"scheduled":3}}
        ]
        """#))
        // Order preserved exactly as the server emitted (selection order).
        #expect(slot.scoreRings.map(\.id) == [.sleepScore, .readiness, .medCompliance])
        let sleep = slot.scoreRings[0]
        #expect(sleep.score == 82)
        #expect(sleep.band == "green")
        #expect(sleep.doses == nil)
        #expect(abs(sleep.fraction - 0.82) < 0.0001)
        // MED_COMPLIANCE carries the honest dose tally for its label.
        let meds = slot.scoreRings[2]
        #expect(meds.doses == DashboardScoreRing.Doses(taken: 1, scheduled: 3))
        #expect(meds.dosesCaption == "1/3")
    }

    @Test("an unknown (future) ring id is skipped — the array survives")
    func skipsUnknownId() throws {
        let slot = try decoder.decode(DashboardSnapshotBriefing.self, from: snapshot(scoreRings: #"""
        [
          {"id":"READINESS","score":70,"band":"green"},
          {"id":"FUTURE_RING_V2","score":90,"band":"green"},
          {"id":"MED_COMPLIANCE","score":100,"band":"green","doses":{"taken":3,"scheduled":3}}
        ]
        """#))
        // The unknown middle element drops; the two known rings survive in order.
        #expect(slot.scoreRings.map(\.id) == [.readiness, .medCompliance])
        // MED_COMPLIANCE all-taken → green, never red.
        #expect(slot.scoreRings.last?.band == "green")
    }

    @Test("absent scoreRings field (older server) decodes to empty")
    func absentDecodesEmpty() throws {
        let slot = try decoder.decode(DashboardSnapshotBriefing.self, from: snapshot(scoreRings: nil))
        #expect(slot.scoreRings.isEmpty)
    }

    @Test("empty scoreRings array (all selected rings had no data) decodes empty")
    func emptyArrayDecodesEmpty() throws {
        let slot = try decoder.decode(DashboardSnapshotBriefing.self, from: snapshot(scoreRings: "[]"))
        #expect(slot.scoreRings.isEmpty)
    }
}
