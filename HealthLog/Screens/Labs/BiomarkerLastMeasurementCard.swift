import SwiftUI

/// v0154 LR-REDO — the "Letzte Messung" card on the biomarker detail page.
///
/// Mirrors the anatomy of the Insights `HeroStrip` "Letzte Messung" block —
/// large value + unit, a small caption underneath = when it was taken, and a
/// status indicator top-right — but is a thin biomarker-specific view because
/// `HeroStrip` is hard-coupled to `ChartDetailStore` / `MetricKind`. The status
/// indicator reuses the NEUTRAL ``LabRangeBadge`` so an out-of-range value reads
/// informative, never an alarm (the server `rangeStatus` is rendered as-is).
struct BiomarkerLastMeasurementCard: View {
    let latest: LabResultDTO

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(valueLabel)
                        .font(.hlMetric(.largeTitle))
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                    Spacer(minLength: HLSpace.sm)
                    LabRangeBadge(status: latest.rangeStatus)
                }
                Text(takenCaption)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var valueLabel: String {
        // Item 1.5 — qualitative rows render their result text, not a phantom 0.
        latest.displayValue
    }

    /// "When taken" caption — relative phrasing paired with the absolute medium
    /// date so it stays coherent with the absolute dates on the "Alle Messungen"
    /// rows directly below (e.g. "Erhoben vor 5 Monaten · 12. Jan. 2026"). Falls
    /// back to the bare medium date when the wire timestamp can't be parsed.
    private var takenCaption: String {
        guard let date = LabsDateFormat.parse(latest.takenAt) else {
            return LabsDateFormat.mediumDate(latest.takenAt)
        }
        let relative = date.formatted(.relative(presentation: .named))
        let absolute = LabsDateFormat.mediumDate(latest.takenAt)
        let template = String(localized: "biomarker.detail.taken.dated")
        return String(format: template, relative, absolute)
    }

    /// One spoken element: value + range status. Distinct from `labs.row.a11y`
    /// (which is name + value + status) so the value isn't read twice — the card
    /// has no separate name line, so a dedicated 2-placeholder string keeps
    /// VoiceOver to a single, non-redundant utterance.
    private var accessibilityText: String {
        let template = String(localized: "biomarker.detail.lastMeasurement.a11y")
        return String(format: template, valueLabel, latest.rangeStatus.localizedLabel)
    }
}
