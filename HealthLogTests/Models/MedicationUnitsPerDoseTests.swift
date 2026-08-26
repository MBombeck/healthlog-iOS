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
}
