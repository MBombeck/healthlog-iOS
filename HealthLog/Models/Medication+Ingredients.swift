import Foundation

// SUPP (1.5.0, #131): the composition of a medication, usually a
// supplement, read as the server delivers it (v1.43). `GET /api/medications/{id}`
// carries `ingredients` (what one tablet or capsule contains, labelled in the
// account language); the list rows carry only `hasIngredients`. Every taken
// dose adds `amountPerUnit × unitsPerDose` to the day's micronutrients under the
// source `SUPPLEMENT`, on the server. Nothing here converts or sums.

/// One line of a composition: what one unit of the medication contains.
public struct MedicationIngredient: Codable, Sendable, Hashable {
    /// The nutrient catalogue code, verbatim (`vitamin_d`, `dha`, …).
    public let nutrient: String
    /// Amount in one unit, in the catalogue's canonical ``unit``.
    public let amountPerUnit: Double
    /// Canonical wire unit (`mg` | `ug` | `ml`).
    public let unit: String
    /// The amount as entered, when it was entered in another unit (`IU`).
    public let enteredAmount: Double?
    public let enteredUnit: String?
    /// The nutrient's name in the account language, from the server.
    public let label: String?

    public init(
        nutrient: String,
        amountPerUnit: Double,
        unit: String,
        enteredAmount: Double? = nil,
        enteredUnit: String? = nil,
        label: String? = nil
    ) {
        self.nutrient = nutrient
        self.amountPerUnit = amountPerUnit
        self.unit = unit
        self.enteredAmount = enteredAmount
        self.enteredUnit = enteredUnit
        self.label = label
    }

    /// The name the row shows: the server's `label`, else the app's own name
    /// for the code, else the raw code.
    public var displayName: String {
        if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty { return label }
        return NutrientDisplay.name(for: NutrientCode(tolerant: nutrient), rawCode: nutrient)
    }

    /// "25 µg", or "25 µg (1.000 IE)" when it was entered in another unit.
    public func amountText(locale: Locale = .current) -> String {
        let canonical = NutrientDisplay.formattedIngredient(amount: amountPerUnit, wireUnit: unit, locale: locale)
        guard let enteredAmount, let enteredUnit, !enteredUnit.isEmpty, enteredUnit != unit else {
            return canonical
        }
        let entered = NutrientDisplay.formattedIngredient(amount: enteredAmount, wireUnit: enteredUnit, locale: locale)
        return "\(canonical) (\(entered))"
    }
}

/// The `ingredients` array, decoded leniently like ``RelatedLinks``: a line
/// without a code, an amount or a unit is dropped, the rest stay in the
/// server's order. A value that is not an array reads as empty, so the field
/// can never fail the medication it hangs on.
public struct MedicationIngredients: Codable, Sendable, Hashable {
    public let items: [MedicationIngredient]

    public init(_ items: [MedicationIngredient]) {
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            items = []
            return
        }
        var kept: [MedicationIngredient] = []
        while !container.isAtEnd {
            guard let element = try? container.decode(Lossy.self) else { break }
            if let line = element.line, !line.nutrient.isEmpty, !line.unit.isEmpty { kept.append(line) }
        }
        items = kept
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(items)
    }

    private struct Lossy: Decodable {
        let line: MedicationIngredient?

        init(from decoder: Decoder) throws {
            line = try? MedicationIngredient(from: decoder)
        }
    }
}

public extension Medication {
    /// The composition lines to show, or `nil` when there is nothing to show:
    /// an older server (no field), a list row (the field rides only the single
    /// read) or a medication without a stored composition.
    var compositionLines: [MedicationIngredient]? {
        guard let items = ingredients?.items, !items.isEmpty else { return nil }
        return items
    }

    /// Whether the server says a composition is stored. Lets the page tell a
    /// failed read of an existing composition from a medication without one.
    var expectsComposition: Bool {
        hasIngredients == true || compositionLines != nil
    }
}
