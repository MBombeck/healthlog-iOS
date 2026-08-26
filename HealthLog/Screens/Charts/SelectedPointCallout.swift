import SwiftUI

/// Floating callout card shown when the user touch-scrubs the chart in the
/// detail view. Renders the formatted date, value(s), source pill, and
/// optional Personal-Record star.
///
/// Lives in its own file so the detail screen stays readable and the callout
/// can be previewed in isolation. Sized small enough to comfortably overlay
/// the chart without obscuring the trace.
public struct SelectedPointCallout: View {
    public let point: SeriesPoint
    public let kind: MetricKind
    public let isPersonalRecord: Bool
    /// A360-5 C-1 — the unit label shown next to the scrubbed value. The host
    /// passes the chart's `displayUnit(units:)` (glucose mg/dL|mmol/L from the
    /// server, weight/BP flipped on-device) so the label matches the converted
    /// number. `nil` falls back to the canonical `kind.unit` (preview / legacy
    /// call-sites).
    public let displayUnit: String?
    /// A360-5 C-1/C-2 — convert the scrubbed value to the user's chosen unit,
    /// matching the hero. Glucose series points are already server-converted.
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

    /// The resolved unit label — host-supplied (unit-aware) when present, else
    /// the canonical `kind.unit`.
    private var resolvedUnit: String {
        displayUnit ?? kind.unit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(formattedDate)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)

            HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                Text(formattedValue)
                    .font(.hlMetric(.title3))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
                Text(resolvedUnit)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                if isPersonalRecord {
                    Image(systemName: "star.fill")
                        .font(.hlIcon(HLIconSize.xs, weight: .bold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("Personal best"))
                }
            }
        }
        .padding(HLSpace.sm)
        .frame(maxWidth: 220, alignment: .leading)
        // Liquid Glass on iOS 26+ via Echo's progressive-enhancement helper —
        // gives the callout the proper Apple-Health "floating-glass" feel
        // (specular highlight + system-tinted blur) without breaking iOS 18-25
        // where we keep the existing elevated surface treatment.
        .hlGlassBackground(
            in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous),
            fallback: HLColor.surfaceElevated
        )
        .overlay(
            RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
                .stroke(HLColor.separator, lineWidth: 0.5)
        )
        .hlShadow(HLShadow.cardLight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Formatting

    private var formattedDate: String {
        point.at.formatted(
            .dateTime.weekday(.abbreviated).day().month().hour().minute()
        )
    }

    /// A360-5 C-1/C-2 — the scrubbed value in the user's chosen unit. BP
    /// converts + honours the kPa 1-decimal branch (was hard-rounded to Int);
    /// weight converts to lb; glucose is already server-converted on the series.
    private var formattedValue: String {
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

    private var accessibilityDescription: Text {
        Text("\(formattedDate), \(formattedValue) \(resolvedUnit)\(isPersonalRecord ? ", persönliche Bestleistung" : "")")
    }
}

#Preview("Single value") {
    SelectedPointCallout(
        point: SeriesPoint(id: "p1", at: .now, value: 72.4, secondary: nil),
        kind: .weight,
        isPersonalRecord: false
    )
    .padding()
    .background(HLColor.background)
}

#Preview("Blood pressure") {
    SelectedPointCallout(
        point: SeriesPoint(id: "p1", at: .now, value: 128, secondary: 82),
        kind: .bloodPressure,
        isPersonalRecord: true
    )
    .padding()
    .background(HLColor.background)
}
