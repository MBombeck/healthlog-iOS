import Foundation

// SUPP (1.5.0, #131): where a nutrient amount came from, and the upper
// intake level the server compares it with (v1.43). Both are the server's:
// the app splits nothing itself, sets no limit of its own and shows the limit
// only on the server's `aboveUpperLimit` verdict.

/// The three sources the server splits a day's amount by, in the order the
/// split reads.
public enum NutrientSource: String, CaseIterable, Sendable {
    case appleHealth = "APPLE_HEALTH"
    case manual = "MANUAL"
    case supplement = "SUPPLEMENT"

    /// The localized source name (the server's wording, `nutrients.sources.*`).
    public var displayName: String {
        // The key is built first: an interpolated literal handed straight to
        // `LocalizationValue` becomes the key `nutrients.source.%@`.
        let key = "nutrients.source." + rawValue
        return String(localized: String.LocalizationValue(key))
    }
}

/// `NutrientAmountBySource`: the amount split by source. A source with
/// nothing is absent. Unknown sources and non-numbers are skipped, so the
/// field can never fail the row it hangs on.
public struct NutrientAmountBySource: Codable, Sendable, Equatable {
    /// Raw source key → amount, exactly as sent.
    public let amounts: [String: Double]

    public init(_ amounts: [String: Double]) {
        self.amounts = amounts
    }

    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: AnyKey.self) else {
            amounts = [:]
            return
        }
        var read: [String: Double] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(Double.self, forKey: key), value.isFinite {
                read[key.stringValue] = value
            }
        }
        amounts = read
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(amounts)
    }

    public func amount(_ source: NutrientSource) -> Double {
        amounts[source.rawValue] ?? 0
    }

    /// The parts worth naming, in source order, each above zero. Empty when a
    /// split says nothing a single total does not: one source only, unless
    /// that source is a supplement (the web's rule, so both read the same).
    public var visibleParts: [(source: NutrientSource, amount: Double)] {
        let parts = NutrientSource.allCases.compactMap { source -> (source: NutrientSource, amount: Double)? in
            let value = amount(source)
            return value > 0 ? (source, value) : nil
        }
        guard !parts.isEmpty else { return [] }
        if parts.count < 2, amount(.supplement) <= 0 { return [] }
        return parts
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }
}

/// `NutrientUpperLimit`: the tolerable upper intake level, its unit, whether it
/// covers the total intake or only the supplement share, the chemical form it is
/// set for, and the cited source. Decoded leniently: a limit without a value, a
/// unit or a source is no limit.
public struct NutrientUpperLimit: Codable, Sendable, Equatable {
    public enum Scope: String, Sendable, Equatable {
        case total
        case supplemental
    }

    public let value: Double
    public let unit: String
    /// The raw scope; see ``resolvedScope``.
    public let scope: String?
    /// The raw form (`retinol`, `folic_acid`, `magnesium_salts`,
    /// `alpha_tocopherol`), `nil` where the level covers the nutrient as such.
    public let form: String?
    /// The bare citation, shown verbatim.
    public let source: String

    public init(value: Double, unit: String, scope: String?, form: String? = nil, source: String) {
        self.value = value
        self.unit = unit
        self.scope = scope
        self.form = form
        self.source = source
    }

    /// An unknown scope reads as `total`: the sentence then claims only what
    /// the server's verdict says, that the day is above the level.
    public var resolvedScope: Scope {
        scope.flatMap(Scope.init(rawValue:)) ?? .total
    }

    /// The localized sentence for a known ``form``, `nil` otherwise (an unknown
    /// form is skipped, as the contract asks).
    public var formSentenceKey: String? {
        switch form {
        case "retinol", "folic_acid", "magnesium_salts", "alpha_tocopherol":
            "nutrients.upperLimit.form.\(form ?? "")"
        default:
            nil
        }
    }
}

public extension NutrientDisplay {
    /// The unit as read on screen, including the input unit `IU` (IE in German).
    static func ingredientUnitGlyph(_ wireUnit: String) -> String {
        wireUnit == "IU" ? String(localized: "nutrients.unit.IU") : unitGlyph(wireUnit)
    }

    /// An ingredient amount with up to three decimals, as many as it has:
    /// 0.025 mg of a trace element must not read as 0, and 100 µg never reads
    /// "100,000".
    static func formattedIngredient(amount: Double, wireUnit: String, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 3
        let number = f.string(from: NSNumber(value: amount)) ?? "\(amount)"
        return "\(number) \(ingredientUnitGlyph(wireUnit))"
    }

    /// The upper-limit note, only on the server's verdict: `nil` unless
    /// `above == true` and a limit came with it.
    static func upperLimitNote(above: Bool?, limit: NutrientUpperLimit?, locale: Locale = .current) -> String? {
        guard above == true, let limit else { return nil }
        let amount = formatted(amount: limit.value, wireUnit: limit.unit, locale: locale)
        let sentence = switch limit.resolvedScope {
        case .total:
            String(localized: "nutrients.upperLimit.above \(amount) \(limit.source)")
        case .supplemental:
            String(localized: "nutrients.upperLimit.aboveSupplemental \(amount) \(limit.source)")
        }
        guard let formKey = limit.formSentenceKey else { return sentence }
        return sentence + " " + String(localized: String.LocalizationValue(formKey))
    }
}
