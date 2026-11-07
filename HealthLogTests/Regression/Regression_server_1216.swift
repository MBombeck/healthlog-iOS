import Foundation
@testable import HealthLog
import Testing

/// **REG (1.5) — Server #1216 (mbreitkreuz): Rest Mode was on with only a
/// chronic illness.**
///
/// The rule is the server's (a chronic, ongoing episode does not start Rest
/// Mode). The app's half: it shows Rest Mode exactly as delivered and derives
/// nothing of its own. A score whose `restMode.active` is false stays silent
/// on every surface that reads it, whatever episodes the account has; one the
/// server marks active shows. The digest's "day n of Rest Mode" line follows
/// its own field the same way.
@Suite("REG Server #1216: Rest Mode is shown as the server delivers it")
struct Regression_server_1216 {
    private static func score(_ restMode: String) throws -> HealthScore {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractional
        let json = #"{"score":71,"band":"yellow","delta":0"# + restMode + "}"
        return try decoder.decode(HealthScore.self, from: Data(json.utf8))
    }

    private static func digest(restMode: DailyDigest.RestMode?) -> DailyDigest {
        DailyDigest(
            generatedAt: "2026-11-05T07:00:00.000Z",
            phase: "morning",
            sleepPending: false,
            score: nil,
            topSignal: nil,
            briefingLead: nil,
            line: "",
            worthALook: [],
            restMode: restMode
        )
    }

    @Test("inactive or absent on the wire: no Rest Mode anywhere", arguments: [
        #","restMode":{"active":false,"since":"2026-10-01T00:00:00.000Z","episodeCount":1}"#,
        #","restMode":null"#,
        ""
    ])
    func inactiveStaysSilent(_ restMode: String) throws {
        let score = try Self.score(restMode)
        #expect(score.activeRestMode == nil)
        #expect(!HealthScorePresentation.sections(for: score).contains(.restMode))
    }

    @Test("active on the wire: shown, with the server's own values")
    func activeIsShown() throws {
        let score = try Self.score(#","restMode":{"active":true,"since":"2026-11-01T08:00:00.000Z","episodeCount":2}"#)
        let rest = try #require(score.activeRestMode)
        #expect(rest.episodeCount == 2)
        #expect(HealthScorePresentation.sections(for: score).contains(.restMode))
    }

    @MainActor
    @Test("the digest's Rest Mode line appears only when the server sends the field")
    func digestLineFollowsTheField() {
        #expect(TodayHeroFacts.statusLines(Self.digest(restMode: nil)).isEmpty)
        #expect(TodayHeroFacts.statusLines(Self.digest(restMode: .init(day: 0))).isEmpty)
        #expect(TodayHeroFacts.statusLines(Self.digest(restMode: .init(day: 3))).count == 1)
    }
}
