import Foundation
@testable import HealthLog
import Testing

/// SUPP (1.5.0, #131) — reading a supplement's composition and the
/// nutrient split by source (server v1.43). Everything shown is the server's:
/// no unit conversion, no sum, no limit of the app's own.
@Suite("Supplement composition and nutrient sources")
@MainActor
struct SupplementCompositionTests {
    private static func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
        try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
    }

    private static let de = Locale(identifier: "de_DE")

    /// `GET /api/medications/{id}` of the #131 acceptance supplement:
    /// 25 µg vitamin D per capsule (entered as 1000 IU), two capsules a dose.
    private static func medicationJSON(_ tail: String) -> String {
        #"{"id":"med_d3","name":"Vitamin D3","dose":"2 Kapseln","unitsPerDose":2,"active":true,"schedules":[]\#(tail)}"#
    }

    private static let vitaminD =
        #"{"nutrient":"vitamin_d","amountPerUnit":25,"unit":"ug","enteredAmount":1000,"enteredUnit":"IU","labelKey":"nutrients.names.vitamin_d","label":"Vitamin D"}"#
    private static let dha =
        #"{"nutrient":"dha","amountPerUnit":250,"unit":"mg","enteredAmount":null,"enteredUnit":null,"labelKey":"nutrients.names.dha","label":"DHA (Omega-3)"}"#

    // MARK: - Composition on the medication

    @Test("The composition reads as delivered: server name, amount per unit, the entered amount beside it")
    func compositionAsDelivered() throws {
        let json = Self.medicationJSON(#","hasIngredients":true,"ingredients":[\#(Self.vitaminD),\#(Self.dha)]"#)
        let medication = try Self.decode(MedicationWireDTO.self, json).toDomain()
        let lines = try #require(medication.compositionLines)
        #expect(lines.map(\.nutrient) == ["vitamin_d", "dha"])
        #expect(lines.map(\.displayName) == ["Vitamin D", "DHA (Omega-3)"])
        #expect(lines[0].amountPerUnit == 25)
        let glyph = NutrientDisplay.ingredientUnitGlyph("IU")
        #expect(lines[0].amountText(locale: Self.de) == "25 µg (1.000 \(glyph))")
        #expect(lines[1].amountText(locale: Self.de) == "250 mg", "no entered unit, no bracket")
        #expect(medication.expectsComposition)
    }

    @Test("Server without the fields: no composition, nothing expected")
    func olderServerShowsNothing() throws {
        let medication = try Self.decode(MedicationWireDTO.self, Self.medicationJSON("")).toDomain()
        #expect(medication.ingredients == nil)
        #expect(medication.hasIngredients == nil)
        #expect(medication.compositionLines == nil)
        #expect(!medication.expectsComposition)
    }

    @Test("A list row says a composition exists; an empty composition shows no section")
    func listRowAndEmpty() throws {
        let row = try Self.decode(MedicationWireDTO.self, Self.medicationJSON(#","hasIngredients":true"#)).toDomain()
        #expect(row.compositionLines == nil, "the list does not carry the lines")
        #expect(row.expectsComposition)
        let none = try Self.decode(MedicationWireDTO.self, Self.medicationJSON(#","hasIngredients":false,"ingredients":[]"#))
            .toDomain()
        #expect(none.compositionLines == nil)
        #expect(!none.expectsComposition)
    }

    @Test("A broken line is dropped, a value that is no list reads as empty, the medication survives")
    func lenientDecoding() throws {
        let broken = #"{"nutrient":"zinc","unit":"mg"}"#
        let json = Self.medicationJSON(#","ingredients":[\#(broken),\#(Self.vitaminD)]"#)
        let medication = try Self.decode(MedicationWireDTO.self, json).toDomain()
        #expect(medication.compositionLines?.map(\.nutrient) == ["vitamin_d"])
        let odd = try Self.decode(MedicationWireDTO.self, Self.medicationJSON(#","ingredients":{"x":1}"#)).toDomain()
        #expect(odd.compositionLines == nil)
        #expect(odd.name == "Vitamin D3")
    }

    @Test("A medication cached by 1.4.1 (no composition keys) decodes; a cached composition survives")
    func updatePath() throws {
        let plain = try Self.decode(MedicationWireDTO.self, Self.medicationJSON("")).toDomain()
        let oldBlob = try JSONEncoder.hlDefault.encode(plain)
        #expect(String(bytes: oldBlob, encoding: .utf8)?.contains("ingredients") == false)
        let restored = try JSONDecoder.hlDefault.decode(Medication.self, from: oldBlob)
        #expect(restored.compositionLines == nil)

        let json = Self.medicationJSON(#","hasIngredients":true,"ingredients":[\#(Self.vitaminD)]"#)
        let withLines = try Self.decode(MedicationWireDTO.self, json).toDomain()
        let back = try JSONDecoder.hlDefault.decode(Medication.self, from: JSONEncoder.hlDefault.encode(withLines))
        #expect(back.compositionLines == withLines.compositionLines)
        #expect(back.hasIngredients == true)
    }

    @Test("A failed read offers Retry; offline and a refusal show nothing; a cancel changes nothing")
    func compositionModelStates() throws {
        let model = MedicationCompositionModel()
        model.apply(CancellationError())
        #expect(model.state == .idle)
        model.apply(HLError.server(status: 500, code: nil, message: ""))
        #expect(model.state == .failed)
        model.apply(HLError.offline)
        #expect(model.state == .loaded([]))
        let json = Self.medicationJSON(#","ingredients":[\#(Self.vitaminD)]"#)
        try model.apply(Self.decode(MedicationWireDTO.self, json).toDomain())
        guard case let .loaded(lines) = model.state else {
            Issue.record("expected loaded lines")
            return
        }
        #expect(lines.count == 1)
    }

    // MARK: - #131 acceptance: the nutrient page

    /// `GET /api/nutrients/daily?nutrient=vitamin_d` the day after: two
    /// capsules a dose, one dose taken, one skipped. 25 µg × 2 × 1 = 50 µg, all
    /// of it from the supplement. The amounts are the server's.
    private static let acceptanceDaily = #"""
    {"nutrient":"vitamin_d","unit":"ug","windowDays":30,
     "days":[{"day":"2026-11-02","amount":0},
             {"day":"2026-11-03","amount":50,"bySource":{"SUPPLEMENT":50},"aboveUpperLimit":false}],
     "reference":{"kind":"AI","direction":"target","value":15,"source":"EFSA DRV 2016"},
     "upperLimit":{"value":100,"unit":"ug","scope":"total","form":null,"source":"EFSA 2023"}}
    """#

    @Test("#131: 25 µg vitamin D, two capsules, one taken, one skipped: 50 µg, all supplement")
    func acceptanceVitaminD() throws {
        let medication = try Self.decode(
            MedicationWireDTO.self,
            Self.medicationJSON(#","ingredients":[\#(Self.vitaminD)]"#)
        ).toDomain()
        let perUnit = try #require(medication.compositionLines?.first?.amountPerUnit)
        let series = try Self.decode(NutrientDailySeriesDTO.self, Self.acceptanceDaily)
        let latest = try #require(series.latestNonEmptyDay)
        // The server's sum for one taken dose of two capsules.
        #expect(latest.amount == perUnit * medication.effectiveUnitsPerDose * 1)
        #expect(latest.amount == 50)

        let breakdown = NutrientStore.latestBreakdown(series: series, row: nil)
        #expect(breakdown.parts == [NutrientSourcePart(source: .supplement, amount: 50, unit: "ug")])
        #expect(breakdown.parts.first?.amountText == NutrientDisplay.formatted(amount: 50, wireUnit: "ug"))
        #expect(breakdown.upperLimitNote == nil, "below the level: no note")
    }

    @Test("Server without the fields: no split and no note on the nutrient page")
    func nutrientPageOlderServer() throws {
        let json = #"{"nutrient":"vitamin_d","unit":"ug","windowDays":30,"days":[{"day":"2026-11-03","amount":12}],"reference":null}"#
        let series = try Self.decode(NutrientDailySeriesDTO.self, json)
        #expect(series.upperLimit == nil)
        #expect(series.days.first?.bySource == nil)
        let overview = try Self.decode(
            NutrientOverviewDTO.self,
            #"{"windowDays":90,"nutrients":[{"nutrient":"vitamin_d","unit":"ug","latestDay":"2026-11-03","latestAmount":12,"daysWithData":1}]}"#
        )
        let row = try #require(overview.nutrients.first)
        #expect(row.latestBySource == nil && row.upperLimit == nil && row.latestAboveUpperLimit == nil)
        #expect(NutrientStore.latestBreakdown(series: series, row: row).isEmpty)
    }

    @Test("Overview fields decode and stand in for a series that lacks them, only for the same day")
    func overviewFallback() throws {
        let json = #"""
        {"windowDays":90,"nutrients":[{"nutrient":"magnesium","unit":"mg","latestDay":"2026-11-03","latestAmount":420,
        "daysWithData":5,"latestBySource":{"APPLE_HEALTH":170,"SUPPLEMENT":250,"FUTURE":3},
        "upperLimit":{"value":250,"unit":"mg","scope":"supplemental","form":"magnesium_salts","source":"EFSA 2006"},
        "latestAboveUpperLimit":false}]}
        """#
        let row = try #require(Self.decode(NutrientOverviewDTO.self, json).nutrients.first)
        #expect(row.latestBySource?.amounts == ["APPLE_HEALTH": 170, "SUPPLEMENT": 250, "FUTURE": 3])
        #expect(row.upperLimit?.resolvedScope == .supplemental)
        let breakdown = NutrientStore.latestBreakdown(series: nil, row: row)
        #expect(breakdown.parts.map(\.source) == [.appleHealth, .supplement], "source order, unknown source skipped")
        #expect(breakdown.upperLimitNote == nil)

        let otherDay = NutrientDailySeriesDTO(
            nutrient: .magnesium, unit: "mg", windowDays: 30,
            days: [NutrientDayPointDTO(day: "2026-11-04", amount: 10)], reference: nil
        )
        #expect(NutrientStore.latestBreakdown(series: otherDay, row: row).parts.isEmpty, "a row of another day says nothing")
    }

    @Test("The upper limit shows only on the server's verdict, with its source")
    func upperLimitOnlyOnVerdict() {
        let limit = NutrientUpperLimit(value: 100, unit: "ug", scope: "total", form: nil, source: "EFSA 2023")
        #expect(NutrientDisplay.upperLimitNote(above: nil, limit: limit) == nil)
        #expect(NutrientDisplay.upperLimitNote(above: false, limit: limit) == nil)
        #expect(NutrientDisplay.upperLimitNote(above: true, limit: nil) == nil, "no limit of our own")
        let note = NutrientDisplay.upperLimitNote(above: true, limit: limit)
        #expect(note?.contains("EFSA 2023") == true)
        #expect(note?.contains(NutrientDisplay.formatted(amount: 100, wireUnit: "ug")) == true)

        let supplemental = NutrientUpperLimit(
            value: 250, unit: "mg", scope: "supplemental", form: "magnesium_salts", source: "EFSA 2006"
        )
        let supplementalNote = NutrientDisplay.upperLimitNote(above: true, limit: supplemental)
        #expect(supplementalNote != note)
        #expect(supplementalNote?.hasSuffix(String(localized: "nutrients.upperLimit.form.magnesium_salts")) == true)

        let oddForm = NutrientUpperLimit(value: 1, unit: "mg", scope: "galactic", form: "plasma", source: "X")
        #expect(oddForm.formSentenceKey == nil, "an unknown form is skipped")
        #expect(oddForm.resolvedScope == .total)
    }

    @Test("Every source and every known form has a catalog text, never its key")
    func sourceAndFormNamesResolve() {
        for source in NutrientSource.allCases {
            #expect(source.displayName != "nutrients.source.\(source.rawValue)", "\(source.rawValue)")
            #expect(!source.displayName.isEmpty)
        }
        for form in ["retinol", "folic_acid", "magnesium_salts", "alpha_tocopherol"] {
            let limit = NutrientUpperLimit(value: 1, unit: "mg", scope: "total", form: form, source: "X")
            let key = limit.formSentenceKey ?? ""
            #expect(String(localized: String.LocalizationValue(key)) != key, "\(form)")
        }
        #expect(NutrientDisplay.ingredientUnitGlyph("IU") != "nutrients.unit.IU")
    }

    @Test("A single synced source has nothing to split; a supplement share always shows")
    func visibleParts() {
        #expect(NutrientAmountBySource(["APPLE_HEALTH": 80]).visibleParts.isEmpty)
        #expect(NutrientAmountBySource(["SUPPLEMENT": 50]).visibleParts.map(\.source) == [.supplement])
        #expect(NutrientAmountBySource(["MANUAL": 5, "APPLE_HEALTH": 3]).visibleParts.map(\.source) == [.appleHealth, .manual])
        #expect(NutrientAmountBySource(["MANUAL": 0, "SUPPLEMENT": 0]).visibleParts.isEmpty)
    }

    // MARK: - dha and epa

    @Test("dha and epa decode as named codes with the server's wording")
    func dhaEpaAreNamed() throws {
        let row = #"{"nutrient":"%@","unit":"mg","latestDay":"2026-11-03","latestAmount":250,"daysWithData":1}"#
        let rows = ["dha", "epa"].map { row.replacingOccurrences(of: "%@", with: $0) }.joined(separator: ",")
        let json = #"{"windowDays":90,"nutrients":[\#(rows)]}"#
        let decoded = try Self.decode(NutrientOverviewDTO.self, json).nutrients
        #expect(decoded.map(\.nutrient) == [.dha, .epa])
        #expect(NutrientDisplay.nameKey(for: .dha) == "nutrients.names.dha")
        #expect(NutrientDisplay.name(for: .dha) != "nutrients.names.dha", "the catalog carries the name")
        #expect(NutrientDisplay.name(for: .epa, rawCode: "epa") == NutrientDisplay.name(for: .epa))
    }

    @Test("dha and epa never land in the nutrient batch")
    func dhaEpaNeverInBatch() throws {
        #expect(!NutrientCode.dha.isSyncable && !NutrientCode.epa.isSyncable && !NutrientCode.unknown.isSyncable)
        let catalogSyncable = NutrientCatalog.all.allSatisfy(\.code.isSyncable)
        #expect(catalogSyncable, "HealthKit is never asked for them")
        let entries = [
            NutrientIntakeEntryDTO(day: "2026-11-03", nutrient: .vitaminD, unit: "ug", amount: 5),
            NutrientIntakeEntryDTO(day: "2026-11-03", nutrient: .dha, unit: "mg", amount: 250),
            NutrientIntakeEntryDTO(day: "2026-11-03", nutrient: .epa, unit: "mg", amount: 400)
        ]
        let request = NutrientBatchRequestDTO(entries: entries)
        #expect(request.entries.map(\.nutrient) == [.vitaminD])
        let body = try #require(String(data: JSONEncoder.hlDefault.encode(request), encoding: .utf8))
        #expect(!body.contains("\"dha\"") && !body.contains("\"epa\""))
    }

    // MARK: - No reference (POLISH-A A1)

    /// The server sends `reference: null` for DHA and EPA because EFSA sets one
    /// intake for both together (v1.43 `supplementOnly`), not because the
    /// profile lacks a sex. Only a syncable code's missing reference is the
    /// sex case.
    @Test("DHA and EPA say they have no reference of their own; a syncable code points to the profile sex")
    func missingReferenceReason() {
        #expect(!NutrientDisplay.missingReferenceMeansNoSex(for: .dha))
        #expect(!NutrientDisplay.missingReferenceMeansNoSex(for: .epa))
        #expect(!NutrientDisplay.missingReferenceMeansNoSex(for: .unknown))
        #expect(NutrientDisplay.missingReferenceMeansNoSex(for: .magnesium))
        #expect(NutrientDisplay.missingReferenceMeansNoSex(for: .vitaminA))
        let none = String(localized: "nutrients.detail.reference.none")
        #expect(none != "nutrients.detail.reference.none")
        #expect(!none.localizedCaseInsensitiveContains("Geschlecht"))
    }
}
