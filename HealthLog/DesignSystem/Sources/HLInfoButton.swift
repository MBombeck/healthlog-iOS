import SwiftUI

/// **1.4 B2 — the one (i) per screen.**
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
                .sheet(isPresented: $isPresented) {
                    HLInfoSheet(content: content)
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
    /// The 44 pt glass circle of the Insights header actions (gear, coach,
    /// info): one diameter and one treatment, so the circles cannot drift.
    func hlHeaderCircle() -> some View {
        font(.hlTitle3)
            .foregroundStyle(HLText.secondary)
            .frame(width: 44, height: 44)
            .hlGlassEffect(in: Circle(), interactive: true, fallback: HLColor.backgroundEleva)
            .contentShape(Circle())
    }
}
