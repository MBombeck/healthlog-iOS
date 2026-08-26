import Foundation
@testable import HealthLog
import Testing

/// **M2 (AUDIT-PARITY-v11612) — medications-list layout.**
///
/// Locks the decode of `GET /api/medications/layout` against the server's
/// resolved shape (`MedicationListLayout` in `medication-list-layout.ts`),
/// the tolerant-first doctrine (a partial / malformed blob collapses onto the
/// defaults), and the manual-order application that makes the iOS list match
/// the web/other devices.
///
/// **08-05 restated `decodesFullShape` in place.** It used to assert that a
/// stored `"view": "table"` decoded *back* to a table presentation — the exact
/// update-path claim the cards-only decision has to invert. The payload is
/// unchanged; what it is allowed to mean is not.
@Suite("MedicationListLayout")
struct MedicationListLayoutTests {
    private let decoder = JSONDecoder()

    @Test("Full layout payload decodes; a legacy view literal neutralises to cards")
    func decodesFullShape() throws {
        let json = Data(#"""
        { "version": 1, "view": "table", "order": ["m3", "m1", "m2"] }
        """#.utf8)
        let layout = try decoder.decode(MedicationListLayout.self, from: json)
        // The installation that already stored `table` is the case that matters:
        // it is accepted, not rejected, and it lands on the only presentation
        // there is.
        #expect(layout.view == .cards)
        #expect(MedicationListView.allCases == [.cards])
        // Neutralising the presentation must not cost the saved order.
        #expect(layout.order == ["m3", "m1", "m2"])
    }

    @Test("A legacy view literal is never encoded back")
    func legacyViewIsNotWrittenBack() throws {
        let json = Data(#"{ "version": 1, "view": "table", "order": ["m1"] }"#.utf8)
        let layout = try decoder.decode(MedicationListLayout.self, from: json)
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(layout)
            ) as? [String: Any]
        )
        // Reading a legacy payload may not turn into writing one: `view` is
        // decode-only, so the round trip states nothing about presentation.
        #expect(object["view"] == nil)
        #expect(object["order"] as? [String] == ["m1"])
        #expect(object["version"] as? Int == 1)
        // ...and the omission is lossless, because there is one case to land on.
        let round = try decoder.decode(
            MedicationListLayout.self,
            from: JSONEncoder().encode(layout)
        )
        #expect(round.view == .cards)
        #expect(round.order == ["m1"])
    }

    @Test("Missing view / order collapse onto defaults")
    func toleratesPartialShape() throws {
        let json = Data(#"{ "version": 1 }"#.utf8)
        let layout = try decoder.decode(MedicationListLayout.self, from: json)
        #expect(layout.view == .cards)
        #expect(layout.order.isEmpty)
    }

    @Test("Unknown view literal degrades to .cards")
    func toleratesUnknownView() throws {
        let json = Data(#"{ "version": 1, "view": "grid", "order": [] }"#.utf8)
        let layout = try decoder.decode(MedicationListLayout.self, from: json)
        #expect(layout.view == .cards)
    }

    @Test("Saved order is applied: ranked ids first, rest keep server order")
    func appliesOrder() {
        struct Med { let id: String }
        let meds = [Med(id: "a"), Med(id: "b"), Med(id: "c"), Med(id: "d")]
        let layout = MedicationListLayout(view: .cards, order: ["c", "a"])
        let result = layout.applied(to: meds, id: \.id).map(\.id)
        // c, a first (saved sequence), then b, d in their original order.
        #expect(result == ["c", "a", "b", "d"])
    }

    @Test("Empty order is a pure passthrough")
    func emptyOrderPassthrough() {
        struct Med { let id: String }
        let meds = [Med(id: "a"), Med(id: "b"), Med(id: "c")]
        let layout = MedicationListLayout(view: .cards, order: [])
        #expect(layout.applied(to: meds, id: \.id).map(\.id) == ["a", "b", "c"])
    }

    @Test("Ids in order that no longer resolve are ignored")
    func staleIdsIgnored() {
        struct Med { let id: String }
        let meds = [Med(id: "a"), Med(id: "b")]
        // "z" no longer resolves to a medication.
        let layout = MedicationListLayout(view: .cards, order: ["z", "b"])
        #expect(layout.applied(to: meds, id: \.id).map(\.id) == ["b", "a"])
    }

    @Test("PUT patch always carries version 1 and only the supplied field")
    func patchEncoding() throws {
        let patch = MedicationListLayoutPatch(order: ["m1", "m2"])
        let encoder = JSONEncoder()
        let data = try encoder.encode(patch)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["version"] as? Int == 1)
        #expect(object["order"] as? [String] == ["m1", "m2"])
        // view was not set → absent from the wire body (preserve-when-absent).
        #expect(object["view"] == nil)
    }
}
