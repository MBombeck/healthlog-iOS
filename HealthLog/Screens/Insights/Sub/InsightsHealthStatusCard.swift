import SwiftUI

/// v1.25 — the "drifting from your normal" awareness card.
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
            // A card head (15 semibold), not the label over a key figure.
            HLCard("clinicalSignals.healthStatus.title") {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        ForEach(status.deviations) { deviation in
                            DeviationRow(deviation: deviation)
                        }
                        ForEach(status.shifts) { shift in
                            ShiftRow(shift: shift)
                        }
                    }

                    // 1.0.3 (App Review 1.4.1) — how the personal band and the
                    // level shifts are derived, plus the literature behind them.
                    HLSourcesLink(topic: .healthStatus)
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
                .hlText(.rowSubtitle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                    Text(name)
                        .hlText(.rowTitle)
                    Spacer(minLength: 0)
                    Text(Self.format(deviation.value))
                        .font(.hlSubhead.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                }
                Text(subline)
                    .hlText(.rowSubtitle)
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
            format: InsightsHealthStatusCard.bandTemplate(basis: deviation.basis),
            Self.format(deviation.low),
            Self.format(deviation.high)
        )
        let direction = deviation.isAbove
            ? String(localized: "clinicalSignals.healthStatus.deviation.above")
            : String(localized: "clinicalSignals.healthStatus.deviation.below")
        return "\(direction), \(band)"
    }

    static func format(_ value: Double) -> String {
        HLValueFormat.number(value, fractionDigits: 0 ... 1)
    }
}

/// One dated level shift: metric name + the calm "shifted higher/lower since
/// {date}" subline.
private struct ShiftRow: View {
    let shift: InsightsHealthStatusDTO.Shift

    var body: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: shift.isUp ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                .hlText(.rowSubtitle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(name)
                    .hlText(.rowTitle)
                Text(subline)
                    .hlText(.rowSubtitle)
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

extension InsightsHealthStatusCard {
    /// #126 P2 (v1.40.3) — `basis: sameHours` means the band is the usual
    /// range for this time of day (a day still in progress), and the line says
    /// so; `day`, `nil` and a word this build does not know keep the day band.
    static func bandTemplate(basis: String?) -> String {
        basis == "sameHours"
            ? String(localized: "clinicalSignals.healthStatus.band.sameHours")
            : String(localized: "clinicalSignals.healthStatus.band")
    }
}
