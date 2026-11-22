import SwiftUI

/// **The one (i) per screen.**
///
/// Sits once in the screen's header or toolbar and opens ``HLInfoSheet`` with
/// everything the cards do not say themselves (the 1.4 design
/// notes). It only reveals information and never navigates
/// elsewhere (HIG, Lists and tables). Inside a sheet's own stack
/// (``SwiftUI/View/hlSheetStack()``) it pushes the page instead of stacking a
/// second sheet. Content with nothing to say renders no button at all.
struct HLInfoButton: View {
    enum Style {
        /// A plain toolbar item; the toolbar supplies the 44 pt target.
        case toolbar
        /// The glass circle of the in-content Insights headers, 44 pt.
        case circle
    }

    let content: HLInfoContent
    var style: Style = .toolbar
    let accessibilityIdentifier: String

    @Environment(\.hlInsideSheetStack) private var insideSheetStack
    @State private var isPresented = false
    @Namespace private var zoom

    var body: some View {
        if !content.isEmpty {
            if insideSheetStack {
                NavigationLink {
                    HLInfoPage(content: content)
                } label: {
                    glyph
                }
                .modifier(InfoButtonTraits(content: content, style: style, identifier: accessibilityIdentifier))
            } else {
                Button {
                    isPresented = true
                } label: {
                    glyph
                }
                .modifier(InfoButtonTraits(content: content, style: style, identifier: accessibilityIdentifier))
                .hlZoomSource(accessibilityIdentifier, in: zoom)
                .sheet(isPresented: $isPresented) {
                    HLInfoSheet(content: content)
                        .hlZoomTransition(from: accessibilityIdentifier, in: zoom)
                }
            }
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch style {
        case .toolbar:
            Image(systemName: "info.circle")
        case .circle:
            Image(systemName: "info.circle")
                .hlHeaderCircle()
        }
    }
}

/// Label and identifier of the (i), the same on both presentation paths.
private struct InfoButtonTraits: ViewModifier {
    let content: HLInfoContent
    let style: HLInfoButton.Style
    let identifier: String

    func body(content view: Content) -> some View {
        Group {
            switch style {
            // The toolbar draws its own item chrome.
            case .toolbar: view
            case .circle: view.buttonStyle(.plain)
            }
        }
        .accessibilityLabel(Text("info.button.a11y \(content.title)"))
        .accessibilityIdentifier(identifier)
    }
}

extension View {
    /// The glass circle of a page header's actions (gear, coach, info): the
    /// size and the treatment of ``HLIconButton`` in the `.bar` style, so the
    /// circles of one header stay equal at every text size.
    func hlHeaderCircle() -> some View {
        modifier(HLHeaderCircle())
    }
}

private struct HLHeaderCircle: ViewModifier {
    @ScaledMetric(relativeTo: .title3) private var scaledSide: CGFloat = HLLayout.iconButton
    /// In a tab header's action group the group is the glass.
    @Environment(\.hlInHeaderActionGroup) private var inGroup

    func body(content: Content) -> some View {
        let side = HLIconButton.side(forScaled: scaledSide)
        let sized = content
            .font(.hlTitle3)
            .foregroundStyle(HLText.secondary)
            // The symbol stops growing where the circle does, as in the icon button.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .frame(width: side, height: side)
        Group {
            if inGroup {
                sized
            } else {
                sized.hlGlassEffect(in: Circle(), interactive: true, fallback: HLColor.backgroundEleva)
            }
        }
        .contentShape(Circle())
    }
}
