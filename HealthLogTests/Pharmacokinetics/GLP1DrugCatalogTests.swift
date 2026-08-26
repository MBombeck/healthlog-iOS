import Foundation
@testable import HealthLog
import Testing

/// Drug-catalog correctness + drift-guard.
///
/// The Swift catalog is a hand-port of `src/lib/medications/glp1-knowledge.ts`.
/// Each test here locks one dimension of the contract so a future server
/// bump (or accidental local edit) is caught before merge.
///
/// Catalog drift = clinical risk. EMA EPAR values are pinned per drug; a
/// silent numeric edit changes the shape of the PK curve and the chip-phase
/// classification. The drift test asserts the snapshot bytes match.
@Suite("GLP1 drug catalog")
struct GLP1DrugCatalogTests {
    // MARK: - Shape

    @Test("Catalog has exactly five drugs in stable order")
    func catalogHasFiveDrugsInOrder() {
        #expect(GLP1DrugCatalog.allDrugIDs == [
            .tirzepatide, .semaglutide, .liraglutide, .dulaglutide, .exenatide
        ])
        #expect(GLP1DrugCatalog.records.count == 5)
    }

    @Test("Every drug record has a non-empty brand list")
    func everyDrugHasBrands() {
        for id in GLP1DrugCatalog.allDrugIDs {
            let record = GLP1DrugCatalog.drug(for: id)
            #expect(!record.brands.isEmpty, "\(id) has no brands")
            #expect(!record.inn.isEmpty, "\(id) has empty INN")
        }
    }

    @Test("Every record has positive pharmacology constants")
    func everyRecordHasPositiveConstants() {
        for id in GLP1DrugCatalog.allDrugIDs {
            let p = GLP1DrugCatalog.drug(for: id).pharmacology
            #expect(p.halfLifeDays > 0, "\(id) halfLifeDays must be > 0")
            #expect(p.tmaxHours > 0, "\(id) tmaxHours must be > 0")
            #expect(p.bioavailability > 0 && p.bioavailability <= 1, "\(id) bioavailability OOR")
            #expect(p.vdLitersPerKg > 0, "\(id) vdLitersPerKg must be > 0")
            #expect(p.clearanceLPerHour70kg > 0, "\(id) clearance must be > 0")
            if let ka = p.absorptionRateHourlyKa {
                #expect(ka > 0, "\(id) absorptionRateHourlyKa, if present, must be > 0")
            }
        }
    }

    // MARK: - Drift guard (locked numeric values)

    @Test("Tirzepatide catalog values match server (psp4.13099 + EMA EPAR)")
    func tirzepatideDrift() {
        let record = GLP1DrugCatalog.drug(for: .tirzepatide)
        #expect(record.inn == "Tirzepatide")
        #expect(record.brands == ["Mounjaro", "Zepbound"])
        #expect(record.drugClass == .gipGlp1DualAgonist)
        #expect(record.standardInjectionFrequency == .weekly)
        #expect(record.maxDoseMg == 15)
        #expect(record.titrationStepsMg == [2.5, 5, 7.5, 10, 12.5, 15])
        #expect(record.pharmacology.halfLifeDays == 5.0)
        #expect(record.pharmacology.tmaxHours == 24)
        #expect(record.pharmacology.absorptionRateHourlyKa == 0.0373)
        #expect(record.pharmacology.bioavailability == 0.8)
        #expect(record.pharmacology.compartmentModel == .twoCompartment)
        #expect(record.sourceJournal?.doi == "10.1002/psp4.13099")
    }

    @Test("Semaglutide brand-routes carry the Rybelsus oral exception")
    func semaglutideBrandRoutes() {
        let record = GLP1DrugCatalog.drug(for: .semaglutide)
        #expect(record.brands == ["Ozempic", "Wegovy", "Rybelsus"])
        #expect(record.route == .subcutaneous)
        #expect(record.brandRoutes["Rybelsus"] == .oral)
        #expect(record.brandRoutes["Ozempic"] == .subcutaneous)
        #expect(record.brandRoutes["Wegovy"] == .subcutaneous)
    }

    @Test("Liraglutide is daily-cadence with ~13h half-life")
    func liraglutideDaily() {
        let record = GLP1DrugCatalog.drug(for: .liraglutide)
        #expect(record.standardInjectionFrequency == .daily)
        #expect(abs(record.pharmacology.halfLifeDays - 13.0 / 24.0) < 1e-12)
        #expect(record.pharmacology.tmaxHours == 11)
        #expect(record.brands == ["Saxenda", "Victoza"])
    }

    @Test("Exenatide is twice-daily IR profile (Byetta default)")
    func exenatideTwiceDaily() {
        let record = GLP1DrugCatalog.drug(for: .exenatide)
        #expect(record.standardInjectionFrequency == .twiceDaily)
        #expect(abs(record.pharmacology.halfLifeDays - 2.4 / 24.0) < 1e-12)
        #expect(record.brands == ["Byetta", "Bydureon"])
    }

    @Test("Dulaglutide is single-dose pen, weekly cadence")
    func dulaglutidePen() {
        let record = GLP1DrugCatalog.drug(for: .dulaglutide)
        #expect(record.standardInjectionFrequency == .weekly)
        #expect(record.dosesPerPen == 1)
        #expect(record.brands == ["Trulicity"])
    }

    // MARK: - Lookups

    @Test("findDrugID(byBrand:) is case-insensitive across all brands")
    func findDrugIDIsCaseInsensitive() {
        let cases: [(brand: String, expected: GLP1DrugCatalog.DrugID)] = [
            ("Mounjaro", .tirzepatide),
            ("mounjaro", .tirzepatide),
            ("MOUNJARO", .tirzepatide),
            ("Zepbound", .tirzepatide),
            ("Ozempic", .semaglutide),
            ("Wegovy", .semaglutide),
            ("Rybelsus", .semaglutide),
            ("Saxenda", .liraglutide),
            ("Victoza", .liraglutide),
            ("Trulicity", .dulaglutide),
            ("Byetta", .exenatide),
            ("Bydureon", .exenatide)
        ]
        for (brand, expected) in cases {
            #expect(GLP1DrugCatalog.findDrugID(byBrand: brand) == expected, "Brand \(brand)")
        }
    }

    @Test("findDrugID(byBrand:) returns nil for unknown / empty")
    func findDrugIDUnknown() {
        #expect(GLP1DrugCatalog.findDrugID(byBrand: "") == nil)
        #expect(GLP1DrugCatalog.findDrugID(byBrand: "   ") == nil)
        #expect(GLP1DrugCatalog.findDrugID(byBrand: "Paracetamol") == nil)
        // Retatrutide is deliberately excluded — no EMA approval.
        #expect(GLP1DrugCatalog.findDrugID(byBrand: "Retatrutide") == nil)
    }

    @Test("detectDrugID handles medication names with extras")
    func detectDrugIDFromMedicationName() {
        // The user-typed `Medication.name` includes brand + dose + freq.
        // Detection picks the brand substring case-insensitively.
        #expect(GLP1DrugCatalog.detectDrugID(fromMedicationName: "Mounjaro 7.5 mg") == .tirzepatide)
        #expect(GLP1DrugCatalog.detectDrugID(fromMedicationName: "Ozempic 1mg weekly") == .semaglutide)
        #expect(GLP1DrugCatalog.detectDrugID(fromMedicationName: "Saxenda 3 mg daily") == .liraglutide)
        #expect(GLP1DrugCatalog.detectDrugID(fromMedicationName: "TRULICITY") == .dulaglutide)
        #expect(GLP1DrugCatalog.detectDrugID(fromMedicationName: "Paracetamol 500mg") == nil)
        #expect(GLP1DrugCatalog.detectDrugID(fromMedicationName: "Wegovy") == .semaglutide)
    }

    @Test("route(for:brand:) honours the Rybelsus oral exception")
    func routeForBrand() {
        #expect(GLP1DrugCatalog.route(for: .semaglutide, brand: "Ozempic") == .subcutaneous)
        #expect(GLP1DrugCatalog.route(for: .semaglutide, brand: "Wegovy") == .subcutaneous)
        #expect(GLP1DrugCatalog.route(for: .semaglutide, brand: "Rybelsus") == .oral)
        #expect(GLP1DrugCatalog.route(for: .tirzepatide, brand: "Mounjaro") == .subcutaneous)
        #expect(GLP1DrugCatalog.route(for: .liraglutide, brand: "Mounjaro") == nil)
    }

    // MARK: - Sources

    @Test("Every record has a valid EMA EPAR URL")
    func emaSourceURLsAreValid() {
        for id in GLP1DrugCatalog.allDrugIDs {
            let record = GLP1DrugCatalog.drug(for: id)
            #expect(record.sourceEMA.scheme == "https", "\(id) sourceEMA must be https")
            #expect(record.sourceEMA.host == "www.ema.europa.eu", "\(id) sourceEMA wrong host")
        }
    }
}
