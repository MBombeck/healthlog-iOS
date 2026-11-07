import Foundation

// SUPP-EDIT (1.5.0, #131 P3): the nutrient catalogue as the server serves
// it to the composition form (`GET /api/nutrients/catalog`, v1.43). Every
// code with its canonical unit, its name in the account language and the
// units an amount may be entered in. The form is built from this and converts
// nothing itself: the server stores the canonical amount and keeps the entered
// one beside it.
//
// Not to be confused with ``NutrientCatalog``, the HealthKit side's list of
// syncable codes.

/// One unit an amount may be entered in (`IU` for vitamin D, `g` for a
/// milligram nutrient, …).
public struct NutrientInputUnit: Codable, Sendable, Hashable {
    public let unit: String
    public let factorToCanonical: Double

    public init(unit: String, factorToCanonical: Double) {
        self.unit = unit
        self.factorToCanonical = factorToCanonical
    }
}

/// One catalogue entry. Decoded leniently: a broken input unit costs only
/// itself; an entry without a code or a unit is dropped by the list.
public struct NutrientServerCatalogEntry: Codable, Sendable, Hashable, Identifiable {
    public let code: String
    /// The canonical unit amounts are stored in.
    public let unit: String
    /// The name in the account language; empty when the server sent none.
    public let label: String
    public let syncable: Bool
    public let inputUnits: [NutrientInputUnit]

    public var id: String {
        code
    }

    public init(code: String, unit: String, label: String, syncable: Bool = true, inputUnits: [NutrientInputUnit]) {
        self.code = code
        self.unit = unit
        self.label = label
        self.syncable = syncable
        self.inputUnits = inputUnits
    }

    private enum CodingKeys: String, CodingKey {
        case code, unit, label, syncable, inputUnits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        unit = try c.decode(String.self, forKey: .unit)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        syncable = (try? c.decodeIfPresent(Bool.self, forKey: .syncable)) ?? false
        var units: [NutrientInputUnit] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .inputUnits) {
            while !list.isAtEnd {
                guard let element = try? list.decode(LossyUnit.self) else { break }
                if let unit = element.unit, !unit.unit.isEmpty { units.append(unit) }
            }
        }
        inputUnits = units
    }

    /// The name the form shows: the server's label, else the app's own name
    /// for the code, else the raw code.
    public var displayName: String {
        if !label.trimmingCharacters(in: .whitespaces).isEmpty { return label }
        return NutrientDisplay.name(for: NutrientCode(tolerant: code), rawCode: code)
    }

    /// The units the form offers, in the server's order. The canonical unit
    /// is always among them (the server lists it first).
    public var offeredUnits: [String] {
        let units = inputUnits.map(\.unit)
        return units.isEmpty ? [unit] : units
    }

    private struct LossyUnit: Decodable {
        let unit: NutrientInputUnit?

        init(from decoder: Decoder) throws {
            unit = try? NutrientInputUnit(from: decoder)
        }
    }
}

/// The `{ entries }` payload of `GET /api/nutrients/catalog`.
public struct NutrientServerCatalog: Codable, Sendable, Hashable {
    public let entries: [NutrientServerCatalogEntry]

    public init(entries: [NutrientServerCatalogEntry]) {
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var kept: [NutrientServerCatalogEntry] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .entries) {
            while !list.isAtEnd {
                guard let element = try? list.decode(Lossy.self) else { break }
                if let entry = element.entry, !entry.code.isEmpty, !entry.unit.isEmpty { kept.append(entry) }
            }
        }
        entries = kept
    }

    /// Water is a day total, never an ingredient (as on the web).
    static let notAnIngredient = "water"

    /// What the form offers, in the server's order.
    public var ingredientEntries: [NutrientServerCatalogEntry] {
        entries.filter { $0.code != Self.notAnIngredient }
    }

    public func entry(for code: String) -> NutrientServerCatalogEntry? {
        entries.first { $0.code == code }
    }

    private struct Lossy: Decodable {
        let entry: NutrientServerCatalogEntry?

        init(from decoder: Decoder) throws {
            entry = try? NutrientServerCatalogEntry(from: decoder)
        }
    }
}

// MARK: - Label proposal

/// The `result` of an AI run of kind `SUPPLEMENT_LABEL_EXTRACT`: a proposal
/// only. Nothing is stored until the composition is saved with
/// `source: LABEL_AI`. Amounts are per single unit (the server divides a
/// per-serving label down and says so in ``servingNote``).
public struct SupplementLabelProposal: Decodable, Sendable, Equatable {
    public struct Line: Decodable, Sendable, Equatable {
        public let nutrient: String
        public let amount: Double
        public let unit: String
        /// `low` asks the person to check the line against the label.
        public let isLowConfidence: Bool
        public let printedText: String

        public init(nutrient: String, amount: Double, unit: String, isLowConfidence: Bool = false, printedText: String = "") {
            self.nutrient = nutrient
            self.amount = amount
            self.unit = unit
            self.isLowConfidence = isLowConfidence
            self.printedText = printedText
        }

        private enum CodingKeys: String, CodingKey {
            case nutrient, amount, unit, confidence, printedText
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nutrient = try c.decode(String.self, forKey: .nutrient)
            amount = try c.decode(Double.self, forKey: .amount)
            unit = try c.decode(String.self, forKey: .unit)
            // Anything but a clear `high` asks for a check.
            isLowConfidence = (try? c.decodeIfPresent(String.self, forKey: .confidence)) != "high"
            printedText = (try? c.decodeIfPresent(String.self, forKey: .printedText)) ?? ""
        }
    }

    public let lines: [Line]
    /// Printed lines the server could not match to a nutrient.
    public let unmatched: [String]
    /// What the label printed the amounts for ("per 2 capsules"); shown, never stored.
    public let servingNote: String?

    public init(lines: [Line], unmatched: [String] = [], servingNote: String? = nil) {
        self.lines = lines
        self.unmatched = unmatched
        self.servingNote = servingNote
    }

    private enum CodingKeys: String, CodingKey {
        case ingredients, unmatched, servingNote
    }

    private struct Unmatched: Decodable {
        let printedText: String?
    }

    private struct LossyLine: Decodable {
        let line: Line?

        init(from decoder: Decoder) throws {
            line = try? Line(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var kept: [Line] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .ingredients) {
            while !list.isAtEnd {
                guard let element = try? list.decode(LossyLine.self) else { break }
                if let line = element.line, !line.nutrient.isEmpty { kept.append(line) }
            }
        }
        lines = kept
        let rawUnmatched = (try? c.decodeIfPresent([Unmatched].self, forKey: .unmatched)) ?? []
        unmatched = rawUnmatched.compactMap(\.printedText).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let note = try? c.decodeIfPresent(String.self, forKey: .servingNote)
        servingNote = note.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }
}
