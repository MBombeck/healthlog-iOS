import Foundation

/// A document page the documents screen pushes. A value resolved at the
/// screen's root, so the page stays when the row or the pane that opened it
/// goes away with a change of width. Carries the list snapshot the page
/// paints first.
struct DocumentRoute: Hashable {
    let document: InboundDocument
}
