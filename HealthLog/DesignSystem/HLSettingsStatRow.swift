import SwiftUI

// Moved out of HLSettingsRow.swift unchanged (POLISH-C), which reached its
// 600-line budget.

// MARK: - Stat row

/// **1.4 B4 — one label and its value.** At the standard sizes the value sits
/// trailing and wraps in full; at an accessibility size it moves under its
/// label, so neither is squeezed into a column of syllables ("Bundle / -ID",
/// "de-v.health-log.app"). The sync diagnostics, its server view and About
/// share it; a value never stops after a few lines ("47 nicht…").
struct HLSettingsStatRow: View {
    let label: Text
    let value: String
    let tint: Color
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(label: Text, value: String, tint: Color = HLText.secondary) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                labelText
                valueText(alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .firstTextBaseline) {
                labelText
                Spacer(minLength: HLSpace.md)
                valueText(alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var labelText: some View {
        label
            .font(.hlSubhead)
            .foregroundStyle(HLText.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func valueText(alignment: TextAlignment) -> some View {
        Text(verbatim: value)
            .font(.hlBody.monospacedDigit())
            .foregroundStyle(tint)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}
