import SwiftUI
import UIKit

/// An identifier the reader may copy or type off the screen: a server
/// address, an endpoint, a token, a domain.
///
/// Running text breaks a long word into syllables with a hyphen, and a hyphen
/// in "uitest.herme-tic.local" is a character the reader then types. This
/// text never hyphenates. It breaks after `/`, `.`, `_` and `-`, and inside a
/// part only when the part alone is wider than the line. The text is
/// selectable, and a copy carries the identifier exactly as it is, without
/// the invisible break marks.
///
/// SwiftUI's `Text` has no switch for hyphenation, so the block draws a
/// read-only `UITextView` whose paragraph style turns it off.
struct HLIdentifierText: View {
    let identifier: String
    var style: UIFont.TextStyle = .subheadline
    var monospaced = false
    var alignment: NSTextAlignment = .natural
    /// The ink: primary where the identifier is the content, secondary or
    /// tertiary where it is the value of a row or a footnote.
    var ink: Color = HLText.primary

    init(
        _ identifier: String,
        style: UIFont.TextStyle = .subheadline,
        monospaced: Bool = false,
        ink: Color = HLText.primary
    ) {
        self.ink = ink
        self.identifier = identifier
        self.style = style
        self.monospaced = monospaced
    }

    /// The characters after which the identifier may break.
    nonisolated static let breakAfter: Set<Character> = ["/", ".", "_", "-", "?", "&", "=", ":", "@"]

    /// The invisible mark that allows a break and takes no room.
    nonisolated static let breakMark: Character = "\u{200B}"

    /// The identifier with a break mark after every separator. A separator at
    /// the very end gets none.
    nonisolated static func breakable(_ identifier: String) -> String {
        var result = ""
        result.reserveCapacity(identifier.count * 2)
        for (index, character) in zip(identifier.indices, identifier) {
            result.append(character)
            if breakAfter.contains(character), identifier.index(after: index) != identifier.endIndex {
                result.append(breakMark)
            }
        }
        return result
    }

    /// What a copy puts on the clipboard: the identifier without break marks.
    nonisolated static func copied(_ shown: String) -> String {
        shown.replacingOccurrences(of: String(breakMark), with: "")
    }

    /// The paragraph style of every identifier: no hyphen, ever.
    nonisolated static func paragraphStyle(alignment: NSTextAlignment) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.hyphenationFactor = 0
        paragraph.usesDefaultHyphenation = false
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = []
        paragraph.alignment = alignment
        return paragraph
    }

    var body: some View {
        HLIdentifierTextView(
            identifier: identifier,
            style: style,
            monospaced: monospaced,
            alignment: alignment,
            ink: ink
        )
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: identifier))
        .accessibilityAddTraits(.isStaticText)
    }
}

extension HLIdentifierText {
    /// Right-aligned, for the value side of a row.
    func trailing() -> HLIdentifierText {
        var copy = self
        copy.alignment = .right
        return copy
    }
}

/// The text view behind ``HLIdentifierText``.
private struct HLIdentifierTextView: UIViewRepresentable {
    let identifier: String
    let style: UIFont.TextStyle
    let monospaced: Bool
    let alignment: NSTextAlignment
    let ink: Color

    func makeUIView(context _: Context) -> HLIdentifierUITextView {
        let view = HLIdentifierUITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return view
    }

    func updateUIView(_ view: HLIdentifierUITextView, context: Context) {
        let traits = UITraitCollection(
            preferredContentSizeCategory: UIContentSizeCategory(context.environment.dynamicTypeSize)
        )
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        let font = monospaced
            ? UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
            : base
        view.attributedText = NSAttributedString(
            string: HLIdentifierText.breakable(identifier),
            attributes: [
                .font: font,
                .foregroundColor: UIColor(ink),
                .paragraphStyle: HLIdentifierText.paragraphStyle(alignment: alignment)
            ]
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HLIdentifierUITextView, context _: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let fittedWidth = ceil(fitted.width)
        return CGSize(width: proposal.width.map { min($0, fittedWidth) } ?? fittedWidth, height: ceil(fitted.height))
    }
}

/// Copies the identifier without the break marks it is shown with.
private final class HLIdentifierUITextView: UITextView {
    override func copy(_ sender: Any?) {
        guard let range = selectedTextRange, let selected = text(in: range) else {
            super.copy(sender)
            return
        }
        UIPasteboard.general.string = HLIdentifierText.copied(selected)
    }
}

#Preview("HLIdentifierText") {
    HLPage {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLIdentifierText("https://uitest.hermetic.local/mcp")
                HLIdentifierText("hlk_sweep_example_token", style: .footnote, monospaced: true)
            }
        }
    }
    .dynamicTypeSize(.accessibility3)
}
