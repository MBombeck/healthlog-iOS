import SwiftUI

extension NotificationsScreen {
    /// #126 3.3 (server v1.42.2) — what a notification may show. Off
    /// (`generic`, the server default) names what it is about with no health
    /// figure; on (`detailed`) adds figures, such as the score in the morning
    /// briefing's title. Shown only when the server sends `content`.
    @ViewBuilder
    var notificationContentCard: some View {
        if let detailed = store?.notificationContentDetailed {
            // 1.4 B2 — what the switch does sits under its title; no footer.
            HLSettingsCard(icon: "text.bubble", title: "notifications.content.title") {
                HLSettingsToggleRow(
                    title: "notifications.content.toggle",
                    description: "notifications.content.footer",
                    isOn: Binding(
                        get: { detailed },
                        set: { newValue in Task { await store?.setNotificationContentDetailed(newValue) } }
                    ),
                    accessibilityID: "NotificationsScreen.contentDetailToggle"
                )
            }
        }
    }
}
