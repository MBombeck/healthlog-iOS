import SwiftUI

// MARK: - Stat row

/// **One label and its value.** At the standard sizes the value sits
/// trailing and wraps in full; at an accessibility size it moves under its
/// label, so neither is squeezed into a column of syllables ("Bundle / -ID",
/// "de-v.health-log.app"). The sync diagnostics, its server view and About
/// share it; a value never stops after a few lines ("47 nicht…").
///
/// A value that is an identifier (a host, a bundle id, a token) passes
/// `isIdentifier: true`: it then breaks only after its punctuation
/// (``HLIdentifierText``), in the same ink.
struct HLSettingsStatRow: View {
    let label: Text
    let value: String
    let tint: Color
    let isIdentifier: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(label: Text, value: String, tint: Color = HLText.secondary, isIdentifier: Bool = false) {
        self.label = label
        self.value = value
        self.tint = tint
        self.isIdentifier = isIdentifier
    }

    var body: some View {
        HLRowLayout(
            title: label,
            subtitle: nil,
            indicator: .hidden,
            configuration: .stat,
            leading: { EmptyView() },
            trailing: { valueText(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing) }
        )
    }

    @ViewBuilder
    private func valueText(alignment: TextAlignment) -> some View {
        if isIdentifier {
            let identifier = HLIdentifierText(value, style: .subheadline, ink: tint)
            if alignment == .trailing {
                identifier.trailing()
            } else {
                identifier
            }
        } else {
            plainValue(alignment: alignment)
        }
    }

    private func plainValue(alignment: TextAlignment) -> some View {
        Text(verbatim: value)
            .font(HLRowValue.Emphasis.setting.font)
            .monospacedDigit()
            .foregroundStyle(tint)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}
