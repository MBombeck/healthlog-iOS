import SwiftUI

/// The document beside the list: its name and facts as the column's head,
/// the preview as large as the pane allows, and the way to the full page
/// (summary, values, details).
///
/// The page is the same one a tap pushes where the list stands alone; the
/// pane is part of the documents screen, not a second navigation stack.
struct DocumentPane: View {
    let store: DocumentsStore
    let document: InboundDocument

    var body: some View {
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            header
            DocumentPreviewView(store: store, document: document, fillsHeight: true)
            HLCard(layout: .rows) {
                HLRow("documents.pane.open", accessory: .chevron)
                    .hlRowLink(value: DocumentRoute(document: document))
                    .accessibilityIdentifier("documents.pane.open")
            }
        }
        .padding(HLLayout.pageInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(HLSurface.primary)
    }

    /// The document's name and facts as the column's head: the pane is a
    /// part of the documents screen, so its name is a column header, as
    /// beside the labs table.
    private var header: some View {
        let said = DocumentRowContent(document: document, isProcessing: DocumentFormat.isProcessing(document), isReady: false)
        return HLColumnHeader(verbatim: said.title, subtitle: said.detail, titleIdentifier: "documents.pane.title")
    }
}

/// The pane's stand-in while no document is selected, or the selected one is
/// gone from the list.
struct DocumentPanePlaceholder: View {
    var body: some View {
        HLEmptyState(
            icon: "doc.text.magnifyingglass",
            title: "documents.pane.empty.title",
            message: "documents.pane.empty.message"
        )
        .hlCenteredOnReadableWidth()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(HLSurface.primary)
    }
}
