import SwiftUI

/// The quiet text action: one font (15 semibold), one ink (secondary), a
/// 44 pt tap area, in two places.
///
/// `.center` is the link under a card or at the end of a section ("Advanced",
/// "Show all", "Recently deleted"); with `isExpanded` it shows that it unfolds
/// content beneath it ("Show more" / "Show fewer"). `.leading` is a quiet
/// action inside a card ("Confirm", "Ask the coach", "Manage tags"). A symbol
/// stands before the words, an onward chevron after them. Accent and warning
/// colours are not link colours; a reference inside running text is
/// ``HLTextLink``.
public struct HLLinkButton: View {
    /// Where the link stands in its row.
    public enum Alignment: Equatable, Sendable {
        /// Centred under a card or at the end of a section.
        case center
        /// At the leading edge of a card, as a quiet action.
        case leading
    }

    /// Height of the tap area. The visible part is one line of text.
    public static let hitHeight: CGFloat = HLHitTarget.minimum

    /// The frame alignment and the text alignment of a placement.
    public nonisolated static func frameAlignment(for alignment: Alignment) -> SwiftUI.Alignment {
        alignment == .center ? .center : .leading
    }

    public nonisolated static func textAlignment(for alignment: Alignment) -> TextAlignment {
        alignment == .center ? .center : .leading
    }

    private let title: Text
    private let systemImage: String?
    private let alignment: Alignment
    private let isExpanded: Bool?
    private let action: () -> Void
    /// Push form: the link is the `NavigationLink` itself. `nil` for the
    /// action form.
    private let destination: AnyView?

    /// Whether this link pushes a page instead of running an action.
    public var pushesDestination: Bool {
        destination != nil
    }

    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        alignment: Alignment = .center,
        isExpanded: Bool? = nil,
        action: @escaping () -> Void
    ) {
        self.init(title: Text(title), systemImage: systemImage, alignment: alignment, isExpanded: isExpanded, action: action)
    }

    /// For words that exist only at run time ("Recently deleted (3)").
    public init(
        _ title: Text,
        systemImage: String? = nil,
        alignment: Alignment = .center,
        isExpanded: Bool? = nil,
        action: @escaping () -> Void
    ) {
        self.init(title: title, systemImage: systemImage, alignment: alignment, isExpanded: isExpanded, action: action)
    }

    private init(
        title: Text,
        systemImage: String?,
        alignment: Alignment,
        isExpanded: Bool?,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.alignment = alignment
        self.isExpanded = isExpanded
        self.action = action
        destination = nil
    }

    /// The link as a push ("Show all"): it puts `destination` onto the
    /// enclosing stack, so the card above it keeps no presenter for it. Name
    /// the closure: an unnamed one after the call reads as an action.
    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        alignment: Alignment = .center,
        destination: () -> some View
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.alignment = alignment
        isExpanded = nil
        action = {}
        self.destination = AnyView(destination())
    }

    public var body: some View {
        if let destination {
            NavigationLink { destination } label: { label }
                .buttonStyle(.plain)
        } else {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .modifier(HLExpansionValue(isExpanded: isExpanded))
        }
    }

    private var label: some View {
        HStack(spacing: HLSpace.xs) {
            if let systemImage, !HLButtonLabel.iconFollowsTitle(systemImage) {
                Image(systemName: systemImage)
                    .font(.hlFootnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            title
                .font(.hlSubhead.weight(.semibold))
                .multilineTextAlignment(Self.textAlignment(for: alignment))
                .fixedSize(horizontal: false, vertical: true)
            if let systemImage, HLButtonLabel.iconFollowsTitle(systemImage) {
                Image(systemName: systemImage)
                    .font(.hlFootnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            if let isExpanded {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.hlFootnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(HLText.secondary)
        .frame(maxWidth: .infinity, minHeight: Self.hitHeight, alignment: Self.frameAlignment(for: alignment))
        .contentShape(Rectangle())
    }
}

/// Tells VoiceOver whether a link's content is unfolded. A plain link carries
/// no value.
private struct HLExpansionValue: ViewModifier {
    let isExpanded: Bool?

    func body(content: Content) -> some View {
        if let isExpanded {
            content.accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
        } else {
            content
        }
    }
}

#Preview("HLLinkButton, light") {
    HLLinkButtonPreview()
        .preferredColorScheme(.light)
}

#Preview("HLLinkButton, dark") {
    HLLinkButtonPreview()
        .preferredColorScheme(.dark)
}

#Preview("HLLinkButton, largest type") {
    HLLinkButtonPreview()
        .dynamicTypeSize(.accessibility5)
}

private struct HLLinkButtonPreview: View {
    @State private var isExpanded = false

    var body: some View {
        HLPage {
            HLCard("Overview", layout: .rows) {
                HLRowLayout(title: "Blood pressure", indicator: .disclosure)
            }
            HLLinkButton("Advanced", isExpanded: isExpanded) { isExpanded.toggle() }
            HLLinkButton(HLControlWord.edit.key) {}
            HLCard {
                HLLinkButton("Ask the coach", systemImage: "sparkles", alignment: .leading) {}
            }
        }
    }
}
