import Foundation
@testable import HealthLog
import Testing

/// **Build 6.3 / Issue #64 — dose-history intake provenance.**
///
/// The dose-history route does not yet stamp `source` (server-side #64 open), so
/// the field must decode tolerantly — absent → nil → the provenance chip does not
/// render. When the server starts emitting one of the five known literals the
/// typed accessor + label-map light the chip up with no client change; an
/// unknown / future literal stays inert (nil) rather than painting a raw string.
@Suite("Medication dose provenance — Build 6.3 (#64)")
struct MedicationProvenanceTests {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractional
        return d
    }()

    private func envelope(intakeExtra: String) -> Data {
        Data("""
        {
            "from": "2026-06-01T00:00:00.000Z",
            "to": "2026-06-14T12:00:00.000Z",
            "rows": [
                {
                    "kind": "slot",
                    "at": "2026-06-13T06:00:00.000Z",
                    "timeOfDay": "08:00",
                    "status": "taken_on_time",
                    "intake": {
                        "id": "evt-1",
                        "scheduledFor": "2026-06-13T06:00:00.000Z",
                        "takenAt": "2026-06-13T06:05:00.000Z",
                        "skipped": false\(intakeExtra)
                    }
                }
            ]
        }
        """.utf8)
    }

    @Test("An absent source decodes fine and yields no provenance (today's reality — #64 open)")
    func absentSourceIsTolerated() throws {
        let env = try decoder.decode(MedicationDoseHistoryEnvelope.self, from: envelope(intakeExtra: ""))
        let row = try #require(env.rows.first)
        #expect(row.intake?.source == nil)
        #expect(row.provenance == nil, "no source → no chip")
    }

    @Test("A known source literal decodes to the typed provenance + labels")
    func knownSourceMapsToProvenance() throws {
        let env = try decoder.decode(
            MedicationDoseHistoryEnvelope.self,
            from: envelope(intakeExtra: #", "source": "REMINDER""#)
        )
        let row = try #require(env.rows.first)
        #expect(row.intake?.source == "REMINDER")
        #expect(row.provenance == .reminder)
    }

    @Test("An unmodelled future source decodes but stays inert (no guessed chip)")
    func unknownSourceStaysInert() throws {
        let env = try decoder.decode(
            MedicationDoseHistoryEnvelope.self,
            from: envelope(intakeExtra: #", "source": "SOME_FUTURE_SOURCE""#)
        )
        let row = try #require(env.rows.first)
        #expect(row.intake?.source == "SOME_FUTURE_SOURCE", "raw preserved")
        #expect(row.provenance == nil, "unknown literal must not render a chip")
    }

    @Test("The label-map covers all five #64 literals")
    func labelMapCoversAllLiterals() {
        for wire in ["WEB", "API", "REMINDER", "IMPORT", "APPLE_HEALTH"] {
            let provenance = DoseIntakeProvenance(wireValue: wire)
            #expect(provenance != nil, "\(wire) must map to a provenance case")
            #expect(provenance?.rawValue == wire)
            #expect(provenance?.systemImage.isEmpty == false)
        }
        #expect(DoseIntakeProvenance.allCases.count == 5)
    }
}
