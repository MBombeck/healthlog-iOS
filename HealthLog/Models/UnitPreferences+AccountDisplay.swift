import Foundation

// MARK: - Account-unit display transform (#115 P2)

//
// The ONE place that knows how a canonical SI value (kg, mmHg, mg/dL, °C, cm,
// m, m/s) turns into the number and the unit the account reads. It mirrors the
// server's display-transform registry (`src/lib/measurements/display-transform.ts`,
// v1.39.5) for the imperial branch: the mass set → lb, waist → in, absolute
// temperatures → °F (affine), the temperature deviation → °F (factor only),
// walking+running distance → mi, walking speed → mph.
//
// Before this, only weight/body-water/bone-mass, blood pressure and glucose
// converted, each surface with its own copy of the arithmetic, and every value
// that did not ride those three paths — a target band, a temperature, a waist,
// a muscle mass — kept its canonical unit on an imperial account. A tester saw
// "162.1 lb" above "Target 61.9–83.3 kg" on the same tile.
//
// **Metric stays byte-identical.** On the metric branch every new family is the
// exact identity (factor 1, offset 0, canonical label, the surface's own
// precision). The server's metric branch shows distance in km and speed in
// km/h; this app has always shown m and m/s there, and that stays as it was —
// this change is about imperial accounts reading their own unit.

/// A linear (or affine) canonical → display mapping plus the label and the
/// precision the display unit is read at.
public struct UnitDisplayTransform: Sendable, Equatable {
    /// `display = canonical * factor + offset` for an absolute value.
    public let factor: Double
    /// Affine shift for an ABSOLUTE value only (°C → °F). Deltas, band widths
    /// and differences take the factor alone.
    public let offset: Double
    /// The unit label the display value carries; `nil` → the surface keeps the
    /// kind's canonical label (identity branch).
    public let suffix: String?
    /// Fixed fraction digits for the display unit; `nil` → the surface keeps
    /// its own precision for the kind (identity branch).
    public let fractionDigits: Int?

    public static let identity = UnitDisplayTransform(factor: 1, offset: 0, suffix: nil, fractionDigits: nil)

    public init(factor: Double, offset: Double = 0, suffix: String?, fractionDigits: Int?) {
        self.factor = factor
        self.offset = offset
        self.suffix = suffix
        self.fractionDigits = fractionDigits
    }

    /// `true` when the number actually changes (imperial branch of a converted
    /// family, lb/kPa/mmol for the device picks).
    public var rescales: Bool {
        factor != 1 || offset != 0
    }

    public func display(_ canonical: Double) -> Double {
        rescales ? canonical * factor + offset : canonical
    }

    public func displayDelta(_ canonicalDelta: Double) -> Double {
        rescales ? canonicalDelta * factor : canonicalDelta
    }

    public func canonical(fromDisplayed displayed: Double) -> Double {
        rescales ? (displayed - offset) / factor : displayed
    }

    /// The display value as text at the transform's fixed precision, or `nil`
    /// when the transform leaves precision to the surface.
    public func formatted(_ canonical: Double) -> String? {
        guard let fractionDigits else { return nil }
        let value = display(canonical)
        guard value.isFinite else { return Double.emDashPlaceholder }
        return fractionDigits == 0
            ? value.safeServerIntString()
            : value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }
}

public extension UnitPreferences {
    /// kg → lb, exact (1 lb = 0.45359237 kg). Same constant as the server.
    internal static let cmToIn = 0.393700787402
    internal static let metresToMiles = 0.000621371192237
    internal static let metresPerSecondToMph = 2.2369362920544

    /// The transform for a unit family under these preferences.
    func transform(for family: MetricKind.UnitFamily) -> UnitDisplayTransform {
        let imperial = system == .imperial
        switch family {
        case .weight:
            return weight == .kg
                ? UnitDisplayTransform(factor: 1, suffix: WeightUnit.kg.unitSuffix, fractionDigits: 1)
                : UnitDisplayTransform(factor: Self.kgToLb, suffix: WeightUnit.lb.unitSuffix, fractionDigits: 1)
        case .bloodPressure:
            return bloodPressure == .mmHg
                ? UnitDisplayTransform(factor: 1, suffix: BloodPressureUnit.mmHg.unitSuffix, fractionDigits: 0)
                : UnitDisplayTransform(factor: Self.mmHgToKPa, suffix: BloodPressureUnit.kPa.unitSuffix, fractionDigits: 1)
        case .glucose:
            return glucose == .mgdL
                ? UnitDisplayTransform(factor: 1, suffix: GlucoseUnit.mgdL.unitSuffix, fractionDigits: 0)
                : UnitDisplayTransform(factor: Self.mgdLToMmolL, suffix: GlucoseUnit.mmolL.unitSuffix, fractionDigits: 1)
        case .temperature:
            return imperial ? UnitDisplayTransform(factor: 1.8, offset: 32, suffix: "°F", fractionDigits: 1) : .identity
        case .temperatureDeviation:
            // A 1 °C deviation is a 1.8 °F deviation, never 33.8 °F. Precision
            // stays with the surface (the signed ±0.0 style).
            return imperial ? UnitDisplayTransform(factor: 1.8, suffix: "°F", fractionDigits: nil) : .identity
        case .circumference:
            return imperial ? UnitDisplayTransform(factor: Self.cmToIn, suffix: "in", fractionDigits: 1) : .identity
        case .distance:
            return imperial ? UnitDisplayTransform(factor: Self.metresToMiles, suffix: "mi", fractionDigits: 2) : .identity
        case .speed:
            return imperial
                ? UnitDisplayTransform(factor: Self.metresPerSecondToMph, suffix: "mph", fractionDigits: 1)
                : .identity
        }
    }

    /// The transform for `kind`; the identity for a kind without a family.
    func transform(for kind: MetricKind) -> UnitDisplayTransform {
        kind.unitFamily.map { transform(for: $0) } ?? .identity
    }

    /// A canonical absolute value of `kind` in the account's unit.
    func displayValue(_ canonical: Double, kind: MetricKind) -> Double {
        transform(for: kind).display(canonical)
    }

    /// A canonical difference / band width of `kind` in the account's unit
    /// (factor only, never the °F offset).
    func displayDelta(_ canonicalDelta: Double, kind: MetricKind) -> Double {
        transform(for: kind).displayDelta(canonicalDelta)
    }

    /// A value typed in the account's unit, back in canonical SI.
    func canonicalValue(fromDisplayed displayed: Double, kind: MetricKind) -> Double {
        transform(for: kind).canonical(fromDisplayed: displayed)
    }

    /// The unit label `kind` reads in: the display unit of a converted family,
    /// otherwise the kind's canonical `unit`.
    func unitLabel(for kind: MetricKind) -> String {
        transform(for: kind).suffix ?? kind.unit
    }
}

// MARK: - Body height (profile column, not a measurement)

public extension UnitPreferences {
    /// **#115 P2** — `User.heightCm` in whole feet + inches, the way a person
    /// states a height (server `src/lib/profile/height-unit-display.ts`,
    /// v1.39.5: `cmToTotalInches = round(cm / 2.54)`). 180 cm → 5 ft 11 in.
    static func feetAndInches(fromCentimetres cm: Double) -> (feet: Int, inches: Int)? {
        guard cm.isFinite, cm > 0, let total = Int(safeServer: (cm / 2.54).rounded()) else { return nil }
        return (total / 12, total % 12)
    }
}
