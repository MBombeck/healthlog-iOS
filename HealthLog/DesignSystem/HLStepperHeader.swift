import SwiftUI

/// Back and forth through days, nights, weeks or months: the title in the
/// middle, a chevron on each side.
///
/// The day pulse, the sleep night, the movement week and the cycle calendar
/// share it, so the chevrons stand at the same place, in the same size and
/// ink everywhere (``HLIconButton``, 44 pt). A side that cannot go further is
/// disabled, never removed, so the title does not jump.
struct HLStepperHeader: View {
    /// The two directions, for tests and identifiers.
    enum Direction: Equatable, Sendable {
        case previous
        case next

        var systemImage: String {
            switch self {
            case .previous: "chevron.left"
            case .next: "chevron.right"
            }
        }
    }

    private let title: Text
    /// The title as words, when it is known as a string: it then wraps
    /// between words only ("Dienstag, 12. / November").
    private var titleWords: String?
    private let subtitle: Text?
    private let previousLabel: LocalizedStringKey
    private let nextLabel: LocalizedStringKey
    private let canGoPrevious: Bool
    private let canGoNext: Bool
    private let identifier: String?
    private let previous: () -> Void
    private let next: () -> Void

    /// - Parameters:
    ///   - previousLabel, nextLabel: what VoiceOver says for the chevrons
    ///     ("Previous night"); the plain "Previous" and "Next" otherwise.
    ///   - identifier: prefix for the chevrons' identifiers
    ///     (`<identifier>.previous`, `<identifier>.next`).
    init(
        title: Text,
        subtitle: Text? = nil,
        previousLabel: LocalizedStringKey = "hl.stepper.previous",
        nextLabel: LocalizedStringKey = "hl.stepper.next",
        canGoPrevious: Bool = true,
        canGoNext: Bool = true,
        identifier: String? = nil,
        previous: @escaping () -> Void,
        next: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.previousLabel = previousLabel
        self.nextLabel = nextLabel
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
        self.identifier = identifier
        self.previous = previous
        self.next = next
    }

    /// For a title built at run time (a date, a night, a week).
    init(
        verbatim title: String,
        subtitle: Text? = nil,
        previousLabel: LocalizedStringKey = "hl.stepper.previous",
        nextLabel: LocalizedStringKey = "hl.stepper.next",
        canGoPrevious: Bool = true,
        canGoNext: Bool = true,
        identifier: String? = nil,
        previous: @escaping () -> Void,
        next: @escaping () -> Void
    ) {
        self.init(
            title: Text(verbatim: title),
            subtitle: subtitle,
            previousLabel: previousLabel,
            nextLabel: nextLabel,
            canGoPrevious: canGoPrevious,
            canGoNext: canGoNext,
            identifier: identifier,
            previous: previous,
            next: next
        )
        titleWords = title
    }

    var body: some View {
        HStack(alignment: .center, spacing: HLSpace.xs) {
            chevron(.previous)
            VStack(spacing: HLSpace.xxs) {
                titleView
                    .foregroundStyle(HLText.primary)
                if let subtitle {
                    subtitle
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            chevron(.next)
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if let titleWords {
            HLWholeWordText(titleWords, font: .hlHeadline, alignment: .center)
        } else {
            title.font(.hlHeadline)
        }
    }

    private func chevron(_ direction: Direction) -> some View {
        let enabled = direction == .previous ? canGoPrevious : canGoNext
        return HLIconButton(
            systemImage: direction.systemImage,
            label: direction == .previous ? previousLabel : nextLabel,
            action: direction == .previous ? previous : next
        )
        .disabled(!enabled)
        .modifier(HLOptionalIdentifier(identifier: identifier.map { "\($0).\(direction == .previous ? "previous" : "next")" }))
    }
}

#Preview("HLStepperHeader") {
    HLPage {
        HLCard {
            HLStepperHeader(
                title: Text(verbatim: "Dienstag, 12. November"),
                subtitle: Text(verbatim: "Heute"),
                canGoNext: false,
                previous: {},
                next: {}
            )
        }
    }
}
