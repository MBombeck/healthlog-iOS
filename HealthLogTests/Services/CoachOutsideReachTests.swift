import Foundation
@testable import HealthLog
import Testing

/// **POLISH-B B9 (1.5, server v1.47.1, COACH-R point 6, #163 B4).**
///
/// A read whose readings all lie past the lookback limit set for the Coach
/// carries `reason: "outside_reach"` on its `activity` frame and on its trail
/// entry from v1.47.1. The status line and the trail say so in their own quiet
/// sentence. Without the field, with another reason, or on a server not known
/// to be v1.47.1, the wording stays as it was.
@Suite("POLISH-B B9 — Coach: readings past the Coach's reach")
@MainActor
struct CoachOutsideReachTests {
    private static func defaults(version: String?) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "polish-b-b9-\(UUID().uuidString)"))
        if let version {
            KnownServerVersion.record(ServerVersionInfo(version: version), defaults: defaults)
        }
        return defaults
    }

    private static func activity(_ extra: String) throws -> CoachServerService.CoachActivity {
        let json = #"{"id":"a2","phase":"fetch","status":"done","round":1,"label":"Holt Blutdruck, 2 Jahre…""#
            + extra + "}"
        return try JSONDecoder().decode(CoachServerService.CoachActivity.self, from: Data(json.utf8))
    }

    @Test("the frame decodes the reason; a malformed one is absence, never a lost frame")
    func decoding() throws {
        #expect(try Self.activity(#","reason":"outside_reach""#).reason == "outside_reach")
        #expect(try Self.activity("").reason == nil)
        #expect(try Self.activity(#","reason":7"#).reason == nil)
        #expect(try Self.activity(#","reason":7"#).label == "Holt Blutdruck, 2 Jahre…")
        let entry = try JSONDecoder().decode(
            CoachServerService.CoachTrail.Entry.self,
            from: Data(#"{"id":"a2","title":"Blutdruck","reason":"outside_reach"}"#.utf8)
        )
        #expect(entry.reason == "outside_reach")
    }

    @Test("the sentence only for outside_reach on a v1.47.1 server")
    func gate() throws {
        let current = try Self.defaults(version: "1.47.1")
        #expect(CoachReachReason.sentence(for: "outside_reach", defaults: current)
            == String(localized: "coach.reach.outsideReach"))
        #expect(CoachReachReason.sentence(for: nil, defaults: current) == nil)
        #expect(CoachReachReason.sentence(for: "outside_window", defaults: current) == nil)
        #expect(try CoachReachReason.sentence(for: "outside_reach", defaults: Self.defaults(version: "1.47.0")) == nil)
        #expect(try CoachReachReason.sentence(for: "outside_reach", defaults: Self.defaults(version: nil)) == nil)
    }

    @Test("status line: the reach sentence replaces the catalog label; without the field the label stays")
    func statusLine() async throws {
        let defaults = try Self.defaults(version: "1.47.1")
        let live = CoachLiveTrail()
        live.beginTurn()
        try await live.apply(Self.activity(""), filter: MDRSafetyFilter(), defaults: defaults)
        #expect(live.statusLine == "Holt Blutdruck, 2 Jahre…")
        try await live.apply(Self.activity(#","reason":"outside_reach""#), filter: MDRSafetyFilter(), defaults: defaults)
        #expect(live.statusLine == String(localized: "coach.reach.outsideReach"))
    }

    @Test("trail: the entry keeps its label and gains the sentence; an older server reads as before")
    func trail() async {
        let trail = CoachServerService.CoachTrail(entries: [
            .init(id: "a2", title: "Blutdruck der letzten zwei Jahre", reason: "outside_reach"),
            .init(id: "a3", title: "Schlaf der letzten Woche")
        ])
        let labels = ["a2": "Holt Blutdruck", "a3": "Holt Schlaf"]
        let rows = await CoachConversationStore.trailRows(
            trail, labels: labels, filter: MDRSafetyFilter(), serverSendsReach: true
        )
        #expect(rows.map(\.label) == ["Holt Blutdruck", "Holt Schlaf"])
        #expect(rows[0].detail == "Blutdruck der letzten zwei Jahre\n" + String(localized: "coach.reach.outsideReach"))
        #expect(rows[1].detail == "Schlaf der letzten Woche")

        let older = await CoachConversationStore.trailRows(
            trail, labels: labels, filter: MDRSafetyFilter(), serverSendsReach: false
        )
        #expect(older[0].detail == "Blutdruck der letzten zwei Jahre")
    }

    @Test("the sentence exists in German, English and Dutch and names no technical word")
    func catalog() {
        for language in ["de", "en", "nl"] {
            let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
            let text = bundle?.localizedString(forKey: "coach.reach.outsideReach", value: "\u{0}", table: nil) ?? "\u{0}"
            #expect(text != "\u{0}" && text != "coach.reach.outsideReach", "\(language)")
            #expect(!text.localizedCaseInsensitiveContains("server"), "\(language)")
        }
    }
}
