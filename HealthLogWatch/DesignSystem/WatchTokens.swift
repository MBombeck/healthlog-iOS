import SwiftUI

// MARK: - Watch-local design tokens

//
// **v0.12 P2 — watchOS companion.** Self-contained tokens for the watch app.
// The iOS `Tokens.swift` / `LiveActivityTokens.swift` use UIKit APIs that are
// unavailable on watchOS (`UIColor(dynamicProvider:)`, `UIColor.label` /
// `.secondaryLabel`, `UITraitCollection.userInterfaceStyle`), so the watch
// gets its own tiny token set instead. Values MIRROR the canonical app tokens
// (`HLSpace`, `HLRadius`, `Font.hl*`, and the `LAColor` Tonal-Mono palette) so
// the watch stays on the documented design system. watchOS renders
// always-dark, so the colours are the dark-scheme variants of the app's
// `LAColor` hexes.

/// Spacing grid — mirrors `HealthLog/DesignSystem/Tokens.swift` `HLSpace`.
enum HLSpace {
    static let hair: CGFloat = 1
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let chip: CGFloat = 6
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let cardInset: CGFloat = 14
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
}

/// Corner radii — mirrors `HLRadius`.
enum HLRadius {
    static let sm: CGFloat = 10
    static let card: CGFloat = 20
    static let button: CGFloat = 14
}

/// Semantic type tokens — mirror `Font.hl*` (semantic Apple text styles, so
/// Dynamic Type on the watch is respected).
extension Font {
    static let hlLargeTitle = Font.system(.largeTitle, weight: .bold)
    static let hlHeadline = Font.system(.headline)
    static let hlBody = Font.system(.body)
    static let hlCallout = Font.system(.callout)
    static let hlSubhead = Font.system(.subheadline)
    static let hlFootnote = Font.system(.footnote)
    static let hlCaption = Font.system(.caption)
}

/// Tonal-Mono palette (dark variants of the app's `LAColor` hexes). Colour is
/// signal-only per STANDARDS §2 — success/warn/danger carry real status,
/// everything else is monochrome text/surface.
enum LAColor {
    static let text = rgb(0xEB, 0xEB, 0xF5)
    static let textSecondary = Color.secondary
    static let surface = rgb(0x1A, 0x1B, 0x1F)
    static let accent = rgb(0xEB, 0xEB, 0xF5)
    static let success = rgb(0x50, 0xFA, 0x7B)
    static let warn = rgb(0xFF, 0xB8, 0x6C)
    static let danger = rgb(0xFF, 0x55, 0x55)

    private static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}
