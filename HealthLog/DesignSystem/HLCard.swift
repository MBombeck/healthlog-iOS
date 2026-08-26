import SwiftUI

public enum HLCardStyle {
    case standard
    case elevated
    case ghost
}

public struct HLCard<Content: View>: View {
    public typealias Style = HLCardStyle

    private let style: Style
    private let content: Content

    public init(style: Style = .standard, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
    }

    public var body: some View {
        content
            .padding(HLSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(HLCardBackground(style: style, shape: cardShape))
            .clipShape(cardShape)
            .overlay {
                if style == .ghost {
                    cardShape.stroke(HLColor.separator, lineWidth: 1)
                }
            }
            .hlShadow(style == .elevated ? HLShadow.card : HLShadow.cardLight)
    }
}

/// Applies the card surface. **Liquid-Glass adoption (P0-1):** standard /
/// elevated cards route through `hlGlassBackground` so on iOS 26 every card
/// (Insights, cycle summary, stats, cycle tile) becomes Liquid Glass while
/// iOS 18-25 keeps the exact `HLSurface.secondary` fill via the fallback.
/// Glass is chrome-only — the content layer stays monochrome per doctrine.
/// Ghost stays transparent (overlay-stroked only).
private struct HLCardBackground: ViewModifier {
    let style: HLCardStyle
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        switch style {
        case .standard, .elevated:
            content.hlGlassBackground(in: shape, fallback: HLSurface.secondary)
        case .ghost:
            content.background(Color.clear, in: shape)
        }
    }
}

#Preview("HLCard") {
    VStack(spacing: HLSpace.lg) {
        HLCard {
            Text("Today")
                .font(.hlTitle3)
            Text("Your day, on one card.")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
        }
        HLCard(style: .elevated) {
            Text("Elevated")
                .font(.hlTitle3)
        }
        HLCard(style: .ghost) {
            Text("Ghost")
                .font(.hlBody)
        }
    }
    .padding()
    .background(HLSurface.primary)
}
