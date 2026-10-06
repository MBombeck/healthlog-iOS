import Foundation

/// **#115 P2 — the target editor in the account's unit.**
///
/// `PUT /api/user/thresholds` and `METRIC_BOUNDS` stay canonical (kg, mg/dL).
/// The web converts at the editor boundary with `resolveTargetUnitAdapter`
/// (`src/lib/targets/target-unit-display.ts`, v1.39.5); this is the same
/// adapter, with the same four round-trip rules:
///
/// 1. To display, a value rounds to the display unit's precision ("150 lb",
///    not "149.99999").
/// 2. To canonical, a typed value rounds to 2 decimals, so 150 lb persists as
///    68.04 kg.
/// 3. 1 + 2 compose back to the typed number: 150 lb → 68.04 kg → 150 lb.
/// 4. The guardrails round INWARD (min up, max down), so a value typed at the
///    edge of the displayed window never inverts outside the canonical window
///    the server enforces (30 kg → 66.2 lb, not 66.1 lb = 29.98 kg).
///
/// On a metric account (and for every metric without a transform) the adapter
/// is the exact identity: no rounding, no arithmetic, the stored threshold is
/// untouched.
public struct ThresholdUnitAdapter: Sendable, Equatable {
    public let transform: UnitDisplayTransform
    /// The unit every label, hint and field on the editor announces.
    public let unit: String

    static let canonicalDecimals = 2

    public var rescales: Bool {
        transform.rescales
    }

    public func toDisplay(_ canonical: Double) -> Double {
        guard rescales else { return canonical }
        return Self.round(transform.display(canonical), decimals: transform.fractionDigits ?? 1)
    }

    public func toCanonical(_ displayed: Double) -> Double {
        guard rescales else { return displayed }
        return Self.round(transform.canonical(fromDisplayed: displayed), decimals: Self.canonicalDecimals)
    }

    /// The display window a typed value is checked against, rounded inward.
    public func bounds(_ canonical: ThresholdMetric.Bounds) -> (min: Double, max: Double) {
        guard rescales else { return (canonical.min, canonical.max) }
        let scale = pow(10, Double(transform.fractionDigits ?? 1))
        let lower = transform.display(canonical.min)
        let upper = transform.display(canonical.max)
        return ((lower * scale).rounded(.up) / scale, (upper * scale).rounded(.down) / scale)
    }

    private static func round(_ value: Double, decimals: Int) -> Double {
        let scale = pow(10, Double(decimals))
        return (value * scale).rounded() / scale
    }
}

public extension ThresholdMetric {
    /// The metric kind whose display transform this threshold follows, or
    /// `nil` for a threshold without one (BP, pulse, body fat, sleep, steps,
    /// SpO₂ keep the unit the server stores them in).
    var displayKind: MetricKind? {
        switch self {
        case .weight: .weight
        case .totalBodyWater: .bodyWater
        case .boneMass: .boneMass
        case .bloodGlucoseFasting, .bloodGlucosePostprandial, .bloodGlucoseRandom, .bloodGlucoseBedtime: .glucose
        case .bloodPressureSys, .bloodPressureDia, .pulse, .bodyFat, .sleepDuration, .activitySteps,
             .oxygenSaturation:
            nil
        }
    }

    /// The editor adapter for this threshold under the account's units.
    func unitAdapter(_ units: UnitPreferences) -> ThresholdUnitAdapter {
        let transform = displayKind.map { units.transform(for: $0) } ?? .identity
        return ThresholdUnitAdapter(transform: transform, unit: transform.suffix ?? bounds.unit)
    }
}
