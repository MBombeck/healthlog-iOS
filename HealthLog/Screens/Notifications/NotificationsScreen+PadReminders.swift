import SwiftUI

extension NotificationsScreen {
    /// **Who reminds when an iPad and an iPhone share the account.**
    ///
    /// Shown only on an iPad while another iPhone of the account is active
    /// (``ReminderDevicePolicy``): that iPhone plans the reminders, and the iPad
    /// stays quiet so no dose is announced twice. The switch is the user's
    /// additive choice to have the iPad plan its own reminders too; it is local
    /// to this iPad and off by default.
    @ViewBuilder
    var padReminderCard: some View {
        if let planning = container?.reminderPlanning, planning.isPad, planning.otherPhoneIsActive {
            @Bindable var planning = planning
            HLCard(
                LocalizedStringKey("notif.padReminders.title"),
                footer: LocalizedStringKey("notif.padReminders.footer")
            ) {
                Text(planning.alsoOnThisDevice ? "notif.padReminders.bodyOn" : "notif.padReminders.body")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HLSettingsToggleRow(
                    title: "notif.padReminders.toggle",
                    description: nil,
                    isOn: $planning.alsoOnThisDevice,
                    accessibilityID: "NotificationsScreen.alsoRemindOnPadToggle"
                )
            }
        }
    }
}
