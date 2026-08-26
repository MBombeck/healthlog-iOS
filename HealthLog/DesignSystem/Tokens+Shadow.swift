import SwiftUI

/// Card elevation shadows — scheme-aware since the v0.14.11 light-theme
/// redesign ("Warmes Papier"). The previous appearance-invariant
/// `Color.black.opacity(0.18)` was tuned for dark surfaces; on the light
/// canvas an 18 % black at 14 pt radius read as a heavy dark halo under every
/// card and drove the "Kontraste viel zu groß" verdict. The shadow ink now
/// resolves through asset-catalog colorsets: **light** gets a soft
/// black @ 0.10 (`card`) / 0.05 (`cardLight`) so elevation reads as gentle
/// paper-lift, while the **dark** slots keep the exact prior 0.18 / 0.08 —
/// dark-mode rendering is pixel-identical. Geometry (radius/offset) is
/// unchanged in both schemes.
public enum HLShadow {
    public static let card = ShadowToken(
        color: Color("ShadowCard", bundle: .main),
        radius: 14,
        x: 0,
        y: 6
    )
    public static let cardLight = ShadowToken(
        color: Color("ShadowCardLight", bundle: .main),
        radius: 10,
        x: 0,
        y: 4
    )
}

public struct ShadowToken: Sendable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat
}

public extension View {
    func hlShadow(_ token: ShadowToken) -> some View {
        shadow(color: token.color, radius: token.radius, x: token.x, y: token.y)
    }
}
