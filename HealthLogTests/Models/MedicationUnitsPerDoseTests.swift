import Foundation
@testable import HealthLog
import Testing

/// **H1/H2 (AUDIT-PARITY-v11612) — units-per-dose contract.**
///
/// Locks the curated picker set + decimal round-trip against the server's
/// `UNITS_PER_DOSE_FRACTIONS` + whole-number contract, the DTO→domain decode,
/// and the create/patch wire-body encode (the edit-path write).
@Suite("MedicationUnitsPerDose")
struct MedicationUnitsPerDoseTests {
    @Test("Curated fractions match the server set exactly")
    func fractionsMatchServer() {
        #expect(MedicationUnitsPerDose.fractions == [0.25, 0.3333, 0.5, 0.6667, 0.75])
    }

    @Test("decimalValue round-trips through from(decimal:)")
    func decimalRoundTrip() {
        for fraction in MedicationUnitsPerDose.fractions {
            let option = MedicationUnitsPerDose.from(decimal: fraction)
            #expect(option == .fraction(fraction))
            #expect(option.decimalValue == fraction)
        }
        for whole in 1 ... 10 {
            let option = MedicationUnitsPerDose.from(decimal: Double(whole))
            #expect(option == .whole(whole))
            #expect(option.decimalValue == Double(whole))
        }
    }

    @Test("Unknown / out-of-range decimal snaps to a curated option")
    func unknownDecimalSnaps() {
        // 0 and a huge whole are not picker options → default to one unit.
        #expect(MedicationUnitsPerDose.from(decimal: 0) == .whole(1))
        // A whole above the picker max clamps into the picker range.
        #expect(MedicationUnitsPerDose.from(decimal: 50).decimalValue > 0)
        // A near-⅓ value snaps to the curated ⅓.
        #expect(MedicationUnitsPerDose.from(decimal: 0.3333) == .fraction(0.3333))
    }

    @Test("W-CRASHGUARD — extreme / non-finite decimal falls back without trapping")
    func extremeDecimalDoesNotCrash() {
        // `1e308` is finite but far out of `Int.range` — the old
        // `Int(value.rounded())` trapped here; now it falls through to one unit.
        #expect(MedicationUnitsPerDose.from(decimal: 1e308) == .whole(1))
        #expect(MedicationUnitsPerDose.from(decimal: .infinity) == .whole(1))
        #expect(MedicationUnitsPerDose.from(decimal: .nan) == .whole(1))
        #expect(MedicationUnitsPerDose.from(decimal: -1e308) == .whole(1))
    }

    @Test("W-CRASHGUARD — DTO decode of an extreme unitsPerDose does not crash")
    func dtoExtremeUnitsPerDoseDecodes() throws {
        let json = Data(#"""
        {
            "id": "m1",
            "name": "Lisinopril",
            "dose": "5 mg",
            "unitsPerDose": 1e308,
            "schedules": []
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(MedicationWireDTO.self, from: json)
        // The raw decimal decodes; the domain mapping must not trap on it.
        #expect(MedicationUnitsPerDose.from(decimal: dto.unitsPerDose ?? 1) == .whole(1))
    }

    @Test("DTO decodes unitsPerDose and maps it onto the domain")
    func dtoMapsUnitsPerDose() throws {
        let json = Data(#"""
        {
            "id": "m1",
            "name": "Lisinopril",
            "dose": "5 mg",
            "unitsPerDose": 0.5,
            "schedules": []
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(MedicationWireDTO.self, from: json)
        #expect(dto.unitsPerDose == 0.5)
        let domain = dto.toDomain()
        #expect(domain.unitsPerDose == 0.5)
    }

    @Test("DTO tolerates an absent unitsPerDose (older servers)")
    func dtoToleratesMissing() throws {
        let json = Data(#"""
        { "id": "m1", "name": "Lisinopril", "dose": "5 mg", "schedules": [] }
        """#.utf8)
        let dto = try JSONDecoder().decode(MedicationWireDTO.self, from: json)
        #expect(dto.unitsPerDose == nil)
        // Treated as 1.0 by the picker mapping.
        #expect(MedicationUnitsPerDose.from(decimal: dto.unitsPerDose ?? 1) == .whole(1))
    }

    @Test("Edit patch encodes the selected unitsPerDose decimal")
    func patchEncodesUnitsPerDose() throws {
        let patch = MedicationsRepository.MedicationPatch(
            dose: "5 mg",
            unitsPerDose: MedicationUnitsPerDose.fraction(0.5).decimalValue
        )
        let data = try JSONEncoder().encode(patch)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["unitsPerDose"] as? Double == 0.5)
    }

    // MARK: - #1034 — a combined value (1½, 2¼) is shown and kept, never rounded

    @Test("#1034 — 1.5 and 2.25 stay what they are and read as 1½ / 2¼")
    func combinedValuesKept() {
        #expect(MedicationUnitsPerDose.from(decimal: 1.5) == .other(1.5))
        #expect(MedicationUnitsPerDose.from(decimal: 1.5).decimalValue == 1.5)
        #expect(MedicationUnitsPerDose.from(decimal: 1.5).label == "1½")
        #expect(MedicationUnitsPerDose.from(decimal: 2.25).decimalValue == 2.25)
        #expect(MedicationUnitsPerDose.from(decimal: 2.25).label == "2¼")
        #expect(MedicationUnitsPerDose.from(decimal: 1.3333).label == "1⅓")
        // A whole above the server's 100 is also kept, not snapped to one unit.
        #expect(MedicationUnitsPerDose.from(decimal: 150).decimalValue == 150)
        // The curated set is unchanged: the picker still offers ¼…¾ and 1…10 only.
        #expect(!MedicationUnitsPerDose.allCases.contains(.other(1.5)))
    }

    /// Tag `v1.39.1` (final) widened the rule past the pre-release state D1
    /// read: any value above 0 and at most 100 with four decimals, so also a
    /// measured amount below one unit (`isSupportedUnitsPerDose`,
    /// `src/lib/medications/units-per-dose.ts`). Such a value is kept verbatim.
    @Test("v1.39.1 final — a measured amount (0.8, 2.4) is kept, not snapped to a curated option")
    func measuredAmountsKept() {
        #expect(MedicationUnitsPerDose.from(decimal: 0.8) == .other(0.8))
        #expect(MedicationUnitsPerDose.from(decimal: 0.8).decimalValue == 0.8)
        #expect(MedicationUnitsPerDose.from(decimal: 2.4) == .other(2.4))
        #expect(MedicationUnitsPerDose.from(decimal: 0.1234).decimalValue == 0.1234)
    }

    @Test("#1034 — the editor opens a stored 1.5 as 1.5, so a save that leaves it alone sends nothing")
    func editorKeepsServerCombinedValue() {
        let med = Medication(
            id: "m1", name: "Metoprolol", dose: "47.5 mg", unitsPerDose: 1.5,
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let state = EditMedicationFormState(from: med)
        #expect(state.unitsPerDose.decimalValue == 1.5)
        #expect(state.unitsPerDose.label == "1½")
    }
}
