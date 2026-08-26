import Foundation

/// A360-5 C-1/C-2 — the SINGLE unit-aware value+unit formatter shared by every
/// measurement-rendering surface (dashboard tile, chart hero, chart stats row,
/// scrub callout, list rows, chronological feed).
///
/// **Why this exists.** Before this type the dashboard/widget/watch applied the
/// user's `UnitPreferences` (kg→lb, mmHg→kPa, mg/dL→mmol/L) at display time
/// while the drill-down surfaces rendered the RAW canonical value with NO
/// conversion. A user in lb / kPa / mmol/L saw one number on the tile and a
/// DIFFERENT number (and unit) on the detail/list/chart for the same reading —
/// the single most visible "the app disagrees with itself" integrity defect.
///
/// This formatter is the one converter every surface routes through, so the
/// displayed value + the unit label always agree across the whole app. It
/// mirrors `MetricDisplay.formatScalar`/`formatBloodPressure` and
/// `DashboardMetric.formattedPrimary(units:)` exactly (same precision rules);
/// those dashboard formatters remain the canonical reference and are unchanged.
///
/// **Canonical vs. pre-converted glucose (the subtle part).** The server's
/// list endpoint (`GET /api/measurements`) returns canonical values for EVERY
/// kind, but the series endpoint (`GET /api/measurements/series`) converts
/// glucose to the user's preferred unit AT SOURCE (server v1.16.16, W-B187 #29)
/// while leaving weight + blood-pressure canonical. Re-converting an
/// already-converted glucose series point would be the 18× double-convert
/// hazard. So callers declare whether glucose is already pre-converted:
///   • `.canonical` (default) — list rows, weight/BP series points: convert all
///     three families.
///   • `.seriesPreConvertedGlucose` — chart hero/stats/callout points: convert
///     weight + BP, but pass glucose through untouched (server already did it).
///
/// Default-unit users (kg / mmHg / mg/dL) see byte-identical output to the
/// pre-fix code in every mode — the conversion is the identity transform and
/// the precision rules are unchanged. Only non-default-unit users get corrected
/// values.
public enum MetricValueFormatter {
    /// Whether the glucose component of the incoming value has already been
    /// converted to the user's preferred unit by the server.
    public enum GlucoseSourceState: Sendable {
        /// Canonical mg/dL — this formatter converts to the user's unit.
        case canonical
        /// Already server-converted to the user's glucose unit (series payload);
        /// pass the value through unchanged, only resolve the matching label.
        case seriesPreConvertedGlucose
    }

    /// The user-facing unit suffix for `kind` under `units`. For the three
    /// re-unitable families this reflects the chosen unit; otherwise the
    /// canonical `kind.unit`. Identical to `DashboardMetric.unitSuffix(units:)`.
    public static func unitSuffix(for kind: MetricKind, units: UnitPreferences) -> String {
        switch kind.unitFamily {
        case .weight: units.weight.unitSuffix
        case .bloodPressure: units.bloodPressure.unitSuffix
        case .glucose: units.glucose.unitSuffix
        case .none: kind.unit
        }
    }

    /// Formats a scalar canonical value for `kind` in the user's chosen unit.
    /// Mirrors `MetricDisplay.formatScalar` (1-dp weight, integer/1-dp glucose,
    /// `decimal0...1` fallback) and never traps on a non-finite server value.
    public static func formatScalar(
        _ value: Double,
        kind: MetricKind,
        units: UnitPreferences,
        glucose: GlucoseSourceState = .canonical
    ) -> String {
        guard value.isFinite else { return Double.emDashPlaceholder }
        switch kind.unitFamily {
        case .weight:
            return units.convertWeight(value).formatted(.number.precision(.fractionLength(1)))
        case .glucose:
            // `.seriesPreConvertedGlucose` — server already converted to the
            // user's unit; render at the same precision as the dashboard
            // without re-running `convertGlucose` (the 18× double-convert trap).
            let v = glucose == .seriesPreConvertedGlucose ? value : units.convertGlucose(value)
            return units.glucose == .mgdL
                ? v.safeServerIntString()
                : v.formatted(.number.precision(.fractionLength(1)))
        case .bloodPressure, .none:
            break
        }
        // Non-re-unitable kinds: the canonical descriptor precision. The list/
        // chart surfaces this serves only ever feed scalar/decimal kinds here;
        // BP routes through `formatBloodPressure` and the dashboard owns the
        // exotic styles (durationHM / grouped / signed), so a plain
        // round-to-0…1 mirrors the prior call-site behaviour exactly.
        return value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }

    /// Formats a `systolic/diastolic` pair in the user's chosen BP unit. Mirrors
    /// `MetricDisplay.formatBloodPressure`: mmHg stays integer-grained, kPa
    /// renders 1 decimal. (A360-5 C-2 — the chart surfaces previously hard-
    /// rounded to Int, ignoring the kPa decimal branch the dashboard uses.)
    public static func formatBloodPressure(
        systolic s: Double,
        diastolic d: Double,
        units: UnitPreferences
    ) -> String {
        let sysValue = units.convertBloodPressure(s)
        let diaValue = units.convertBloodPressure(d)
        if units.bloodPressure == .mmHg {
            return Double.safeServerBPString(systolic: sysValue, diastolic: diaValue)
        }
        return "\(sysValue.formatted(.number.precision(.fractionLength(1))))/\(diaValue.formatted(.number.precision(.fractionLength(1))))"
    }

    /// Formats a whole `Measurement` (scalar or BP) value-only (no unit suffix)
    /// in the user's chosen unit. Shared by the list row + chronological feed.
    public static func formattedValue(
        _ measurement: Measurement,
        units: UnitPreferences,
        glucose: GlucoseSourceState = .canonical
    ) -> String {
        switch measurement.value {
        case let .scalar(v):
            formatScalar(v, kind: measurement.kind, units: units, glucose: glucose)
        case let .bloodPressure(s, d):
            formatBloodPressure(systolic: s, diastolic: d, units: units)
        }
    }
}
