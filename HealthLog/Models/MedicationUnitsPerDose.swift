import Foundation

/// **H1/H2 (AUDIT-PARITY-v11612) — curated units-per-dose options.**
///
/// One source of truth for the `unitsPerDose` selector, mirroring the server's
/// `UNITS_PER_DOSE_FRACTIONS` + whole-number contract
/// (`src/lib/validations/medication.ts`): the curated fractions a split pill
/// can take (¼ ⅓ ½ ⅔ ¾, stored as their decimal value) plus whole multi-unit
/// doses 1…N. Thirds are inexact in decimal (⅓ ≈ 0.3333, ⅔ ≈ 0.6667) — the
/// server `@db.Decimal(10,4)` column absorbs the drift, so we match those exact
/// decimals on the wire.
public enum MedicationUnitsPerDose: Hashable, Sendable, CaseIterable, Identifiable {
    /// A curated split-pill fraction (¼ ⅓ ½ ⅔ ¾).
    case fraction(Double)
    /// A whole number of units (1…``wholeMax``).
    case whole(Int)

    /// Server-supported split-pill fractions, decimal values matched exactly.
    public static let fractions: [Double] = [0.25, 0.3333, 0.5, 0.6667, 0.75]
    /// Server cap on a whole-number units-per-dose.
    public static let wholeMax = 100
    /// Whole values surfaced in the picker (1…10 keeps the menu usable; larger
    /// multi-tablet doses are rare and still valid via the model).
    public static let pickerWholeMax = 10

    public var id: Double {
        decimalValue
    }

    /// The decimal value sent on the wire / stored in `unitsPerDose`.
    public var decimalValue: Double {
        switch self {
        case let .fraction(value): value
        case let .whole(value): Double(value)
        }
    }

    /// The curated picker options: the five fractions, then whole 1…10.
    public static var allCases: [MedicationUnitsPerDose] {
        fractions.map { .fraction($0) } + (1 ... pickerWholeMax).map { .whole($0) }
    }

    /// Maps a server-side decimal back onto a curated option. A supported
    /// fraction becomes `.fraction`; ANY whole number the server validator accepts
    /// (1…``wholeMax``) becomes `.whole` **losslessly** — we never clamp a valid
    /// server whole (e.g. 15) down to the picker convenience max, because the edit
    /// sheet would otherwise round-trip that 15 back to the server as 10 (H-1
    /// data-loss). Whole values above ``pickerWholeMax`` are surfaced as an extra
    /// picker row (see ``UnitsPerDosePicker``) so the selection always has a tag.
    /// Only a genuinely unrecognised value (NaN, ≤0, >wholeMax, non-integer
    /// non-fraction) falls back to one whole unit.
    public static func from(decimal value: Double) -> MedicationUnitsPerDose {
        if let fraction = fractions.first(where: { abs($0 - value) < 0.0005 }) {
            return .fraction(fraction)
        }
        // `Int(safeServer:)` (W-CRASHGUARD): a non-finite / out-of-range server
        // decimal (`NaN`, `1e308`) returns `nil` here instead of trapping —
        // such a value is "unrecognised" anyway and falls through to the
        // one-whole-unit default below.
        if let rounded = Int(safeServer: value), Double(rounded) == value, (1 ... wholeMax).contains(rounded) {
            return .whole(rounded)
        }
        // Unknown / out-of-range → default to one whole unit.
        return .whole(1)
    }

    /// Localised display label. Fractions render as their unicode glyph; wholes
    /// as the integer.
    public var label: String {
        switch self {
        case let .fraction(value):
            switch value {
            case 0.25: "¼"
            case 0.3333: "⅓"
            case 0.5: "½"
            case 0.6667: "⅔"
            case 0.75: "¾"
            default: String(format: "%.2f", value)
            }
        case let .whole(value):
            String(value)
        }
    }
}
