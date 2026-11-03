import SwiftUI

/// **1.4 B2-c — the one icon-and-sentence row.**
///
/// Settings cards and consent sheets list short statements, each led by a
/// small symbol: what an import does with the file, what an AI provider
/// receives, the About disclaimer. Nine private helpers built that row with
/// three icon widths (18, 20 and 24 pt), three text sizes and two tints, so the
/// left text edge moved from card to card (R2 1.9). This is the row they share:
/// one icon column, one text style, top-aligned so a wrapped sentence stays
/// beside its symbol.
struct HLIconTextRow: View {
    /// 1.4 B4 — the one icon column of every info row at the standard text
    /// size. Rows that are not an `HLIconTextRow` (a stat with an icon, a
    /// ranked source, an info-sheet link) take it through
    /// `.hlInfoIconColumn()`, so the text edge is the same everywhere.
    static let iconColumnWidth: CGFloat = 20

    private let icon: String
    private let text: Text

    init(icon: String, _ key: LocalizedStringKey) {
        self.icon = icon
        text = Text(key)
    }

    /// Text that is already localized (a sentence built with an interpolated
    /// provider name, for instance).
    init(icon: String, verbatim: String) {
        self.icon = icon
        text = Text(verbatim: verbatim)
    }

    var body: some View {
        HStack(alignment: .top, spacing: HLSpace.md) {
            Image(systemName: icon)
                .font(.hlIcon(HLIconSize.md))
                .foregroundStyle(HLText.secondary)
                .hlInfoIconColumn()
                .accessibilityHidden(true)
            text
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// 1.4 B4 — the info rows' one icon column, `HLIconTextRow.iconColumnWidth`.
    /// The glyph in it is an `.hlIcon` size (pixel-locked like every symbol
    /// in the app), so the column does not grow with the text either: at the
    /// accessibility sizes the sentence keeps the width.
    func hlInfoIconColumn(alignment: Alignment = .center) -> some View {
        frame(width: HLIconTextRow.iconColumnWidth, alignment: alignment)
    }
}
