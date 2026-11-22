import SwiftUI

/// A bare symbol at the leading edge of a row, in a column as wide as
/// ``HLSettingsIconChip``.
///
/// Symbols differ in width, so a bare symbol beside text lets every row
/// start its text somewhere else. The column keeps one start for all rows,
/// with or without a symbol, and next to rows that carry a chip. It grows
/// with the text exactly as the chip does.
public struct HLRowGlyph: View {
    private let symbol: String?
    private let tint: Color
    @ScaledMetric(relativeTo: .subheadline) private var scaledSide: CGFloat = HLLayout.rowIcon

    /// - Parameter symbol: the SF Symbol, or `nil` for an empty column that
    ///   keeps the text in line with the rows around it.
    public init(symbol: String?, tint: Color = HLText.secondary) {
        self.symbol = symbol
        self.tint = tint
    }

    /// Width of the column for a scaled base value; the same as the chip's.
    public nonisolated static func columnWidth(forScaled scaled: CGFloat) -> CGFloat {
        HLSettingsIconChip.side(forScaled: scaled)
    }

    public var body: some View {
        let side = Self.columnWidth(forScaled: scaledSide)
        let scale = side / HLSettingsIconChip.baseSide
        Group {
            if let symbol {
                // The glyph follows the column, and the column already
                // follows the text size, so a text style would scale twice.
                Image(systemName: symbol)
                    .font(.hlIcon(HLIconSize.rowAction * scale))
                    .foregroundStyle(tint)
            } else {
                Color.clear.frame(height: side)
            }
        }
        .frame(width: side)
        .accessibilityHidden(true)
    }
}

#Preview("HLRowGlyph") {
    HLPage {
        HLCard(layout: .rows) {
            HLRowLayout(title: Text(verbatim: "Blutdruck messen")) {
                EmptyView()
            } leading: {
                HLRowGlyph(symbol: "heart.fill", tint: HLAccent.userBrandTint)
            }
            HLRowLayout(title: Text(verbatim: "Schritte")) {
                EmptyView()
            } leading: {
                HLRowGlyph(symbol: "figure.walk")
            }
            HLRowLayout(title: Text(verbatim: "Ohne Symbol")) {
                EmptyView()
            } leading: {
                HLRowGlyph(symbol: nil)
            }
        }
    }
}
