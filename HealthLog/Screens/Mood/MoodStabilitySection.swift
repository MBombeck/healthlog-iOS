import SwiftUI

/// v0.10.0 W-Mood-A — the stability gauge + entry-count pair (DESIGN-B §3).
///
/// A **horizontal linear gauge** (NOT a ring — avoids the `HLRing` "progress
/// toward a goal" read and the compliance-ring collision; stability is a
/// *position on a calm↔volatile spectrum*) + one plain-language sentence, in a
/// flat `HLCard`. Paired with a half-width entry-count tile. The two tiles
/// reflow to a single column at accessibility text sizes (DESIGN-A §5.3).
///
/// Color = signal only: the track / fill / number / sentence are *always*
/// monochrome; the single 8-pt marker dot warms to `statusWarn` ONLY when the
/// band is flagged (score < 40), never `statusBad` — volatility is not an error.
struct MoodStabilitySection: View {
    let stability: MoodStability?
    /// Entry count + window-length string for the paired tile.
    let entryCount: Int
    let windowLabel: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var reflowsToColumn: Bool {
        dynamicTypeSize >= .accessibility1
    }

    var body: some View {
        // Stability gate: omit the whole section if < 7 daily-avg days
        // (computed upstream → `stability == nil`). The entry-count tile still
        // shows when there is at least one entry.
        if stability == nil, entryCount == 0 {
            EmptyView()
        } else if reflowsToColumn {
            VStack(spacing: HLSpace.md) {
                if let stability { gaugeCard(stability, fillHeight: false) }
                countCard(fillHeight: false)
            }
        } else {
            // D6-redux (Walkthrough-2): the gauge + count tiles must read as a
            // genuinely equal half-width pair. The earlier `maxHeight: .infinity`
            // on the *outer* card stretched only the invisible layout frame —
            // `HLCard`'s background paints behind its content, which sizes to
            // intrinsic height, so the shorter Entries tile stayed visibly
            // smaller (a transparent gap filled the rest). The fix pushes the
            // stretch *into* the card content (see `fillHeight:`) so the card
            // background itself grows, and pins both via `HStack(alignment: .top)`
            // + `maxWidth: .infinity` for the half-half split.
            HStack(alignment: .top, spacing: HLSpace.md) {
                if let stability {
                    gaugeCard(stability, fillHeight: true)
                        .frame(maxWidth: .infinity)
                } else {
                    // No stability yet → count tile takes the row, half-width
                    // alignment preserved by a spacer.
                    Spacer().frame(maxWidth: .infinity)
                }
                countCard(fillHeight: true)
                    .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Gauge card

    private func gaugeCard(_ stability: MoodStability, fillHeight: Bool) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel("Stability")

                HStack(alignment: .firstTextBaseline) {
                    track(score: stability.score, flagged: stability.band.isFlagged)
                    Spacer(minLength: HLSpace.sm)
                    Text("\(stability.score)")
                        // Audit-01 H3 — semantic metric style (34pt @ Large)
                        // instead of the pixel-locked escape hatch.
                        .font(.hlMetric(.largeTitle))
                        .foregroundStyle(HLText.primary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                HStack {
                    Text("unsettled")
                        .font(.hlCaption2)
                        .foregroundStyle(HLText.tertiary)
                    Spacer()
                    Text("very steady")
                        .font(.hlCaption2)
                        .foregroundStyle(HLText.tertiary)
                }

                Text(Self.sentence(for: stability.band))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: fillHeight ? .infinity : nil,
                alignment: .topLeading
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Mood stability"))
        .accessibilityValue(Text(
            "\(stability.score) of 100, \(Self.bandLabel(for: stability.band)). \(Self.sentence(for: stability.band))"
        ))
    }

    /// The linear gauge: inert track + calm graphite fill + a single marker dot
    /// (the one permitted accent, warmed only when flagged).
    private func track(score: Int, flagged: Bool) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = max(0, min(1, Double(score) / 100))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(HLText.primary.opacity(0.10))
                    .frame(height: 6)
                Capsule()
                    .fill(HLText.primary.opacity(0.55))
                    .frame(width: width * fraction, height: 6)
                Circle()
                    .fill(flagged ? HLColor.statusWarn : HLText.primary)
                    .frame(width: 8, height: 8)
                    .offset(x: max(0, min(width - 8, width * fraction - 4)))
            }
            .frame(height: 8)
        }
        .frame(height: 8)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    // MARK: - Entry-count card

    @ViewBuilder
    private func countCard(fillHeight: Bool) -> some View {
        if entryCount > 0 {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: "calendar")
                            // swiftlint:disable:next dynamic_type_bypass
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(HLText.secondary)
                        Text("Entries")
                            .font(.hlCaption.weight(.semibold))
                            .foregroundStyle(HLText.secondary)
                            .lineLimit(1)
                    }
                    Text("\(entryCount)")
                        // Audit-01 H3 — semantic metric style (34pt @ Large)
                        // instead of the pixel-locked escape hatch.
                        .font(.hlMetric(.largeTitle))
                        .foregroundStyle(HLText.primary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(windowLabel)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .lineLimit(1)
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: fillHeight ? .infinity : nil,
                    alignment: .topLeading
                )
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Band copy

    nonisolated static func bandLabel(for band: MoodStability.Band) -> String {
        switch band {
        case .verySteady: String(localized: "Very steady")
        case .steady: String(localized: "Steady")
        case .variable: String(localized: "Variable")
        case .unsettled: String(localized: "Unsettled")
        case .veryUnsettled: String(localized: "Very unsettled")
        }
    }

    nonisolated static func sentence(for band: MoodStability.Band) -> String {
        switch band {
        case .verySteady: String(localized: "Your mood is very steady.")
        case .steady: String(localized: "Your mood is mostly steady.")
        case .variable: String(localized: "Your mood varies noticeably.")
        case .unsettled: String(localized: "Your mood is fairly changeable.")
        case .veryUnsettled: String(localized: "Your mood swings a lot.")
        }
    }
}
