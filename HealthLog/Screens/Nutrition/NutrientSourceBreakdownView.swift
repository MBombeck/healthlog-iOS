import SwiftUI

/// Under the latest day's total on the nutrient page:
/// how much came from Apple Health, from own entries and from supplements, and,
/// only when the server says the day is above it, the upper intake level with
/// its source. Nothing is summed or compared here.
struct NutrientSourceBreakdownView: View {
    let breakdown: NutrientLatestBreakdown

    var body: some View {
        if !breakdown.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                // The fact pair of the design system: side by side, stacked
                // at the accessibility sizes instead of a column of syllables.
                ForEach(breakdown.parts) { part in
                    HLFactRow(label: Text(verbatim: part.source.displayName), value: Text(verbatim: part.amountText))
                        .accessibilityIdentifier("nutrients.detail.source.\(part.source.rawValue)")
                }
                if let note = breakdown.upperLimitNote {
                    Text(note)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, breakdown.parts.isEmpty ? 0 : HLSpace.xxs)
                        .accessibilityIdentifier("nutrients.detail.upperLimit")
                }
            }
        }
    }
}
