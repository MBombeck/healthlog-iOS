import SwiftUI

/// v0.10.0 W-Mood-A — tag → avg-mood delta chips (DESIGN-B §4).
///
/// "Sport days average 4.2 vs your 3.5 baseline (+0.7)" — the clinical gold.
/// Direction is encoded by **glyph + ink-weight + sign**, NEVER hue: positive
/// = `arrow.up` semibold `HLText.primary`; negative = `arrow.down` regular
/// `HLText.secondary` (visibly behind). The single accent is NOT used here —
/// tag valence is a soft correlation, kept fully monochrome.
///
/// Sample-gated upstream (`MoodInsights.makeTagDeltas`: ≥3 occurrences AND
/// |delta| ≥ 0.3, sorted by |delta|). Caps at 6 chips with a "show more"
/// reveal; if 0 tags qualify the host omits the whole section.
struct MoodTagInsightSection: View {
    let deltas: [MoodTagDelta]

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let collapsedCap = 6

    private var visible: [MoodTagDelta] {
        expanded ? deltas : Array(deltas.prefix(Self.collapsedCap))
    }

    var body: some View {
        if deltas.isEmpty {
            EmptyView()
        } else {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    Text("What tracks with your mood")
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.primary)

                    TagChipFlow(spacing: HLSpace.sm) {
                        ForEach(visible) { delta in
                            chip(delta)
                        }
                    }

                    if deltas.count > Self.collapsedCap {
                        Button {
                            withAnimation(reduceMotion ? nil : HLMotion.spring) { expanded.toggle() }
                        } label: {
                            Text(expanded ? "Show fewer" : "Show more")
                                .font(.hlSubhead.weight(.medium))
                                .foregroundStyle(HLText.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func chip(_ delta: MoodTagDelta) -> some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: delta.isPositive ? "arrow.up" : "arrow.down")
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: 11, weight: delta.isPositive ? .semibold : .regular))
                .foregroundStyle(delta.isPositive ? HLText.primary : HLText.secondary)
            Text(delta.tag)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Text(Self.deltaString(delta.delta))
                .font(.hlCaption.weight(.medium))
                .foregroundStyle(HLText.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, HLSpace.sm)
        .padding(.vertical, HLSpace.chip)
        .background(HLSurface.tertiary, in: RoundedRectangle(cornerRadius: HLRadius.xs, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(delta.tag))
        .accessibilityValue(Text(Self.accessibilityValue(delta)))
    }

    /// `"+0.7"` / `"−0.4"` (proper minus), locale decimal separator.
    nonisolated static func deltaString(_ delta: Double) -> String {
        let magnitude = abs(delta).formatted(.number.precision(.fractionLength(1)))
        return delta >= 0 ? "+\(magnitude)" : "−\(magnitude)"
    }

    nonisolated static func accessibilityValue(_ delta: MoodTagDelta) -> String {
        let avg = delta.average.formatted(.number.precision(.fractionLength(1)))
        let signed = deltaString(delta.delta)
        return String(localized: "Average \(avg), \(signed) versus your baseline")
    }
}

/// A minimal wrapping flow layout for the tag chips (SwiftUI `Layout`).
/// Chips never truncate — they wrap to fewer-per-row at large Dynamic Type.
private struct TagChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
                rows.append(0)
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let maxWidth = proposal.width ?? bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
