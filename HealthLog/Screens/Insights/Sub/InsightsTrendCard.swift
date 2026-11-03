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
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: symbol)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .frame(width: 22)
                    Text(title)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Spacer(minLength: HLSpace.sm)
                    Text(valueText)
                        .font(.hlHeadline)
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                }
                // 1.4 B2 — no sentence under the line: the overview's trend
                // sentence is spoken with the card, not painted under it.
                plot()
            }
        }
    }
}
