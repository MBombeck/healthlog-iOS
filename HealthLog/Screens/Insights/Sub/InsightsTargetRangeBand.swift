import Foundation

/// The in-target band ("Zielband") for one personal target from
/// `GET /api/insights/targets`, shared by the Dashboard tile
/// (`DashboardTileTargetResolver`) and the Insights target panel
/// (`InsightsTargetReferencePanel`) so both read the same labels and the same
/// in-range percentage.
///
/// It used to live on `InsightsTargetTileGrid`, which was never mounted and is
/// gone (#115 B7); this helper was the only part of it in use.
enum InsightsTargetRangeBand {
    /// Returns `nil` when no range is configured, the window is insufficient,
    /// or nothing was logged in it — no in-band claim is possible then. The
    /// percentage is the server's own `daysInRange30d / daysLogged30d` tally,
    /// clamped so a malformed payload can never exceed 100 %.
    ///
    /// **#115 P2** — the bounds are canonical on the wire (kg, mg/dL) and are
    /// converted here into the account's unit (``TargetUnitDisplay``), so the
    /// band reads "Target 136.5–183.6 lb" under a "162.1 lb" headline instead
    /// of the kilograms the tester saw.
    nonisolated static func rangeBand(
        range: InsightsTargetsResponseDTO.TargetItem.Range?,
        insufficient: Bool,
        daysInRange30d: Int,
        daysLogged30d: Int,
        unit: String,
        type: String,
        units: UnitPreferences
    ) -> RangeBand? {
        guard let range, !insufficient, daysLogged30d > 0 else { return nil }
        let inRange = max(0, min(daysInRange30d, daysLogged30d))
        let pct = Int((Double(inRange) / Double(daysLogged30d) * 100).rounded())
        let display = TargetUnitDisplay(type: type, serverUnit: unit, units: units)
        return RangeBand(
            lowerLabel: display.bound(range.min),
            upperLabel: display.bound(range.max),
            unit: display.unit.isEmpty ? nil : display.unit,
            pctInRange: pct
        )
    }
}

/// **#115 P2 — the target payload in the account's unit.**
///
/// `GET /api/insights/targets` is canonical on the wire (server
/// `src/lib/targets/target-unit-display.ts`, v1.39.5: "Storage never changes …
/// the adapter converts at the render boundary"): a weight band is kg, a
/// glucose band is mg/dL. Two traps the web handles and this type now handles
/// the same way:
///
/// - The web converts with the account's metric/imperial preference
///   (`resolveTargetUnitAdapter`). A client that prints the payload verbatim
///   shows kg to an imperial account.
/// - A glucose target row carries `unit` = the ACCOUNT's glucose unit
///   (`glucose-builder.ts` `unit = resolveGlucoseUnit(profile.glucoseUnit)`)
///   while `range`/`current`/`average30` stay mg/dL. Printing the payload's
///   `unit` next to its numbers would read "70–140 mmol/L". The label therefore
///   always comes from the conversion, never from the payload, for a converted
///   family.
///
/// Every other target (pulse, steps, body fat, sleep, mood, compliance) has no
/// display transform and passes through with the server's own unit.
struct TargetUnitDisplay: Equatable {
    let transform: UnitDisplayTransform
    /// The unit the band, the average and the "current" hint read in.
    let unit: String
    /// Max fraction digits for a bound (`0 … decimals`).
    let decimals: Int

    init(type: String, serverUnit: String, units: UnitPreferences) {
        let kind = Self.kind(forTargetType: type)
        let transform = kind.map { units.transform(for: $0) } ?? .identity
        self.transform = transform
        unit = transform.suffix ?? serverUnit
        decimals = switch type {
        case "ACTIVITY_STEPS", "PULSE", "RESTING_HR", "MEDICATION_COMPLIANCE": 0
        default: transform.fractionDigits.map { max($0, 0) } ?? 1
        }
    }

    /// The metric kind whose display transform a target type follows, or
    /// `nil` for a target without one. Glucose rows arrive per context
    /// (`BLOOD_GLUCOSE_FASTING`, …) and all follow the glucose unit.
    nonisolated static func kind(forTargetType type: String) -> MetricKind? {
        if type == "BLOOD_GLUCOSE" || type.hasPrefix("BLOOD_GLUCOSE_") { return .glucose }
        return switch type {
        case "WEIGHT": .weight
        case "TOTAL_BODY_WATER": .bodyWater
        case "BONE_MASS": .boneMass
        case "BODY_TEMPERATURE": .bodyTemperature
        case "WAIST_CIRCUMFERENCE": .waistCircumference
        default: nil
        }
    }

    /// A canonical absolute value (a bound, the average, the latest reading)
    /// in the display unit.
    func value(_ canonical: Double) -> Double {
        transform.display(canonical)
    }

    /// A canonical bound as label text: converted, then trimmed to
    /// `0 … decimals` so a whole band reads "120", not "120.0".
    func bound(_ canonical: Double) -> String {
        let displayed = value(canonical)
        guard displayed.isFinite else { return Double.emDashPlaceholder }
        return displayed.formatted(.number.precision(.fractionLength(0 ... decimals)))
    }
}
