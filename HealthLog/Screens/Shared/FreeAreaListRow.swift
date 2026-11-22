import SwiftUI

extension View {
    /// An empty or failed lockup as the one row of a list: at the reading
    /// width and centred across it, at the top of the free area under the
    /// page's head, where ``HLEmptyState`` stands on every page. No height of
    /// its own: in a list the row is its own container, so a frame relative
    /// to it would cut the lockup.
    func hlFreeAreaListRow() -> some View {
        hlCenteredOnReadableWidth()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
