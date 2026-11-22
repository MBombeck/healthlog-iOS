import SwiftUI

/// Tinted rounded-square symbol at the leading edge of a row.
///
/// The chip grows with the text beside it, so a row at a large text size does
/// not keep a small symbol next to large type. Growth stops at ``maxSide``:
/// beyond that the chip would take the width the title needs.
public struct HLSettingsIconChip: View {
    /// Side length at the standard text size.
    public nonisolated static let baseSide: CGFloat = HLLayout.rowIcon
    /// Largest side length the chip grows to.
    public nonisolated static let maxSide: CGFloat = HLLayout.rowIcon * 2

    private let symbol: String
    private let tint: Color
    @ScaledMetric(relativeTo: .subheadline) private var scaledSide: CGFloat = HLLayout.rowIcon

    public init(symbol: String, tint: Color) {
        self.symbol = symbol
        self.tint = tint
    }

    /// The side length for a scaled base value, held between the base size
    /// and the cap.
    public nonisolated static func side(forScaled scaled: CGFloat) -> CGFloat {
        min(max(scaled, baseSide), maxSide)
    }

    public var body: some View {
        let side = Self.side(forScaled: scaledSide)
        let scale = side / Self.baseSide
        ZStack {
            RoundedRectangle(cornerRadius: HLRadius.xs * scale, style: .continuous)
                .fill(tint.opacity(0.18))
            // The glyph follows the chip, and the chip already follows the
            // text size, so a text style here would scale it twice.
            Image(systemName: symbol)
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: HLLayout.rowIconGlyph * scale, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

#Preview("HLSettingsIconChip, light") {
    HLSettingsIconChipPreview()
        .preferredColorScheme(.light)
}

#Preview("HLSettingsIconChip, dark") {
    HLSettingsIconChipPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLSettingsIconChip, largest type") {
    HLSettingsIconChipPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLSettingsIconChipPreview: View {
    var body: some View {
        HStack(spacing: HLSpace.md) {
            HLSettingsIconChip(symbol: "heart.fill", tint: HLAccent.userBrandTint)
            HLSettingsIconChip(symbol: "trash.fill", tint: HLColor.statusBad)
            Text("Blood pressure")
                .font(.hlSubhead.weight(.semibold))
        }
        .padding(HLLayout.pageMargin)
        .background(HLSurface.primary)
    }
}
