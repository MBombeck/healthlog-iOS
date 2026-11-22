import SwiftUI

/// The title of a page that is a sidebar tab in a regular window and a page
/// pushed onto More everywhere else (Labs, Documents, Measurements and the
/// other sections).
///
/// As a tab root the page heads itself like every bar tab: ``HLTabHeader`` in
/// the content, warm, on the page margin and the reading column, and no title
/// in the bar. Pushed, the system's inline title stays, as on every subpage,
/// and the header is not built. The system title is kept in both forms, so
/// the back button of a page pushed from the section still names it.
struct SectionRootHeader: View {
    private let title: LocalizedStringResource
    private let subtitle: LocalizedStringKey?
    private let inList: Bool

    @Environment(\.hlIsTabRoot) private var isTabRoot

    /// `inList` sets the header as the first row of a `List`.
    init(_ title: LocalizedStringResource, subtitle: LocalizedStringKey? = nil, inList: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.inList = inList
    }

    var body: some View {
        if isTabRoot {
            if inList {
                HLTabHeader(title, subtitle: subtitle)
                    .hlTabHeaderListRow()
            } else {
                HLTabHeader(title, subtitle: subtitle)
            }
        }
    }
}

extension View {
    /// The bar's half of a section root's title: the inline system title,
    /// taken out of the bar where the page heads itself with
    /// ``SectionRootHeader``. `headsItself` is `false` for a state that has
    /// no header in its content (an opt-in or a failed load), so the page
    /// never stands without a title.
    func hlSectionRootTitle(_ title: Text, headsItself: Bool = true) -> some View {
        modifier(SectionRootTitleModifier(title: title, headsItself: headsItself))
    }
}

private struct SectionRootTitleModifier: ViewModifier {
    let title: Text
    let headsItself: Bool

    @Environment(\.hlIsTabRoot) private var isTabRoot

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: isTabRoot && headsItself ? .title : nil)
    }
}

extension HLLoadPhase {
    /// The failed state, whose rows the list container builds itself, so a
    /// section root's header is not among them.
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
