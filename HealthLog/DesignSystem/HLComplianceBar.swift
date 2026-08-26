import SwiftUI

/// Shared medication-compliance bar primitive — **FW1-C (M6).**
///
/// `ComplianceBand` (DesignSystem/ComplianceBand.swift) already unified the
/// *colour/threshold* contract across the three med surfaces. But the *bar
/// geometry* was still hand-rolled twice — `ActiveMedicationRow.ComplianceBar`
/// (med-card) and `InsightsMedicationsPage.InsightsComplianceBar` (Insights
/// medications page) each drew their own label row + capsule track + fill +
/// band-tick marks. They had already drifted apart: the card showed 40 %/70 %
/// colour-blind tick marks and an `HLText.tertiary.opacity(0.15)` empty track,
/// while the Insights copy dropped the ticks and used
/// `HLColor.backgroundEleva` for the empty track. Same data, two silhouettes.
///
/// This primitive owns the one canonical geometry so the two call-sites can
/// never drift again:
///
/// - **Label row:** `hlCaption` label (secondary) + `hlCaption`-semibold
///   `"<rate> %"` value (primary, monospaced-digit).
/// - **Track:** 6pt-tall capsule, `HLColor.backgroundEleva` empty tone
///   (the DRIFT-8 convergence token), `ComplianceBand`-coloured fill, animated
///   on `rate` at the shared 0.4 s tempo.
/// - **Band ticks:** 1pt hairlines at the 40 % + 70 % band boundaries
///   (`HLText.tertiary` @ 0.55), so a colour-blind user reads the band even
///   without the hue. Now shown on BOTH surfaces (was card-only).
public struct HLComplianceBar: View {
    private let label: String
    private let rate: Int

    public init(label: String, rate: Int) {
        self.label = label
        self.rate = rate
    }

    private var fillRatio: CGFloat {
        CGFloat(max(0, min(100, rate))) / 100
    }

    private var fillColor: Color {
        ComplianceBand.band(forPercent: rate).color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack {
                Text(label)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                Spacer(minLength: HLSpace.sm)
                Text(HLNumberFormat.percent(rate))
                    .font(.hlCaption.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(HLColor.backgroundEleva)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(0, proxy.size.width * fillRatio))
                        // Smooth the fill grow when `rate` shifts (e.g. operator
                        // taps Genommen and the 7-day rate climbs). Keyed on the
                        // rate Int so SwiftUI re-runs only on real changes.
                        // 0.4 s lines up with the ring-fill tempo.
                        .hlAnimation(.smooth(duration: 0.4), value: rate)
                    // Shape-encode the band boundaries (40 % + 70 %) as a pair of
                    // 1pt-wide × full-height ticks so a colour-blind user still
                    // sees where the warning / good band starts and ends.
                    bandTick(at: 0.40, width: proxy.size.width)
                    bandTick(at: 0.70, width: proxy.size.width)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(
            format: String(localized: "med.card.compliance.a11y"),
            label,
            rate
        )))
    }

    private func bandTick(at fraction: CGFloat, width: CGFloat) -> some View {
        Rectangle()
            .fill(HLText.tertiary.opacity(0.55))
            .frame(width: 1)
            .offset(x: max(0, width * fraction))
    }
}

#Preview("HLComplianceBar") {
    VStack(spacing: HLSpace.lg) {
        HLComplianceBar(label: "7 days", rate: 92)
        HLComplianceBar(label: "30 days", rate: 58)
        HLComplianceBar(label: "90 days", rate: 31)
    }
    .padding(HLSpace.lg)
    .background(HLSurface.primary)
}
