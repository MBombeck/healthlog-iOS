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

    /// Unit-aware primary value (v0.11 N1). For the three metric families the
    /// user can re-unit (weight/body-water/bone-mass → kg|lb, blood-pressure →
    /// mmHg|kPa, glucose → mg/dL|mmol/L) the canonical SI value is converted at
    /// display time and rendered with a precision that suits the target unit.
    /// All other kinds fall through to `formattedPrimary()` unchanged.
    func formattedPrimary(units: UnitPreferences) -> String {
        // SWEEP (H1-class) — same non-finite → `Int()` trap as above; unit
        // conversion preserves non-finite, so guard the gate + the BP `sec`.
        guard let latest = latestValue, latest.isFinite else { return "—" }
        switch kind.unitFamily {
        case .weight:
            let v = units.convertWeight(latest)
            return v.formatted(.number.precision(.fractionLength(1)))
        case .glucose:
            let v = units.convertGlucose(latest)
            // mg/dL is integer-grained; mmol/L needs one decimal.
            return units.glucose == .mgdL
                ? v.safeServerIntString()
                : v.formatted(.number.precision(.fractionLength(1)))
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
        }
    }

    /// Unit-aware suffix (v0.11 N1). Returns the user-chosen suffix for the
    /// three re-unitable families; otherwise the descriptor's canonical
    /// `unitLabel`, resolved to a `String`.
    func unitSuffix(units: UnitPreferences) -> String {
        switch kind.unitFamily {
        case .weight: units.weight.unitSuffix
        case .bloodPressure: units.bloodPressure.unitSuffix
        case .glucose: units.glucose.unitSuffix
        case .none: String(localized: descriptor.unitLabel)
        }
    }
}

// MARK: - Unit families (v0.11 N1)

public extension MetricKind {
    /// Which user-selectable display-unit family this metric belongs to, or
    /// `nil` when the metric has no re-unitable display (steps, pulse, …).
    /// Canonical server storage is SI: kg for the weight family, mmHg for
    /// blood-pressure, mg/dL for glucose.
    enum UnitFamily: Sendable, Hashable {
        case weight
        case bloodPressure
        case glucose
    }

    var unitFamily: UnitFamily? {
        switch self {
        case .weight, .bodyWater, .boneMass: .weight
        case .bloodPressure: .bloodPressure
        case .glucose: .glucose
        default: nil
        }
    }
}
