import Foundation
@testable import HealthLog
import Testing

/// Locks the nutrient wire DTOs + catalog against the server v1.28 contract
/// (`POST /api/nutrients/batch`, GH iOS #48).
@Suite("Nutrient batch DTO + catalog")
struct NutrientBatchDTOTests {
    // MARK: - Catalog

    @Test("Catalog covers all 26 codes, one row per NutrientCode, canonical units")
    func catalogCoversEveryCode() {
        // 24 vitamins/minerals + water + caffeine.
        #expect(NutrientCatalog.all.count == 26)
        #expect(NutrientCode.allCases.count == 26)
        let codes = Set(NutrientCatalog.all.map(\.code))
        #expect(codes == Set(NutrientCode.allCases), "every catalog code is unique + present")
        for item in NutrientCatalog.all {
            #expect(["mg", "ug", "ml"].contains(item.unit), "\(item.code.rawValue) unit must be mg|ug|ml")
            #expect(item.hkIdentifier.hasPrefix("HKQuantityTypeIdentifierDietary"), "\(item.code.rawValue)")
        }
    }

    @Test("Catalog identifier + unit match the server table exactly")
    func catalogMatchesServerTable() {
        func item(_ code: NutrientCode) -> NutrientCatalogItem? {
            NutrientCatalog.all.first { $0.code == code }
        }
        #expect(item(.vitaminA)?.hkIdentifier == "HKQuantityTypeIdentifierDietaryVitaminA")
        #expect(item(.vitaminA)?.unit == "ug")
        #expect(item(.vitaminC)?.unit == "mg")
        #expect(item(.vitaminB12)?.hkIdentifier == "HKQuantityTypeIdentifierDietaryVitaminB12")
        #expect(item(.vitaminB12)?.unit == "ug")
        #expect(item(.water)?.hkIdentifier == "HKQuantityTypeIdentifierDietaryWater")
        #expect(item(.water)?.unit == "ml")
        #expect(item(.caffeine)?.hkIdentifier == "HKQuantityTypeIdentifierDietaryCaffeine")
        #expect(item(.caffeine)?.unit == "mg")
        #expect(item(.pantothenicAcid)?.hkIdentifier == "HKQuantityTypeIdentifierDietaryPantothenicAcid")
    }

    @Test("Energy / macros / sodium / potassium are NOT in the catalog (out of scope)")
    func outOfScopeCodesAbsent() {
        let rawValues = Set(NutrientCode.allCases.map(\.rawValue))
        for excluded in ["energy", "carbohydrates", "protein", "fat", "sugar", "fiber", "sodium", "potassium"] {
            #expect(!rawValues.contains(excluded), "\(excluded) must be out of scope")
        }
        for item in NutrientCatalog.all {
            for banned in ["Sodium", "Potassium", "Carbohydrates", "Protein", "Sugar", "Fiber", "FatTotal", "EnergyConsumed"] {
                #expect(!item.hkIdentifier.contains(banned), "must not request \(banned)")
            }
        }
    }

    // MARK: - NutrientCode wire strings

    @Test("NutrientCode snake_case wire strings match the server enum")
    func codeWireStrings() {
        #expect(NutrientCode.vitaminA.rawValue == "vitamin_a")
        #expect(NutrientCode.pantothenicAcid.rawValue == "pantothenic_acid")
        #expect(NutrientCode.vitaminB6.rawValue == "vitamin_b6")
        #expect(NutrientCode.vitaminB12.rawValue == "vitamin_b12")
        #expect(NutrientCode.thiamin.rawValue == "thiamin")
        #expect(NutrientCode.iodine.rawValue == "iodine")
    }

    // MARK: - Entry encoding

    @Test("Entry encodes { day, nutrient, unit, amount } and omits nil externalSourceVersion")
    func entryEncoding() throws {
        let entry = NutrientIntakeEntryDTO(day: "2026-07-07", nutrient: .vitaminC, unit: "mg", amount: 90.0)
        let data = try JSONEncoder.hlDefault.encode(entry)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["day"] as? String == "2026-07-07")
        #expect(obj["nutrient"] as? String == "vitamin_c")
        #expect(obj["unit"] as? String == "mg")
        #expect(obj["amount"] as? Double == 90.0)
        #expect(obj["externalSourceVersion"] == nil, "nil provenance must be omitted from the wire")
    }

    @Test("Entry encodes externalSourceVersion when present")
    func entryEncodingWithVersion() throws {
        let entry = NutrientIntakeEntryDTO(
            day: "2026-07-07",
            nutrient: .water,
            unit: "ml",
            amount: 2000,
            externalSourceVersion: "iPhone16,2"
        )
        let data = try JSONEncoder.hlDefault.encode(entry)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["externalSourceVersion"] as? String == "iPhone16,2")
    }

    // MARK: - Response decoding

    @Test("Response decodes inserted / updated / skipped statuses")
    func responseDecoding() throws {
        let json = Data("""
        {
          "processed": 3,
          "inserted": 1,
          "updated": 1,
          "skipped": [{ "index": 2, "reason": "unit_mismatch" }],
          "entries": [
            { "index": 0, "status": "inserted" },
            { "index": 1, "status": "updated" },
            { "index": 2, "status": "skipped", "reason": "unit_mismatch" }
          ]
        }
        """.utf8)
        let response = try JSONDecoder().decode(NutrientBatchResponseDTO.self, from: json)
        #expect(response.processed == 3)
        #expect(response.inserted == 1)
        #expect(response.updated == 1)
        #expect(response.skipped.first?.reason == "unit_mismatch")
        #expect(response.entries.map(\.status) == [.inserted, .updated, .skipped])
    }
}
