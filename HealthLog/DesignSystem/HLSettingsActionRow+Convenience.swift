import SwiftUI

// Moved out of `HLSettingsRow.swift` (SET-ROUTE) to keep that file under the
// 600-line `file_length` budget after the push-by-value initializer. Pure move.

public extension HLSettingsActionRow where Trailing == EmptyView {
    /// Convenience — Push-Zeile ohne zusätzliches Trailing-Beiwerk.
    init(
        icon: String? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        role: Role = .standard,
        labelTintOverride: Color? = nil,
        presents: Push,
        @ViewBuilder destination: () -> Destination
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            role: role,
            labelTintOverride: labelTintOverride,
            presents: presents,
            trailing: { EmptyView() },
            destination: destination
        )
    }

    /// Convenience — Aktions-Zeile ohne zusätzliches Trailing-Beiwerk.
    init(
        icon: String? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        role: Role = .standard,
        labelTintOverride: Color? = nil,
        presents: Presents,
        action: @escaping () -> Void
    ) where Destination == EmptyView {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            role: role,
            labelTintOverride: labelTintOverride,
            presents: presents,
            trailing: { EmptyView() },
            action: action
        )
    }
}
