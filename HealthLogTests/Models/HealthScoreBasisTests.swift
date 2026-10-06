import Foundation
@testable import HealthLog
import Testing

/// #103 / #115 · 1.3 — a one-area Health Score must not render like a full one.
/// `scoreBasis` and `compositionNotice` ride `GET /api/dashboard/snapshot` →
/// `healthScore` (server v1.38, `HealthScoreBasis` in `docs/api/openapi.yaml`
/// at `v1.39.0`); the app shows "based on N of M areas" beside the number.
@Suite("Health Score basis (#103, #115 1.3)")
@MainActor
struct HealthScoreBasisTests {
    private static let minimalSnapshot = #"""
    {
      "briefingState": "ready",
      "healthScore": {
        "score": 82, "band": "green", "delta": null, "deltaReason": "first_eligibility_window",
        "composition": ["BLOOD_PRESSURE"],
        "scoreBasis": { "domains": 1, "recommended": 3, "tier": "minimal", "physiological": true },
        "compositionNotice": { "itemKey": "health-score-composition:2026-09-23", "left": ["SLEEP"], "joined": [], "dismissed": false }
      }
    }
    """#

    private static func decode(_ json: String) throws -> DashboardSnapshotBriefing {
        try JSONDecoder.hlDefault.decode(DashboardSnapshotBriefing.self, from: Data(json.utf8))
    }

    @Test("scoreBasis and compositionNotice decode from the snapshot")
    func decodesBasis() throws {
        let score = try #require(Self.decode(Self.minimalSnapshot).healthScore)
        #expect(score.scoreBasis == HealthScoreBasis(domains: 1, recommended: 3, tier: .minimal, physiological: true))
        #expect(score.scoreBasis?.isNarrow == true)
        #expect(score.compositionNotice?.left == [.sleep])
        #expect(score.compositionNotice?.isShowable == true)
    }

    @Test("the basis line names N of M areas")
    func basisLine() throws {
        let score = try #require(Self.decode(Self.minimalSnapshot).healthScore)
        let basis = try #require(score.scoreBasis)
        let line = HealthScorePresentation.basisLine(basis)
        #expect(line.contains("1"))
        #expect(line.contains("3"))
        let notice = try #require(score.compositionNotice)
        #expect(HealthScorePresentation.noticeLines(notice).count == 1)
    }

    @Test("the basis survives the SWR cache round trip")
    func cacheRoundTrip() throws {
        let score = try #require(Self.decode(Self.minimalSnapshot).healthScore)
        let data = try JSONEncoder().encode(score)
        let decoded = try JSONDecoder().decode(HealthScore.self, from: data)
        #expect(decoded.scoreBasis == score.scoreBasis)
        #expect(decoded.compositionNotice == score.compositionNotice)
    }

    @Test("an older server without the fields claims nothing about breadth")
    func olderServer() throws {
        let json = #"{ "briefingState": "ready", "healthScore": { "score": 70, "band": "yellow", "delta": 1 } }"#
        let score = try #require(Self.decode(json).healthScore)
        #expect(score.scoreBasis == nil)
        #expect(score.compositionNotice == nil)
    }

    @Test("an unknown tier word keeps the score; a dismissed notice says nothing")
    func tolerance() throws {
        let json = #"""
        { "briefingState": "ready", "healthScore": { "score": 70, "band": "yellow", "delta": 1,
          "scoreBasis": { "domains": 4, "recommended": 3, "tier": "zz-wide", "physiological": false },
          "compositionNotice": { "itemKey": "k", "left": [], "joined": ["LIPIDS"], "dismissed": true } } }
        """#
        let score = try #require(Self.decode(json).healthScore)
        #expect(score.score == 70)
        #expect(score.scoreBasis?.tier == .unknown)
        #expect(score.scoreBasis?.physiological == false)
        let notice = try #require(score.compositionNotice)
        #expect(HealthScorePresentation.noticeLines(notice).isEmpty)
    }
}
