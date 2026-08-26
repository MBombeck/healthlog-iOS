import SwiftUI

/// **v1.18.7 — "Signals of the day"** (web-parity, ❌-3).
///
/// Renders the server-generated `dailyBriefing.signalsOfDay` — the
/// present-focused lead of the rebuilt daily briefing. Each signal is a calm
/// row: a tone bar + metric glyph + a NOW-anchored headline + one concrete
/// nudge + an optional delta badge. It mirrors the web `BriefingRow` layout
/// (`src/components/insights/daily-briefing.tsx`) one-to-one.
///
/// **Render-only.** The server hands the comparison already finished (delta +
/// tone verdict); iOS never recomputes it. The card self-suppresses when the
/// briefing carries no signals, so pre-v1.18.7 caches paint nothing extra.
///
/// Placement: directly below the `DailyBriefingHero` (the longer-horizon
/// paragraph) inside `InsightsBriefingHero`, matching the web order
/// (signals lead, key-findings trail).
struct InsightsSignalsCard: View {
    let signals: [DailyBriefingSignal]

    var body: some View {
        if !signals.isEmpty {
            HLCard(style: .elevated) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLSectionLabel("insights.signals.title")

                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        ForEach(signals) { signal in
                            SignalRow(signal: signal)
                            if signal.id != signals.last?.id {
                                Divider().background(HLColor.separator)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One "Signal of the day" row — tone bar + glyph + headline + nudge + delta.
private struct SignalRow: View {
    let signal: DailyBriefingSignal

    var body: some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            // Tone accent bar — the single colour cue (monochrome doctrine:
            // headline + nudge stay on the mono text scale).
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(toneColor)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            Image(systemName: glyph)
                .font(.hlCaption)
                .foregroundStyle(toneColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                    Text(signal.headline)
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let delta = signal.delta, !delta.isEmpty {
                        Text(delta)
                            .font(.hlCaption.weight(.medium))
                            .foregroundStyle(toneColor)
                            .lineLimit(1)
                    }
                }
                Text(signal.nudge)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        if let delta = signal.delta, !delta.isEmpty {
            Text("\(signal.headline). \(delta). \(signal.nudge)")
        } else {
            Text("\(signal.headline). \(signal.nudge)")
        }
    }

    private var toneColor: Color {
        switch signal.tone {
        case .good: HLColor.statusOK
        case .watch: HLColor.statusWarn
        case .info: HLText.secondary
        }
    }

    /// Metric → SF Symbol, mirroring the web `METRIC_ICON` map. Unknown keys
    /// fall back to a neutral glyph so a new server metric never breaks layout.
    private var glyph: String {
        switch signal.sourceMetric {
        case "bp": "heart.fill"
        case "weight": "scalemass.fill"
        case "pulse", "resting_hr": "waveform.path.ecg"
        case "mood": "face.smiling"
        case "compliance", "glp1_plateau": "pills.fill"
        case "hrv": "bolt.heart.fill"
        case "sleep": "moon.fill"
        case "steps": "figure.walk"
        case "active_energy": "flame.fill"
        case "flights": "figure.stairs"
        case "distance": "point.topleft.down.to.point.bottomright.curvepath"
        case "vo2_max": "lungs.fill"
        case "body_temp": "thermometer.medium"
        case "readiness": "gauge.with.dots.needle.67percent"
        case "recovery": "heart.text.square.fill"
        default: "sparkles"
        }
    }
}
