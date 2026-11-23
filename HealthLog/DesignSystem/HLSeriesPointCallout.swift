import SwiftUI

/// The scrub callout of a metric chart: one `SeriesPoint` formatted in the
/// person's units and drawn as the app's one callout, ``HLScrubCallout``.
///
/// It owns only the formatting (weekday, date and time; a blood pressure as
/// "128/82"; the account's unit) and the personal-best star, so a metric chart
/// and a mood or workout chart read with the same card.
public struct HLSeriesPointCallout: View {
    public let point: SeriesPoint
    public let kind: MetricKind
    public let isPersonalRecord: Bool
    /// The unit label shown next to the scrubbed value: the chart's
    /// `displayUnit(units:)`, so label and converted number agree. `nil`
    /// falls back to the account's label for `kind`.
    public let displayUnit: String?
    @Environment(\.unitPreferences) private var units

    public init(
        point: SeriesPoint,
        kind: MetricKind,
        isPersonalRecord: Bool = false,
        displayUnit: String? = nil
    ) {
        self.point = point
        self.kind = kind
        self.isPersonalRecord = isPersonalRecord
        self.displayUnit = displayUnit
    }

    public var body: some View {
        HLScrubCallout(
            title: Self.title(for: point.at),
            value: Self.value(of: point, kind: kind, units: units),
            unit: displayUnit ?? units.unitLabel(for: kind),
            marksRecord: isPersonalRecord
        )
    }

    /// "Mo., 3. Nov., 08:15": weekday, day and month, time.
    static func title(for date: Date) -> String {
        let weekday = HLDateFormat.weekday(date, abbreviated: true)
        return "\(weekday), \(HLDateFormat.dayMonth(date)), \(HLTimeFormat.time(date))"
    }

    /// The scrubbed value in the account's unit. A blood pressure reads as
    /// both legs; a glucose series is already server-converted.
    static func value(of point: SeriesPoint, kind: MetricKind, units: UnitPreferences) -> String {
        if let secondary = point.secondary {
            return MetricValueFormatter.formatBloodPressure(
                systolic: point.value,
                diastolic: secondary,
                units: units
            )
        }
        return MetricValueFormatter.formatScalar(
            point.value,
            kind: kind,
            units: units,
            glucose: .seriesPreConvertedGlucose
        )
    }
}

#Preview("Single value") {
    HLSeriesPointCallout(
        point: SeriesPoint(id: "p1", at: .now, value: 72.4, secondary: nil),
        kind: .weight
    )
    .padding()
    .background(HLColor.background)
}

#Preview("Blood pressure, personal best") {
    HLSeriesPointCallout(
        point: SeriesPoint(id: "p1", at: .now, value: 128, secondary: 82),
        kind: .bloodPressure,
        isPersonalRecord: true
    )
    .padding()
    .background(HLColor.background)
}
