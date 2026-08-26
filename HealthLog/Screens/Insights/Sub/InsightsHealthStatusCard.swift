import SwiftUI

/// v1.25 (GH iOS #38) — the "drifting from your normal" awareness card.
///
/// Renders `GET /api/insights/health-status` (`InsightsHealthStatusDTO`): vitals
/// sitting outside the user's personal band today (deviations) plus dated,
/// sustained level shifts (changepoints). **Server-authoritative,
/// render-don't-recompute** — the bands + shifts arrive already finished; iOS
/// only resolves a localized metric label from the type token and paints.
///
/// **Non-diagnostic framing** mirrors the server's register ("Awareness only,
/// never a diagnosis"). The card **self-suppresses** when the read is absent /
/// not present, exactly like the other conditional insight cards.
struct InsightsHealthStatusCard: View {
    let status: InsightsHealthStatusDTO?

    var body: some View {
        if let status, status.hasContent {
            HLCard(style: .elevated) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLSectionLabel("clinicalSignals.healthStatus.title")

                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        ForEach(status.deviations) { deviation in
                            DeviationRow(deviation: deviation)
                        }
                        ForEach(status.shifts) { shift in
                            ShiftRow(shift: shift)
                        }
                    }

                    Text("clinicalSignals.healthStatus.caption")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("insights.clinicalSignals.healthStatus")
        }
    }
}

/// One out-of-band vital: metric name + today's value + the calm "outside your
/// usual range" subline (with the personal band).
private struct DeviationRow: View {
    let deviation: InsightsHealthStatusDTO.Deviation

    var body: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: deviation.isAbove ? "arrow.up" : "arrow.down")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                    Text(name)
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                    Spacer(minLength: 0)
                    Text(Self.format(deviation.value))
                        .font(.hlSubhead.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                }
                Text(subline)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var name: String {
        deviation.metricKind?.displayName ?? deviation.type
    }

    private var subline: String {
        let band = String(
            format: String(localized: "clinicalSignals.healthStatus.band"),
            Self.format(deviation.low),
            Self.format(deviation.high)
        )
        let direction = deviation.isAbove
            ? String(localized: "clinicalSignals.healthStatus.deviation.above")
            : String(localized: "clinicalSignals.healthStatus.deviation.below")
        return "\(direction) · \(band)"
    }

    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }
}

/// One dated level shift: metric name + the calm "shifted higher/lower since
/// {date}" subline.
private struct ShiftRow: View {
    let shift: InsightsHealthStatusDTO.Shift

    var body: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: shift.isUp ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(name)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                Text(subline)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var name: String {
        shift.metricKind?.displayName ?? shift.metric
    }

    private var subline: String {
        let key = shift.isUp
            ? "clinicalSignals.healthStatus.shift.up"
            : "clinicalSignals.healthStatus.shift.down"
        return String(format: String(localized: String.LocalizationValue(key)), shift.breakDate)
    }
}
