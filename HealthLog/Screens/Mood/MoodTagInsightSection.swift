import SwiftUI

/// Tag → avg-mood delta badges.
///
/// "Sport days average 4.2 vs your 3.5 baseline (+0.7)" — the clinical gold.
/// Direction is encoded by **glyph + sign**, NEVER hue: positive = `arrow.up`,
/// negative = `arrow.down`, in the neutral tag capsule. The single accent is
/// NOT used here — tag valence is a soft correlation, kept fully monochrome.
///
/// Sample-gated upstream (`MoodInsights.makeTagDeltas`: ≥3 occurrences AND
/// |delta| ≥ 0.3, sorted by |delta|). Caps at 6 chips with a "show more"
/// reveal; if 0 tags qualify the host omits the whole section.
struct MoodTagInsightSection: View {
    let deltas: [MoodTagDelta]

    @State private var expanded = false

    private static let collapsedCap = 6

    private var visible: [MoodTagDelta] {
        expanded ? deltas : Array(deltas.prefix(Self.collapsedCap))
    }

    var body: some View {
        if deltas.isEmpty {
            EmptyView()
        } else {
            HLCard("What tracks with your mood") {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    HLFlowLayout {
                        ForEach(visible) { delta in
                            chip(delta)
                        }
                    }

                    if deltas.count > Self.collapsedCap {
                        MoodShowMoreLink(isExpanded: $expanded)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A tag is a feature of the days, so it takes the tag capsule; the
    /// arrow and the sign carry the direction, no hue.
    private func chip(_ delta: MoodTagDelta) -> some View {
        HLBadge(Self.badgeTitle(delta), icon: Self.symbol(delta))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(delta.tag))
            .accessibilityValue(Text(Self.accessibilityValue(delta)))
    }

    /// "Sport +0,7": the tag, then its signed swing.
    nonisolated static func badgeTitle(_ delta: MoodTagDelta) -> String {
        "\(delta.tag) \(deltaString(delta.delta))"
    }

    nonisolated static func symbol(_ delta: MoodTagDelta) -> String {
        delta.isPositive ? "arrow.up" : "arrow.down"
    }

    /// `"+0.7"` / `"−0.4"` (proper minus), locale decimal separator.
    nonisolated static func deltaString(_ delta: Double) -> String {
        let magnitude = HLValueFormat.number(abs(delta), fractionDigits: 1 ... 1)
        return delta >= 0 ? "+\(magnitude)" : "−\(magnitude)"
    }

    nonisolated static func accessibilityValue(_ delta: MoodTagDelta) -> String {
        let avg = HLValueFormat.number(delta.average, fractionDigits: 1 ... 1)
        let signed = deltaString(delta.delta)
        return String(localized: "Average \(avg), \(signed) versus your baseline")
    }
}
