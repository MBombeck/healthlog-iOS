import SwiftUI

// MARK: - HR zones (W-B182)

/// One HR-zone slice. `index` is the canonical zone number (0–5),
/// `seconds` the time spent in that zone.
///
/// **Split note (file_length-discipline):** moved out of `WorkoutDetailView`
/// in W-B182 when the WHOOP HR-zone surface pushed the detail file past the
/// 600-line cap. Pure section move — no behaviour change.
struct HRZone: Identifiable, Equatable {
    let index: Int
    let label: String
    let seconds: Double
    var id: Int {
        index
    }
}

/// Horizontal stacked bar of time-in-HR-zone proportions plus a per-zone
/// legend with absolute durations. Tonal ramp from the canonical chart tints so
/// it reads as part of the dashboard's mono surface.
struct HRZoneBar: View {
    let zones: [HRZone]

    private var total: Double {
        zones.reduce(0) { $0 + $1.seconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(zones) { zone in
                        Rectangle()
                            .fill(color(for: zone.index))
                            .frame(width: width(for: zone, in: geo.size.width))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            .accessibilityLabel(accessibilitySummary)

            VStack(spacing: HLSpace.xs) {
                ForEach(zones) { zone in
                    HStack(spacing: HLSpace.xs) {
                        Circle()
                            .fill(color(for: zone.index))
                            .frame(width: 8, height: 8)
                        Text(zone.label)
                            .font(.hlCaption.weight(.semibold))
                            .foregroundStyle(HLText.secondary)
                        Spacer()
                        Text(Self.durationLabel(zone.seconds))
                            .font(.hlCaption.monospacedDigit())
                            .foregroundStyle(HLText.primary)
                    }
                }
            }
        }
    }

    private func width(for zone: HRZone, in totalWidth: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return totalWidth * CGFloat(zone.seconds / total)
    }

    /// Zone-0 (rest) → zone-5 (max): cool to warm via the canonical ramp.
    private func color(for index: Int) -> Color {
        switch index {
        case 0: HLChartTints.seriesLow
        case 1: HLChartTints.series.opacity(0.45)
        case 2: HLChartTints.series.opacity(0.7)
        case 3: HLChartTints.series
        case 4: HLColor.statusWarn.opacity(0.8)
        default: HLColor.statusBad.opacity(0.85)
        }
    }

    /// Compact `Hh Mm` / `Mm Ss` label for a zone duration.
    static func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min" }
        return "\(s) s"
    }

    private var accessibilitySummary: Text {
        Text("workout.hrZones.a11y.summary \(zones.count)")
    }
}
