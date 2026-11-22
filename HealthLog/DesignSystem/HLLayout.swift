import SwiftUI

/// Named layout roles over the existing spacing ladder.
///
/// Screen code states the job (`pageMargin`, `cardGap`) instead of the step
/// (`lg`, `xl`), so the same element class has the same measure on every
/// screen. `HLSpace` and `HLRadius` stay as the ladder underneath.
public enum HLLayout {
    /// Horizontal page margin of every screen outside onboarding.
    public static let pageMargin: CGFloat = 16
    /// Width up to which a text or list column grows; beyond it the column
    /// stays centred, so lines stay readable on an iPad or an open Duo.
    public static let readableWidth: CGFloat = 720
    /// Measured width from which two blocks stand side by side: two columns
    /// of 360 plus the gap between them.
    public static let sideBySideMinimum: CGFloat = 736
    /// Widest a grid tile grows, so ring and value never float in empty space.
    public static let tileMaxWidth: CGFloat = 320
    /// Widest a button with a short title grows (in a state lockup, a card):
    /// on a wide window a full-width bar of 700 pt reads as a frame, not a button.
    public static let actionMaxWidth: CGFloat = 320
    /// Gap between the navigation area and the first element of a page.
    public static let pageTop: CGFloat = 12
    /// Free room below the last element of a page.
    public static let pageBottom: CGFloat = 32
    /// The one gap between two cards, across and down alike: card to card,
    /// tile to tile, column to column. Equal to the page margin.
    public static let cardGap: CGFloat = 16
    /// Gap inside a tile grid. Tiles are cards, so it is the card gap: a grid
    /// beside a column must not stand tighter than the column gap.
    public static let tileGap: CGFloat = cardGap
    /// Gap between the cells of a statistic row (Min, Ø, Max). Tighter than
    /// ``cardGap``: the cells are recessed parts of one card, not cards of
    /// their own, and four of them share a phone-wide row.
    public static let statCellGap: CGFloat = 8
    /// Narrowest a statistic cell gets before its row breaks: four cells
    /// still stand side by side in a card on a 320 pt window.
    public static let statCellMinWidth: CGFloat = 52
    /// Room above a section header.
    public static let sectionGapBefore: CGFloat = 24
    /// Room between a section header and the first card under it.
    public static let sectionGapAfter: CGFloat = 8
    /// Inner padding of a card: on every side around free content, on the
    /// sides of a row card.
    public static let cardInset: CGFloat = 16
    /// Minimum height of a row. A row grows with its text, never below this.
    public static let rowMinHeight: CGFloat = 44
    /// Gap between a row's leading symbol and its text.
    public static let rowGap: CGFloat = 12
    /// Vertical room between two rows of a card.
    public static let rowSpacing: CGFloat = 16
    /// Distance from one single-line row to the next. Rows in a card and rows
    /// in a list or form stand on this one grid.
    public static let rowPitch: CGFloat = rowMinHeight + rowSpacing
    /// Room above the first and below the last row of a row card: half a row
    /// spacing, so n single-line rows measure n row pitches, in a card as in
    /// a list section.
    public static let rowCardInsetVertical: CGFloat = rowSpacing / 2
    /// Height of a full-width button.
    public static let buttonHeight: CGFloat = 48
    /// Height of the onboarding button, the one sanctioned exception.
    public static let onboardingButtonHeight: CGFloat = 56
    /// Gap between the two buttons of a pair, side by side and stacked.
    public static let buttonGap: CGFloat = 8
    /// Side length of an icon button, visible circle and hit area alike.
    public static let iconButton: CGFloat = 44
    /// Base side length of a row's symbol chip. Scaled with the text next to
    /// it by ``HLSettingsIconChip``.
    public static let rowIcon: CGFloat = 26
    /// Base point size of the glyph inside the row's symbol chip.
    public static let rowIconGlyph: CGFloat = 13
    /// Visible height of a selectable chip. Its hit area is ``iconButton``.
    public static let chipHeight: CGFloat = 32

    /// Page insets as one value, for scaffolds that take `EdgeInsets`.
    public static let pageInsets = EdgeInsets(
        top: pageTop,
        leading: pageMargin,
        bottom: pageBottom,
        trailing: pageMargin
    )
}
