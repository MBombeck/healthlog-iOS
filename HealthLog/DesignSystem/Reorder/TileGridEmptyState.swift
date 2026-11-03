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
/// 1.4 B4 — the canonical ``HLEmptyState`` lockup on the page, no longer in
/// an `HLCard`: title and the one `.secondary` action. The sentence that said
/// "you've hidden every tile, add some back" repeated both. Monochrome
/// chrome — the glyph + CTA read as a calm waiting state, not an alarm.
struct TileGridEmptyState: View {
    /// Opens the add/customise path (edit mode + add-tile sheet).
    let onAddTiles: () -> Void

    var body: some View {
        HLEmptyState(
            icon: "square.grid.2x2",
            title: "No tiles shown"
        ) {
            HLButton(
                String(localized: "Add tiles"),
                icon: "plus",
                variant: .secondary,
                action: onAddTiles
            )
        }
        .accessibilityIdentifier("tileGrid.emptyState")
    }
}
