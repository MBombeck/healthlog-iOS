import Foundation

/// #135 (server v1.43) — the comparison band a personal record shows, read
/// straight from the server's `benchmark` (`low`, `high`, `unit`,
/// `sourceLabel`) on `GET /api/personal-records`.
///
/// Until 1.3.0 the band read an on-device provider that hard-coded population
/// means and spreads, and since #115 · 1.3 that provider answered `nil` for
/// every kind, so the band never showed. The server now publishes an age- and
/// sex-aware band where a cited norm exists; the app draws exactly that band
/// and judges nothing: there is no "favourable" or "worse" here, only where
/// the record sits against the two edges the server sent.
///
/// The band converts with the record itself: when the benchmark is
/// in the record's own unit, both take the record's account transform, so an
/// imperial account reads grip strength in lb on the value and the band
/// alike. A benchmark in any other unit is not drawn: the app cannot place a
/// value against a band it would have to convert on its own.
struct RecordBenchmarkBand: Equatable, Sendable {
    /// Where the record sits against the band, for the one-line summary.
    enum Region: String, Equatable, Sendable {
        case below
        case inside
        case above
    }

    /// Lower edge in the display unit.
    let low: Double
    /// Upper edge in the display unit.
    let high: Double
    /// The record's value in the same display unit.
    let value: Double
    /// The display unit both are in (may be empty for a unitless score).
    let unit: String
    /// The server's citation, in the account's language.
    let sourceLabel: String

    init(low: Double, high: Double, value: Double, unit: String, sourceLabel: String) {
        self.low = low
        self.high = high
        self.value = value
        self.unit = unit
        self.sourceLabel = sourceLabel
    }

    /// The band for `record`, or `nil` when the server sent none, sent one
    /// the app cannot draw, or sent it in a unit other than the record's.
    init?(record: PersonalRecordDTO, units: UnitPreferences) {
        guard let benchmark = record.benchmark, benchmark.isDrawable, record.value.isFinite else { return nil }
        let recordUnit = record.unit.trimmingCharacters(in: .whitespaces)
        let benchmarkUnit = benchmark.unit.trimmingCharacters(in: .whitespaces)
        guard benchmarkUnit.isEmpty || recordUnit.caseInsensitiveCompare(benchmarkUnit) == .orderedSame else { return nil }
        let transform = record.accountTransform(units)
        let edges = [transform.display(benchmark.low), transform.display(benchmark.high)].sorted()
        self.init(
            low: edges[0],
            high: edges[1],
            value: record.displayValue(units),
            unit: record.displayUnit(units),
            sourceLabel: benchmark.sourceLabel
        )
    }

    var region: Region {
        if value < low { return .below }
        if value > high { return .above }
        return .inside
    }

    /// The one-line summary under the bar: a position, never a verdict.
    var summary: String {
        switch region {
        case .inside: String(localized: "records.comparison.insideBand")
        case .below: String(localized: "records.comparison.belowCentered")
        case .above: String(localized: "records.comparison.aboveCentered")
        }
    }

    /// "35 to 43 ml/kg/min", locale-formatted.
    var formattedRange: String {
        let range = HLNumberFormat.range(Self.format(low), Self.format(high))
        return unit.isEmpty ? range : "\(range) \(unit)"
    }

    var formattedValue: String {
        unit.isEmpty ? Self.format(value) : "\(Self.format(value)) \(unit)"
    }

    /// The bar's x-domain: both edges and the value, padded 8 % so neither the
    /// tick nor an edge sits flush with the capsule end.
    var domain: ClosedRange<Double> {
        let lo = min(low, value)
        let hi = max(high, value)
        let pad = max(hi - lo, 1) * 0.08
        return (lo - pad) ... (hi + pad)
    }

    /// `value`'s position on a track `width` wide, or `nil` for an empty domain.
    func position(of point: Double, width: Double) -> Double? {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0, point.isFinite else { return nil }
        return (point - domain.lowerBound) / span * width
    }

    static func format(_ value: Double) -> String {
        HLValueFormat.number(value, fractionDigits: 0 ... 1)
    }
}
