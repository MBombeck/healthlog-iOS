import Foundation
@testable import HealthLog
import Testing

/// **1.5 VISIT (#149 item 2)** — the wire of `GET /api/encounters`
/// (`preparation`, server v1.43.11) and `GET /api/day/notable` (`anchor`),
/// decoded tolerantly: a server without the field, every `basis`, `since`
/// null, an unknown value and a broken row.
@Suite("Next visit: encounter and notable contract (VISIT)")
struct NextVisitContractTests {
    static func visitJSON(id: String = "enc_1", preparation: String? = nil) -> String {
        let prep = preparation.map { #","preparation":\#($0)"# } ?? ""
        return #"""
        {"id":"\#(id)","occurredAt":"2026-11-18T09:30:00.000Z","status":"PLANNED","kind":"SPECIALIST",
         "practitioner":{"id":"p1","name":"Dr. Weber","specialty":"Dermatologie","practice":"Hautpraxis am Markt",
          "location":null,"phone":null,"note":null,"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"},
         "reason":null,"outcome":null,"bodySite":null,"laterality":null,"reminderNextDueAt":null,
         "links":{"documents":[],"labResults":[],"conditions":[]},
         "createdAt":"2026-10-01T00:00:00.000Z","updatedAt":"2026-10-01T00:00:00.000Z"\#(prep)}
        """#
    }

    static func preparationJSON(basis: String, since: String) -> String {
        #"{"from":"2026-08-12","to":"2026-11-18","basis":"\#(basis)","since":\#(since)}"#
    }

    static let sinceJSON = #"""
    {"id":"enc_0","occurredAt":"2026-08-12T08:00:00.000Z","kind":"ROUTINE","practitionerName":"Dr. Weber","specialty":"Dermatologie"}
    """#

    static func list(_ rows: [String]) -> Data {
        Data(#"{"upcoming":[\#(rows.joined(separator: ","))],"past":[]}"#.utf8)
    }

    private func decode(_ data: Data) throws -> UpcomingEncounters {
        try JSONDecoder.hlDefault.decode(UpcomingEncounters.self, from: data)
    }

    @Test("a server without preparation: the visit decodes, the window is nil")
    func serverWithoutField() throws {
        let list = try decode(Self.list([Self.visitJSON()]))
        let visit = try #require(list.upcoming.first)
        #expect(visit.id == "enc_1")
        #expect(visit.practitioner?.practice == "Hautpraxis am Markt")
        #expect(visit.preparation == nil)
    }

    @Test(
        "every basis decodes, with since and with since null",
        arguments: ["practitioner", "specialty", "kind", "default", "somethingNew"]
    )
    func everyBasis(basis: String) throws {
        for since in [Self.sinceJSON, "null"] {
            let json = Self.visitJSON(preparation: Self.preparationJSON(basis: basis, since: since))
            let visit = try #require(try decode(Self.list([json])).upcoming.first)
            let prep = try #require(visit.preparation)
            #expect(prep.from == "2026-08-12")
            #expect(prep.to == "2026-11-18")
            #expect(prep.basis == EncounterPreparation.Basis(raw: basis))
            #expect((prep.since == nil) == (since == "null"))
            if since != "null" { #expect(prep.since?.practitionerName == "Dr. Weber") }
        }
    }

    @Test("an unknown basis is kept, not an error")
    func unknownBasis() {
        #expect(EncounterPreparation.Basis(raw: "somethingNew") == .unknown("somethingNew"))
    }

    @Test("a broken row is skipped, the rest keep the server's order; a missing list reads empty")
    func brokenRowSkipped() throws {
        let broken = #"{"occurredAt":"2026-11-18T09:30:00.000Z"}"#
        let list = try decode(Self.list([Self.visitJSON(id: "a"), broken, Self.visitJSON(id: "b")]))
        #expect(list.upcoming.map(\.id) == ["a", "b"])
        #expect(try decode(Data(#"{"past":[]}"#.utf8)).upcoming.isEmpty)
    }

    @Test("notable: anchor nextVisit and an unknown anchor, rows tolerated, firstValue kept for the model to drop")
    func notableWindow() throws {
        for anchor in ["nextVisit", "somewhereElse"] {
            let json = #"""
            {"from":"2026-08-12","to":"2026-11-05","anchor":"\#(anchor)",
             "observations":[{"date":"2026-09-01","kind":"extremeHigh","type":"WEIGHT","params":{"since":"2026-02-03","value":81.4}},
                             {"date":"2026-09-02","kind":"gap","type":"PULSE","params":{"days":14}},
                             {"kind":"broken"}],
             "changes":[{"date":"2026-08-20","kind":"doseChange","section":"medications","id":"m1","title":"Lisinopril","count":1,"href":null}]}
            """#
            let window = try JSONDecoder.hlDefault.decode(DayNotableWindow.self, from: Data(json.utf8))
            #expect(window.anchor == anchor)
            #expect(window.observations.count == 2)
            #expect(window.observations[0].since == "2026-02-03")
            #expect(window.observations[1].days == 14)
            #expect(window.changes.first?.title == "Lisinopril")
        }
    }

    // MARK: - Capped window (POLISH-A A8, server v1.47.1)

    /// v1.47.1 caps the window at the 730 days a health report covers and
    /// says so with `preparation.capped`. The card then says "the last two
    /// years" instead of promising everything since the matched visit. A
    /// server without the field keeps the line it had.
    @Test("a capped window says the last two years; false or absent keeps the line of its basis")
    func cappedWindow() throws {
        func prep(_ tail: String) throws -> EncounterPreparation {
            let json = #"{"from":"2024-11-19","to":"2026-11-18","basis":"practitioner","since":\#(Self.sinceJSON)\#(tail)}"#
            let visit = try #require(try decode(Self.list([Self.visitJSON(preparation: json)])).upcoming.first)
            return try #require(visit.preparation)
        }
        let capped = try prep(#","capped":true"#)
        #expect(NextVisitFormat.sinceLine(capped) == String(localized: "visit.next.since.capped"))
        #expect(NextVisitFormat.sinceLine(capped) != "visit.next.since.capped", "a raw key would show")
        let open = try prep(#","capped":false"#)
        let absent = try prep("")
        let wrongType = try prep(#","capped":"yes""#)
        #expect(NextVisitFormat.sinceLine(open) == NextVisitFormat.sinceLine(absent))
        #expect(NextVisitFormat.sinceLine(wrongType) == NextVisitFormat.sinceLine(absent))
        #expect(NextVisitFormat.sinceLine(absent).contains("Dr. Weber"))
    }
}
