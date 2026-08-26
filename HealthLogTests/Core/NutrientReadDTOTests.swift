import Foundation
@testable import HealthLog
import Testing

/// Locks the nutrient READ wire DTOs against the server contract (v1.28
/// `GET /api/nutrients`, v1.29 `GET /api/nutrients/daily` +
/// `POST /api/nutrients/water`, GH iOS #48): tolerant decode of every catalog
/// code with its wire unit, missing-field defaults, unknown-code skip, the EFSA
/// reference (all kinds/directions + null), and the water request/response shapes.
@Suite("Nutrient read DTOs — overview + daily + water")
struct NutrientReadDTOTests {
    private static let decoder = JSONDecoder.hlDefault
    private static let encoder = JSONEncoder.hlDefault

    // MARK: - Overview

    @Test("Overview decodes one row per catalog code with its wire unit")
    func overviewDecodesEveryCode() throws {
        // Build a row per catalog code carrying its canonical wire unit.
        let rows = NutrientCatalog.all.map { item in
            #"{"nutrient":"\#(item.code.rawValue)","unit":"\#(item.unit)","latestDay":"2026-07-06","latestAmount":12.5,"daysWithData":3}"#
        }.joined(separator: ",")
        let json = #"{"windowDays":14,"nutrients":[\#(rows)]}"#
        let dto = try Self.decoder.decode(NutrientOverviewDTO.self, from: Data(json.utf8))

        #expect(dto.windowDays == 14)
        #expect(dto.nutrients.count == 26, "all 26 catalog codes decode")
        for row in dto.nutrients {
            let catalog = NutrientCatalog.all.first { $0.code == row.nutrient }
            #expect(row.unit == catalog?.unit, "unit rides the wire, not hardcoded")
            #expect(["mg", "ug", "ml"].contains(row.unit))
        }
    }

    @Test("Overview skips an unknown forward-compat nutrient code, keeps the rest")
    func overviewSkipsUnknownCode() throws {
        let json = #"""
        {"windowDays":14,"nutrients":[
          {"nutrient":"vitamin_c","unit":"mg","latestDay":"2026-07-06","latestAmount":88,"daysWithData":2},
          {"nutrient":"unobtainium","unit":"mg","latestDay":"2026-07-06","latestAmount":1,"daysWithData":1},
          {"nutrient":"water","unit":"ml","latestDay":"2026-07-06","latestAmount":1500,"daysWithData":5}
        ]}
        """#
        let dto = try Self.decoder.decode(NutrientOverviewDTO.self, from: Data(json.utf8))
        #expect(dto.nutrients.count == 2, "unknown code dropped, valid rows survive")
        #expect(dto.nutrients.map(\.nutrient) == [.vitaminC, .water])
    }

    @Test("Overview row tolerates missing numeric + string fields with defaults")
    func overviewToleratesMissingFields() throws {
        // Only `nutrient` present — everything else defaults.
        let json = #"{"nutrients":[{"nutrient":"iron"}]}"#
        let dto = try Self.decoder.decode(NutrientOverviewDTO.self, from: Data(json.utf8))
        #expect(dto.windowDays == 0)
        let row = try #require(dto.nutrients.first)
        #expect(row.nutrient == .iron)
        #expect(row.unit.isEmpty)
        #expect(row.latestAmount == 0)
        #expect(row.daysWithData == 0)
    }

    // MARK: - Daily series + reference

    @Test("Daily series decodes dense days + a PRI target reference")
    func dailySeriesDecodesReference() throws {
        let json = #"""
        {"nutrient":"vitamin_a","unit":"ug","windowDays":3,
         "days":[{"day":"2026-07-04","amount":0},{"day":"2026-07-05","amount":700},{"day":"2026-07-06","amount":650}],
         "reference":{"kind":"PRI","direction":"target","value":650,"source":"EFSA DRV 2015 (retinol equivalents, adults)"}}
        """#
        let dto = try Self.decoder.decode(NutrientDailySeriesDTO.self, from: Data(json.utf8))
        #expect(dto.nutrient == .vitaminA)
        #expect(dto.unit == "ug")
        #expect(dto.days.count == 3)
        let ref = try #require(dto.reference)
        #expect(ref.kind == .pri)
        #expect(ref.direction == .target)
        #expect(ref.value == 650)
        // The latest day carrying data drives the reference progress.
        #expect(dto.latestNonEmptyDay?.day == "2026-07-06")
    }

    @Test("Daily series decodes caffeine safeLevel upperGuidance reference")
    func dailySeriesDecodesSafeLevel() throws {
        let json = #"""
        {"nutrient":"caffeine","unit":"mg","windowDays":1,
         "days":[{"day":"2026-07-06","amount":420}],
         "reference":{"kind":"safeLevel","direction":"upperGuidance","value":400,"source":"EFSA 2015"}}
        """#
        let dto = try Self.decoder.decode(NutrientDailySeriesDTO.self, from: Data(json.utf8))
        let ref = try #require(dto.reference)
        #expect(ref.kind == .safeLevel)
        #expect(ref.direction == .upperGuidance)
        #expect(ref.value == 400)
    }

    @Test("Daily series tolerates a null reference (profile sex unknown)")
    func dailySeriesNullReference() throws {
        let json = #"""
        {"nutrient":"vitamin_c","unit":"mg","windowDays":1,"days":[{"day":"2026-07-06","amount":90}],"reference":null}
        """#
        let dto = try Self.decoder.decode(NutrientDailySeriesDTO.self, from: Data(json.utf8))
        #expect(dto.reference == nil)
    }

    @Test("Daily series nils a malformed reference instead of failing the decode")
    func dailySeriesMalformedReferenceNils() throws {
        // Unknown `kind` — the reference nils, the series still decodes.
        let json = #"""
        {"nutrient":"zinc","unit":"mg","windowDays":1,"days":[{"day":"2026-07-06","amount":9}],
         "reference":{"kind":"BOGUS","direction":"target","value":9,"source":"x"}}
        """#
        let dto = try Self.decoder.decode(NutrientDailySeriesDTO.self, from: Data(json.utf8))
        #expect(dto.nutrient == .zinc)
        #expect(dto.reference == nil, "malformed reference is dropped, not fatal")
    }

    // MARK: - Water write

    @Test("Water request encodes amountMl + mode, omits day when nil")
    func waterRequestEncodes() throws {
        let body = NutrientWaterWriteRequestDTO(amountMl: 300, mode: .add)
        let data = try Self.encoder.encode(body)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["amountMl"] as? Double == 300)
        #expect(obj["mode"] as? String == "add")
        #expect(obj["day"] == nil, "day omitted when nil so the server uses local today")
    }

    @Test("Water request round-trips the outbox payload including an explicit day")
    func waterRequestRoundTrips() throws {
        let body = NutrientWaterWriteRequestDTO(amountMl: 500, mode: .set, day: "2026-07-06")
        let data = try Self.encoder.encode(body)
        let back = try Self.decoder.decode(NutrientWaterWriteRequestDTO.self, from: data)
        #expect(back == body)
    }

    @Test("Water response decodes the MANUAL row and tolerates missing fields")
    func waterResponseDecodes() throws {
        let json = #"{"day":"2026-07-06","nutrient":"water","source":"MANUAL","amount":800,"unit":"ml"}"#
        let dto = try Self.decoder.decode(NutrientWaterWriteResponseDTO.self, from: Data(json.utf8))
        #expect(dto.nutrient == "water")
        #expect(dto.source == "MANUAL")
        #expect(dto.amount == 800)
        #expect(dto.unit == "ml")

        // Missing amount/unit fall back to sane defaults (tolerant).
        let sparse = #"{"day":"2026-07-06"}"#
        let dto2 = try Self.decoder.decode(NutrientWaterWriteResponseDTO.self, from: Data(sparse.utf8))
        #expect(dto2.amount == 0)
        #expect(dto2.unit == "ml")
        #expect(dto2.nutrient == "water")
    }

    // MARK: - Display helpers

    @Test("Unit glyph maps ug to microgram sign, passes others through")
    func unitGlyph() {
        #expect(NutrientDisplay.unitGlyph("ug") == "µg")
        #expect(NutrientDisplay.unitGlyph("mg") == "mg")
        #expect(NutrientDisplay.unitGlyph("ml") == "ml")
        #expect(NutrientDisplay.unitGlyph("weird") == "weird")
    }

    @Test("Progress fraction guards a non-positive or absent reference")
    func progressFraction() {
        #expect(NutrientDisplay.progressFraction(amount: 50, reference: 100) == 0.5)
        #expect(NutrientDisplay.progressFraction(amount: 50, reference: nil) == nil)
        #expect(NutrientDisplay.progressFraction(amount: 50, reference: 0) == nil)
    }
}
