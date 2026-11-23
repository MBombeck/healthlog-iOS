import SwiftUI

/// Missing data inside a card: one quiet line where the content would be.
///
/// A whole page or a whole section without data takes ``HLEmptyState``.
/// Inside a card that already has a head, the lockup would be a box around
/// nothing; this line says the same in the card's own body text.
public struct HLEmptyNote: View {
    /// Font of the note.
    public static let font: Font = .hlSubhead

    private let text: Text
    private let alignment: HLEmptyNoteAlignment

    /// `.center` where the line stands alone in a sheet or under a chart,
    /// with no card head to line up with.
    public init(_ text: LocalizedStringKey, alignment: HLEmptyNoteAlignment = .leading) {
        self.text = Text(text)
        self.alignment = alignment
    }

    /// For a note that is already a text (formatted or pre-localized).
    public init(_ text: Text, alignment: HLEmptyNoteAlignment = .leading) {
        self.text = text
        self.alignment = alignment
    }

    /// For specimen text that is not a catalogue key.
    public init(verbatim text: String) {
        self.text = Text(verbatim: text)
        alignment = .leading
    }

    public var body: some View {
        text
            .font(Self.font)
            .foregroundStyle(HLText.secondary)
            .multilineTextAlignment(alignment.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment.frame)
    }
}

/// Where an ``HLEmptyNote`` stands across its width.
public enum HLEmptyNoteAlignment: Sendable, CaseIterable {
    /// At the leading edge, under a card head.
    case leading
    /// Centred, alone in a sheet or a free area.
    case center

    public var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        }
    }

    public var frame: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        }
    }
}

#Preview("HLEmptyNote") {
    HLPage {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLCardLabel(verbatim: "Verlauf")
                HLEmptyNote(verbatim: "Noch keine Einnahmen erfasst.")
            }
        }
    }
}
