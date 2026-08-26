import SwiftUI

/// Canonical 4pt spacing scale (C-11 sweep, 2026-05-16).
///
/// Symmetrie-Prinzip: jedes Layout-Padding und VStack/HStack-`spacing` benutzt
/// einen named Token, niemals ein loses Int-Literal. Sub-Grid-Werte (`hair`, `xxs`,
/// `chip`) sind explizit benannt fuer Faelle, in denen ein 4pt-Schritt zu grob
/// waere — chip-internal Vertikal-Padding, Hairline-Clip-Vermeidung,
/// Optical-Adjustment in dichten Listenzeilen.
public enum HLSpace {
    /// 1pt — Hairline, fuer Clip-Vermeidung an Chip-Borders / Sparkline-Edges.
    public static let hair: CGFloat = 1
    /// 2pt — Optical-Adjustment in dichten Listenzeilen / Caption-Stacks.
    public static let xxs: CGFloat = 2
    /// 4pt — kleinster Layout-Schritt (Icon-zu-Text in Buttons).
    public static let xs: CGFloat = 4
    /// 6pt — Chip-internal Vertikal-Padding (TrendChip, HealthScore-Badge).
    public static let chip: CGFloat = 6
    /// 8pt — Standard-Gap in dichten Stacks (Row-vertikal).
    public static let sm: CGFloat = 8
    /// 12pt — Mittlerer Gap (Form-Field-Stacks, Card-internal).
    public static let md: CGFloat = 12
    /// 14pt — Settings-Card-internal Padding (W6-4): zwischen `md` (12) und
    /// `lg` (16), bewusst eng damit eine zweizeilige Settings-Karte weniger
    /// Vertikalraum frisst, ohne den Divider zu quetschen. Benannter Sub-Grid-
    /// Token (wie `chip`), ersetzt den ehemaligen `HLSpacePB.cardInset`.
    public static let cardInset: CGFloat = 14
    /// 16pt — HIG-default Edge-Inset, Card-Padding-Standard.
    public static let lg: CGFloat = 16
    /// 20pt — Section-Top-Gap (legacy, weiterhin in Onboarding aktiv).
    public static let xl: CGFloat = 20
    /// 24pt — Section-Gap (HIG Lockup-Spacing).
    public static let xxl: CGFloat = 24
    /// 32pt — Hero-Section-Gap (Empty-State, Splash).
    public static let xxxl: CGFloat = 32
    /// 40pt — Maximum Layout-Schritt (Onboarding-Hero, Top-Padding).
    public static let xxxxl: CGFloat = 40
}

/// Minimum interaction geometry.
///
/// Until v0.14.1 nothing in the token set named a minimum, so every surface
/// that wrapped a small glyph in a tap target guessed its own: 44×32 for the
/// onboarding back chevron, 36×32 for the Documents bulk bar, 28×28 for the
/// score-card edit button. Three guesses, three different answers, all of them
/// under the HIG figure in at least one direction.
///
/// The number lives here rather than inside the modifier that spends it so a
/// call-site that must state its own frame (a `Button` whose label already
/// carries geometry, say) states the *same* number instead of a fourth guess.
public enum HLHitTarget {
    /// 44pt — the smallest comfortable interaction region (Apple HIG). It is a
    /// property of the *region*, never of the glyph: growing the icon to 44pt
    /// would meet the number and break the visual language it sits in.
    public static let minimum: CGFloat = 44
}

public enum HLRadius {
    public static let xs: CGFloat = 6
    public static let sm: CGFloat = 10
    public static let md: CGFloat = 14
    /// Default radius for Cards.
    public static let lg: CGFloat = 18
    public static let xl: CGFloat = 22
    public static let xxl: CGFloat = 28

    // MARK: - Semantic v0.4.0 aliases (HIG-aligned per component)

    //
    // The numeric scale above stays — these are *named* radii callers should
    // prefer for new code so the meaning is obvious at the call-site and
    // adjustments at the token layer flow through cleanly.

    /// Compact tiles + sparkline cells (Dashboard mini-cards).
    public static let tile: CGFloat = 16
    /// Standard surface cards (HLCard default).
    public static let card: CGFloat = 20
    /// Primary controls + chip buttons.
    public static let button: CGFloat = 14
    /// Bottom sheets + presented dialogs.
    public static let sheet: CGFloat = 28
}
