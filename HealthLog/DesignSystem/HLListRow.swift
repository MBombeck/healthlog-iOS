import SwiftUI

/// A list row from plain strings: symbol, title, subtitle, value. It is the
/// shared row grid with runtime text; new code uses ``HLRow``. It shows a
/// value, so it draws no chevron unless the caller names one.
public struct HLListRow: View {
    private let icon: String?
    /// `nil` means "use the live user accent"
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
        trailingSymbol: String? = nil
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.trailingSymbol = trailingSymbol
    }

    public var body: some View {
        HLRowLayout(
            title: Text(title),
            subtitle: subtitle.map { Text($0) },
            indicator: indicator,
            configuration: .standard,
            leading: {
                if let icon {
                    HLSettingsIconChip(symbol: icon, tint: iconColor ?? HLAccent.userBrandTint)
                }
            },
            trailing: {
                if let value {
                    HLRowValue(value)
                }
            }
        )
    }

    private var indicator: HLRowIndicator {
        guard let trailingSymbol else { return .hidden }
        switch trailingSymbol {
        case "chevron.right": return .disclosure
        // Maps the old external sign of existing callers onto the one sign.
        // swiftlint:disable:next hl_one_external_sign
        case "arrow.up.right.square": return .symbol(HLRowIndicator.externalSymbol)
        default: return .symbol(trailingSymbol)
        }
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
