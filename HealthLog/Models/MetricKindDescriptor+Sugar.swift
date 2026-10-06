// MetricKind/DashboardMetric sugar split out of MetricKindDescriptor.swift (pure move, W-FILELEN).
import Foundation
import SwiftUI

// MARK: - MetricKind sugar

public extension MetricKind {
    /// Shorthand: `MetricKind.weight.descriptor.sfSymbol` etc.
    var descriptor: MetricKindDescriptor {
        MetricKindDescriptor.descriptor(for: self)
    }
}

// MARK: - DashboardMetric integration helpers

public extension DashboardMetric {
    /// Resolves the descriptor for this tile. Convenience pass-through.
    var descriptor: MetricKindDescriptor {
        kind.descriptor
    }

    /// Localized primary value via the descriptor's `FormatStyle`. Nil-safe:
    /// returns the em-dash placeholder when `latestValue == nil`. Replaces
    /// the older `displayValue` for callers that want format-style routing.
    func formattedPrimary() -> String {
        // SWEEP (W-CRASHGUARD) — unsanitized server `latestValue`; `Int(...)`
        // below traps on non-finite AND on finite-but-out-of-`Int.range`. Reject
        // non-finite at the gate, and route every integer conversion through
        // `Int(safeServer:)` → em-dash placeholder on an unrepresentable value.
        guard let latest = latestValue, latest.isFinite else { return "—" }
        switch descriptor.formatStyle {
        case .integer:
            return latest.safeServerIntString()
        case .decimal1:
            return latest.formatted(.number.precision(.fractionLength(1)))
        case .decimal2:
            return latest.formatted(.number.precision(.fractionLength(0 ... 2)))
        case .bloodPressureCompound:
            if let sec = secondaryValue {
                return Double.safeServerBPString(systolic: latest, diastolic: sec)
            }
            return latest.safeServerIntString()
        case .durationHM:
            // Sleep — `latestValue` is hours (server emits unit "h").
            return latest.safeServerSleepDurationHM
        case .groupedInteger:
            return latest.safeServerGroupedIntString
        case .signedDecimal1:
            return MetricKindDescriptor.formatSignedDecimal1(latest)
        }
    }

    /// Unit-aware primary value (v0.11 N1, #115 P2). Every re-unitable family
    /// (mass, blood pressure, glucose, temperature, waist, distance, speed)
    /// converts the canonical SI value into the account's unit through the one
    /// `MetricValueFormatter.account` path; everything else, and the identity
    /// branch of every family, renders in the descriptor's `FormatStyle`
    /// exactly as `formattedPrimary()` does.
    func formattedPrimary(units: UnitPreferences) -> String {
        // SWEEP (H1-class) — same non-finite → `Int()` trap as above; unit
        // conversion preserves non-finite, so guard the gate + the BP `sec`.
        guard let latest = latestValue, latest.isFinite else { return "—" }
        switch kind.unitFamily {
        case .bloodPressure:
            let sysValue = units.convertBloodPressure(latest)
            guard let sec = secondaryValue, sec.isFinite else {
                return units.bloodPressure == .mmHg
                    ? sysValue.safeServerIntString()
                    : sysValue.formatted(.number.precision(.fractionLength(1)))
            }
            let diaValue = units.convertBloodPressure(sec)
            return units.bloodPressure == .mmHg
                ? Double.safeServerBPString(systolic: sysValue, diastolic: diaValue)
                : "\(sysValue.formatted(.number.precision(.fractionLength(1))))/\(diaValue.formatted(.number.precision(.fractionLength(1))))"
        case .none:
            return formattedPrimary()
        case .some:
            return MetricValueFormatter.account(latest, kind: kind, units: units) { converted in
                MetricValueFormatter.styled(converted, style: descriptor.formatStyle)
            }
        }
    }

    /// Unit-aware suffix (v0.11 N1, #115 P2). The account's display unit for a
    /// converted family; otherwise the descriptor's canonical `unitLabel`,
    /// resolved to a `String`.
    func unitSuffix(units: UnitPreferences) -> String {
        units.transform(for: kind).suffix ?? String(localized: descriptor.unitLabel)
    }
}

// MARK: - Unit families (v0.11 N1)

public extension MetricKind {
    /// Which user-selectable display-unit family this metric belongs to, or
    /// `nil` when the metric has no re-unitable display (steps, pulse, …).
    /// Canonical server storage is SI: kg for the weight family, mmHg for
    /// blood-pressure, mg/dL for glucose.
    ///
    /// **#115 P2** — the family set mirrors the server's display-transform
    /// registry (`display-transform.ts`, v1.39.5): the whole mass set (the
    /// server converts fat/fat-free/lean/muscle mass and grip strength to lb,
    /// not just weight), absolute temperatures (affine °C → °F), the signed
    /// temperature deviation (factor only), waist circumference (cm → in),
    /// walking+running distance (m → mi) and walking speed (m/s → mph). The
    /// conversions themselves live in `UnitPreferences.transform(for:)`.
    enum UnitFamily: Sendable, Hashable, CaseIterable {
        case weight
        case bloodPressure
        case glucose
        case temperature
        case temperatureDeviation
        case circumference
        case distance
        case speed
    }

    var unitFamily: UnitFamily? {
        switch self {
        case .weight, .bodyWater, .boneMass, .fatMass, .fatFreeMass, .leanBodyMass, .muscleMass, .gripStrength:
            .weight
        case .bloodPressure: .bloodPressure
        case .glucose: .glucose
        case .bodyTemperature, .skinTemperature, .wristTemperature: .temperature
        case .bodyTemperatureDeviation: .temperatureDeviation
        case .waistCircumference: .circumference
        case .distanceWalkingRunning: .distance
        case .walkingSpeed: .speed
        default: nil
        }
    }
}
