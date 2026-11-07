import Foundation

// Moved out of `Measurement.swift` unchanged (HK-NEW, 1.5) so that file stays
// under its baselined length while the server-v1.44 kinds join `MetricKind`.

public extension Measurement {
    /// Convenience: scalar-Wert oder für BP der systolische.
    var primaryValue: Double {
        switch value {
        case let .scalar(v): v
        case let .bloodPressure(s, _): s
        }
    }

    /// Severity nach Effective Range. `.ok` wenn keine Bereiche bekannt.
    func severity(against range: EffectiveRange?) -> Severity {
        guard let range else { return .ok }
        let v = primaryValue
        if let lo = range.criticalLow, v < lo { return .critical }
        if let hi = range.criticalHigh, v > hi { return .critical }
        if let lo = range.warnLow, v < lo { return .warning }
        if let hi = range.warnHigh, v > hi { return .warning }
        return .ok
    }
}

public enum Severity: String, Codable, Sendable {
    case ok
    case warning
    case critical
}
