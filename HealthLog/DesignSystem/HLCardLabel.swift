import SwiftUI

/// A small label inside a card, above the part of the card it names: a
/// kicker, not a section header.
///
/// A label between cards is an ``HLSectionHeader`` of rank `.group`; a label
/// inside a card is this one. `.hlFootnote` semibold in sentence case, like
/// every other header of the app, `HLText.secondary`, marked as a header for
/// VoiceOver, no room of its own.
///
/// A long word in a narrow card needs a second line. The label keeps that
/// line for itself: a line limit set around it does not cut the word off.
struct HLCardLabel: View {
    private let text: Text

    init(_ title: LocalizedStringKey) {
        text = Text(title)
    }

    /// For a label that is already final, such as a category name resolved
    /// at run time.
    init(verbatim title: String) {
        text = Text(verbatim: title)
    }

    var body: some View {
        text
            .font(.hlFootnote.weight(.semibold))
            .foregroundStyle(HLText.secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}
