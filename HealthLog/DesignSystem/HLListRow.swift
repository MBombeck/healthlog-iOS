import SwiftUI

public struct HLListRow: View {
    private let icon: String?
    /// v0.5.2-A8 / v0.8.0-W6: `nil` means "use the live user accent"
    /// (`HLAccent.userBrandTint`, resolved at body-eval from
    /// `SettingsStore.preferredTint`). The prior `.accentColor` default read
    /// the *asset-catalog* AccentColor, not the live tint, so it could
    /// disagree with the rest of the app. A non-nil override paints a literal
    /// colour and is reserved for the rare brand-anchor row.
    private let iconColor: Color?
    private let title: String
    private let subtitle: String?
    private let value: String?
    private let trailingSymbol: String?

    public init(
        icon: String? = nil,
        iconColor: Color? = nil,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        trailingSymbol: String? = "chevron.right"
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.trailingSymbol = trailingSymbol
    }

    public var body: some View {
        HStack(spacing: HLSpace.md) {
            if let icon {
                IconChip(name: icon, color: iconColor ?? HLAccent.userBrandTint)
            }
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(title)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: HLSpace.sm)
            if let value {
                Text(value)
                    .font(.hlMetric(.body))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
            }
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.tertiary)
            }
        }
        .padding(.vertical, HLSpace.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct IconChip: View {
    let name: String
    let color: Color

    var body: some View {
        // Intentional fixed size:
        // Icon sits inside a fixed 32×32 chip; size locked to match chip frame.
        Image(systemName: name)
            // swiftlint:disable:next dynamic_type_bypass
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
    }
}

#Preview("HLListRow") {
    VStack(spacing: 0) {
        HLListRow(icon: "scalemass", title: "Gewicht", subtitle: "Heute Morgen", value: "72,4 kg")
        Divider().background(HLColor.separator)
        HLListRow(icon: "waveform.path.ecg", title: "Blutdruck", subtitle: "vor 12 Min", value: "126/82")
        Divider().background(HLColor.separator)
        HLListRow(icon: "pills.fill", title: "Lisinopril", subtitle: "Gleich um 20:00")
    }
    .padding()
    .background(HLSurface.primary)
}
