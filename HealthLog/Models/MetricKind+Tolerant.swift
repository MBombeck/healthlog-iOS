import Foundation

// Moved out of `Measurement.swift` (#162) so that file, which sits on a
// baselined `file_length` ceiling, has room for the Garmin cases. Pure move.

/// Tolerant-decoding wrapper used at array-decode sites so a single
/// unknown enum case from the server doesn't reject the whole list
/// (PROJECT_GUIDE.md anti-pattern: "Silent error swallowing — entweder
/// behandeln oder bewusst durchwerfen mit Kontext"). Here we choose
/// "log + continue" — the array survives.
///
/// Use at every decode site that takes a `[MetricKind]`-shaped array
/// of dashboard tiles, sync entries etc. — pre-v0.4.0 the dashboard
/// summary failed wholesale on a single new kind from the server
/// (A4-Audit row 5).
public struct TolerantMetricKind: Decodable, Sendable {
    public let value: MetricKind?

    public init(value: MetricKind?) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let kind = MetricKind(rawValue: raw) {
            value = kind
        } else {
            HLLog.api.warning("Unknown MetricKind raw value: \(raw, privacy: .public) — dropping from array.")
            value = nil
        }
    }
}
