import SwiftUI

/// The recovery page's 30-day trend card: symbol, title and value on one line
/// over a tile chart, on a matte `HLCard`, the same anatomy as a Vitalwerte
/// card on the overview.
///
/// 1.4 B3 lifted it out of the overview's "Trends" row; 1.4 B4 removed that
/// row (it repeated Vitalwerte and the Heute tiles). The chart is a slot: the
/// recovery page passes a dated line at the compact chart height, or its
/// skeleton while the line loads.
struct InsightsTrendCard<Plot: View>: View {
    let symbol: String
    let title: String
    let valueText: String
    @ViewBuilder let plot: () -> Plot

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // The head of a Today tile and the compact cell value, as
                // on the overview's Vitals cards. The value is a finished
                // text ("12,4 von 21"), so it takes the compact number font
                // rather than a number and a unit.
                HLAdaptiveStack(spacing: HLSpace.sm) { stacked in
                    HStack(spacing: HLSpace.xs) {
                        HLTileHeaderGlyph(systemName: symbol)
                            .accessibilityHidden(true)
                        HLTileTitleLabel(Text(title))
                    }
                    if !stacked {
                        Spacer(minLength: HLSpace.sm)
                    }
                    Text(valueText)
                        .font(HLValueSize.compact.numberFont)
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                }
                // No sentence under the line: the overview's trend
                // sentence is spoken with the card, not painted under it.
                plot()
            }
        }
    }
}
