import SwiftUI

/// SUPP (1.5.0, #131) — under the latest day's total on the nutrient page:
/// how much came from Apple Health, from own entries and from supplements, and,
/// only when the server says the day is above it, the upper intake level with
/// its source. Nothing is summed or compared here.
struct NutrientSourceBreakdownView: View {
    let breakdown: NutrientLatestBreakdown

    var body: some View {
        if !breakdown.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                ForEach(breakdown.parts) { part in
                    HStack(alignment: .firstTextBaseline) {
                        Text(part.source.displayName)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.secondary)
                        Spacer(minLength: HLSpace.sm)
                        Text(part.amountText)
                            .font(.hlCaption.monospacedDigit())
                            .foregroundStyle(HLText.secondary)
                    }
                    .accessibilityElement(children: .combine)
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
