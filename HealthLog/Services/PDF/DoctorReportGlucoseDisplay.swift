import Foundation

/// **#115 B5 — glucose in the local doctor report prints in the account's unit.**
/// **#115 P2 — and so do weight, temperature, waist and distance.**
///
/// The spec carries canonical values (the FHIR bundle built from the same spec
/// must stay UCUM mg/dL, kg, °C). The PDF converts at the last moment, here,
/// with the one transform every other surface in the app uses
/// (`UnitPreferences.transform(for:)`), and labels the value with the unit it is
/// printed in. A kind whose transform does not rescale (every kind on a metric
/// account except glucose) keeps its canonical label and the report's own
/// precision, exactly as before. Blood pressure always prints mmHg
/// (`DoctorReportSpec.printUnits`).
enum DoctorReportGlucoseDisplay {
    /// Whether the PDF converts `kind` under `units`: glucose always (B5),
    /// every other family only when its transform actually rescales.
    private static func converts(_ kind: MetricKind, units: UnitPreferences) -> Bool {
        guard kind.unitFamily != nil, kind.unitFamily != .bloodPressure else { return false }
        return kind == .glucose || units.transform(for: kind).rescales
    }

    /// A canonical value of `kind`, in the unit the PDF prints it in.
    static func value(_ canonical: Double, kind: MetricKind, units: UnitPreferences) -> Double {
        converts(kind, units: units) ? units.displayValue(canonical, kind: kind) : canonical
    }

    /// The unit label the PDF prints next to a value of `kind`.
    static func unit(for kind: MetricKind, units: UnitPreferences) -> String {
        converts(kind, units: units) ? units.unitLabel(for: kind) : kind.unit
    }

    /// Fraction digits for a converted kind (whole mg/dL, one decimal mmol/L,
    /// lb, °F, in; two for mi). `nil` → the report's own precision.
    static func fractionDigits(for kind: MetricKind, units: UnitPreferences) -> Int? {
        converts(kind, units: units) ? units.transform(for: kind).fractionDigits : nil
    }

    /// A chart series with its points in the printed unit.
    static func series(
        _ series: DoctorReportSpec.ChartsBlock.Series,
        units: UnitPreferences
    ) -> DoctorReportSpec.ChartsBlock.Series {
        guard converts(series.kind, units: units) else { return series }
        return DoctorReportSpec.ChartsBlock.Series(
            kind: series.kind,
            points: series.points.map { point in
                DoctorReportSpec.ChartsBlock.Point(
                    at: point.at,
                    value: value(point.value, kind: series.kind, units: units),
                    secondary: point.secondary
                )
            }
        )
    }

    /// The chart tile's title suffix: the printed unit of a converted kind.
    static func titleUnit(for kind: MetricKind, units: UnitPreferences) -> String? {
        converts(kind, units: units) ? units.unitLabel(for: kind) : nil
    }

    // MARK: - B5 glucose-only entry points (unchanged behaviour)

    static func value(_ canonical: Double, kind: MetricKind, glucoseUnit: GlucoseUnit) -> Double {
        value(canonical, kind: kind, units: UnitPreferences(glucose: glucoseUnit))
    }

    static func unit(for kind: MetricKind, glucoseUnit: GlucoseUnit) -> String {
        unit(for: kind, units: UnitPreferences(glucose: glucoseUnit))
    }

    static func fractionDigits(for kind: MetricKind, glucoseUnit: GlucoseUnit) -> Int? {
        fractionDigits(for: kind, units: UnitPreferences(glucose: glucoseUnit))
    }

    static func series(
        _ series: DoctorReportSpec.ChartsBlock.Series,
        glucoseUnit: GlucoseUnit
    ) -> DoctorReportSpec.ChartsBlock.Series {
        self.series(series, units: UnitPreferences(glucose: glucoseUnit))
    }
}
