import SwiftUI

/// v0.8.2 W1a (B1) — escape-hatch card shown when every tile in a reorderable
/// grid is hidden, so the visible grid would render nothing.
///
/// Long-press-to-edit only fires on a tile; with zero tiles there is nothing to
/// long-press, so the operator would otherwise be trapped — the in-edit "+"
/// add-sheet (the only in-context way back to the tiles) lives behind edit mode
/// they can no longer enter. This card breaks the trap with an explicit
/// "Add tiles" CTA that opens the add/customise path directly.
///
/// Hosted inside `HLCard` (via the canonical ``HLEmptyState`` lockup) so it
/// sits in the same scroll rhythm as the surrounding dashboard / insights
/// cards. Monochrome chrome — the glyph + CTA read as a calm waiting state,
/// not an alarm.
struct TileGridEmptyState: View {
    /// Opens the add/customise path (edit mode + add-tile sheet).
    let onAddTiles: () -> Void

    var body: some View {
        HLCard {
            HLEmptyState(
                icon: "square.grid.2x2",
                title: "No tiles shown",
                message: "You've hidden every tile. Add some back to see your metrics at a glance."
            ) {
                HLButton(
                    String(localized: "Add tiles"),
                    icon: "plus",
                    variant: .primary,
                    size: .regular,
                    action: onAddTiles
                )
            }
            .accessibilityIdentifier("tileGrid.emptyState")
        }
    }
}
