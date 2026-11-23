import Foundation
@testable import HealthLog
import Testing

/// A marker minted from a text result has the empty unit `""` (HealthLog#1393).
/// The editor opens it like "No unit", a rename sends no `unit` key, and a
/// real unit change is held back on a server that would answer 422.
@Suite("Lab markers without a unit: rename and edit")
struct LabMarkerUnitEditTests {
    private static func defaults(server version: String?) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "labs.markerunit.\(UUID().uuidString)"))
        if let version {
            KnownServerVersion.record(ServerVersionInfo(version: version), defaults: defaults)
        }
        return defaults
    }

    private static func body(_ patch: BiomarkerPatch) throws -> [String: Any] {
        let data = try JSONEncoder().encode(patch)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("the empty unit and the unity both mean no unit")
    func noUnit() {
        #expect(LabUnit.isNoUnit(""))
        #expect(LabUnit.isNoUnit("  "))
        #expect(LabUnit.isNoUnit("1"))
        #expect(!LabUnit.isNoUnit("mg/dL"))
        #expect(LabUnit.sameMarkerUnit("", "1"))
        #expect(!LabUnit.sameMarkerUnit("", "mg/dL"))
    }

    @Test("renaming a marker with an empty unit sends no unit key")
    func renameSendsNoUnit() throws {
        // The editor opens "" with "No unit" on, so its wire unit is "1".
        let wire = LabUnit.wire(typed: "", noUnit: true)
        let patch = BiomarkerPatch(name: "Urine protein", unit: LabUnit.markerPatchUnit(stored: "", edited: wire))
        let body = try Self.body(patch)
        #expect(body["name"] as? String == "Urine protein")
        #expect(body["unit"] == nil)
    }

    struct UnitEdit: Sendable {
        let stored: String
        let edited: String
        let sent: String?
    }

    @Test("the unit is sent only when it really changes", arguments: [
        UnitEdit(stored: "", edited: "1", sent: nil),
        UnitEdit(stored: "1", edited: "1", sent: nil),
        UnitEdit(stored: "mg/dL", edited: "mg/dL", sent: nil),
        UnitEdit(stored: "mg/dL ", edited: "mg/dL", sent: nil),
        UnitEdit(stored: "", edited: "mg/dL", sent: "mg/dL"),
        UnitEdit(stored: "1", edited: "mg/dL", sent: "mg/dL"),
        UnitEdit(stored: "mg/dL", edited: "1", sent: "1"),
        UnitEdit(stored: "mg/dL", edited: "mmol/L", sent: "mmol/L")
    ])
    func patchUnit(edit: UnitEdit) {
        #expect(LabUnit.markerPatchUnit(stored: edit.stored, edited: edit.edited) == edit.sent)
    }

    @Test("an empty unit can be changed only from server 1.47.7; other units always")
    func unitEditableFollowsTheServer() throws {
        let versions: [String?: Bool] = [nil: false, "1.47.6": false, "1.47.7": true, "1.48.0": true]
        for (version, editable) in versions {
            let defaults = try Self.defaults(server: version)
            #expect(LabUnit.markerUnitEditable(stored: "", defaults: defaults) == editable, "\(version ?? "unknown")")
            #expect(LabUnit.markerUnitEditable(stored: "mg/dL", defaults: defaults))
            #expect(LabUnit.markerUnitEditable(stored: "1", defaults: defaults))
            #expect(LabUnit.markerUnitEditable(stored: nil, defaults: defaults), "a new marker")
        }
    }
}
