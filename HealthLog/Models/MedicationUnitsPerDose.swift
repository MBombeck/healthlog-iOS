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
    /// **#1034 — any other positive value the server holds**, kept exactly as
    /// sent: a combined value like 1½ (1.5) or 2¼ (2.25), or a measured amount
    /// like 0.8. Since server v1.39.1 (final tag) every write path accepts any
    /// value above 0 and at most 100 with up to four decimals, and the web
    /// editor enters them. This build still offers only the curated choices (a
    /// v1.39.0 server refuses anything else and the app does not probe the
    /// server version for it). This case lets the editor show the real value,
    /// and a save that does not touch the field can never round it to a
    /// curated option.
    case other(Double)

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
        case let .other(value): value
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
    /// **#1034 — any other positive value is kept verbatim** as ``other(_:)``
    /// (1.5, 2.25, a whole above ``wholeMax``): it used to snap to one whole
    /// unit, so the editor showed "1" for a stored 1½. Only a value no server
    /// column can hold (NaN, infinity, ≤0, ≥ ``otherCeiling``) still falls
    /// back to one whole unit.
    public static func from(decimal value: Double) -> MedicationUnitsPerDose {
        if let fraction = fractions.first(where: { abs($0 - value) < 0.0005 }) {
            return .fraction(fraction)
        }
        // `Int(safeServer:)` (W-CRASHGUARD): a non-finite / out-of-range server
        // decimal (`NaN`, `1e308`) returns `nil` here instead of trapping —
        // such a value is "unrecognised" anyway and falls through below.
        if let rounded = Int(safeServer: value), Double(rounded) == value, (1 ... wholeMax).contains(rounded) {
            return .whole(rounded)
        }
        if value.isFinite, value > 0, value < otherCeiling {
            return .other(value)
        }
        // Not a value the server can hold → default to one whole unit.
        return .whole(1)
    }

    /// Exclusive ceiling for ``other(_:)``: the server column is
    /// `Decimal(10,4)`, so nothing at or above a million is a stored value.
    public static let otherCeiling: Double = 1_000_000

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
        case let .other(value):
            Self.mixedLabel(value)
        }
    }

    /// 1.5 → "1½", 2.25 → "2¼", 1.3333 → "1⅓"; anything else as a plain
    /// decimal with up to four places (the column's precision), never rounded
    /// to a curated option.
    static func mixedLabel(_ value: Double) -> String {
        let whole = value.rounded(.down)
        let remainder = value - whole
        if whole >= 1, let fraction = fractions.first(where: { abs($0 - remainder) < 0.0005 }),
           let wholeInt = Int(safeServer: whole)
        {
            return String(wholeInt) + MedicationUnitsPerDose.fraction(fraction).label
        }
        return value.formatted(.number.precision(.fractionLength(0 ... 4)))
    }
}
