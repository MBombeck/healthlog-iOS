import SwiftUI

/// A row that is chosen: one form for every choice in the app.
///
/// One of several (an output format, a provider, the ring on the start page,
/// the answer to a questionnaire item) shows a check mark at the trailing
/// edge of the chosen row, the way Settings does. Several of several (the
/// records to share, the documents to delete) show a circle at the leading
/// edge, filled when chosen, as in Mail's and Photos' selection. There is no
/// radio circle on iOS. The whole row takes the tap, gives the press
/// feedback of every row and reports its state to VoiceOver.
struct HLChoiceRow: View {
    enum Mode: Equatable, Sendable {
        /// One of several: check mark at the trailing edge.
        case single
        /// Several of several: circle at the leading edge.
        case multiple
        /// One of several where nothing is chosen until the person answers
        /// (a questionnaire item, the form of a share): an open circle at the
        /// trailing edge of every row, filled on the chosen one. With nothing
        /// chosen a bare check-mark list read as loose text.
        case singleOpen
    }

    /// The sign a row shows, and on which side. `nil` for an unchosen row of
    /// a single choice, which shows nothing.
    nonisolated static func symbol(mode: Mode, isSelected: Bool) -> String? {
        switch (mode, isSelected) {
        case (.single, true): "checkmark"
        case (.single, false): nil
        case (.multiple, true), (.singleOpen, true): "checkmark.circle.fill"
        case (.multiple, false), (.singleOpen, false): "circle"
        }
    }

    nonisolated static func edge(for mode: Mode) -> HorizontalEdge {
        mode == .multiple ? .leading : .trailing
    }

    /// The standard row that never moves its mark under the title.
    static var configuration: HLRowConfiguration {
        var configuration = HLRowConfiguration.standard
        configuration.stacking = .never
        return configuration
    }

    private let title: Text
    private let detail: Text?
    private let symbol: String?
    private let isSelected: Bool
    private let mode: Mode
    private let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        symbol: String? = nil,
        isSelected: Bool,
        mode: Mode = .single,
        action: @escaping () -> Void
    ) {
        self.init(
            title: Text(title),
            detail: detail.map { Text($0) },
            symbol: symbol,
            isSelected: isSelected,
            mode: mode,
            action: action
        )
    }

    /// For titles that exist only at run time (a document's name).
    /// `symbol` gives a row of a single choice its glyph at the leading
    /// edge, so a list whose rows are all unchosen still reads as a list of
    /// choices, not as loose text.
    init(
        title: Text,
        detail: Text? = nil,
        symbol: String? = nil,
        isSelected: Bool,
        mode: Mode = .single,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.isSelected = isSelected
        self.mode = mode
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            // The mark keeps its side at every size: a check mark under the
            // title would read as a second line, not as the choice.
            HLRowLayout(
                title: title,
                subtitle: detail,
                indicator: .hidden,
                configuration: Self.configuration,
                leading: {
                    if Self.edge(for: mode) == .leading {
                        mark
                    } else if let symbol {
                        HLRowGlyph(symbol: symbol)
                    }
                },
                trailing: { if Self.edge(for: mode) == .trailing { mark } }
            )
        }
        .buttonStyle(.hlRow)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    @ViewBuilder
    private var mark: some View {
        if let symbol = Self.symbol(mode: mode, isSelected: isSelected) {
            Image(systemName: symbol)
                .font(mode == .single ? .hlBody.weight(.semibold) : .hlTitle3)
                .foregroundStyle(isSelected ? HLText.primary : HLText.tertiary)
                .accessibilityHidden(true)
        } else {
            // Keeps the title from moving when the mark comes and goes.
            Image(systemName: "checkmark")
                .font(.hlBody.weight(.semibold))
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

#Preview("HLChoiceRow") {
    HLPage {
        HLCard(layout: .rows) {
            HLChoiceRow(title: Text(verbatim: "PDF"), isSelected: true) {}
            HLChoiceRow(title: Text(verbatim: "CSV"), isSelected: false) {}
        }
        HLCard(layout: .rows) {
            HLChoiceRow(title: Text(verbatim: "Blutdruck"), detail: Text(verbatim: "128 Einträge"), isSelected: true, mode: .multiple) {}
            HLChoiceRow(title: Text(verbatim: "Gewicht"), isSelected: false, mode: .multiple) {}
        }
    }
}
