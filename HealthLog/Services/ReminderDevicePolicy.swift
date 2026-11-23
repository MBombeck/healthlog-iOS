import Foundation

/// **Which device plans the local reminders.**
///
/// The app plans reminders locally (medications through SpeziScheduler,
/// critical ones through AlarmKit, the evening mood nudge, supply alerts) and
/// tells the server so with `notificationPrefs.medication.clientManaged`; that
/// flag is account-wide and silences the APNs leg for every device. Two devices
/// that both plan would announce every dose twice; a device that plans nothing
/// while the server is quiet would hear nothing. One rule keeps both from
/// happening.
///
/// - The iPhone and the Duo (`.phone`) behave as they always did: they plan.
/// - The iPad plans only when no *other* iPhone of the account is active. Active
///   means a device labelled "iPhone" last seen less than seven days ago. Seven
///   and not fourteen: an iPad that wrongly takes over only doubles a reminder,
///   an iPad that wrongly waits delivers none.
/// - The iPad can be told to plan anyway (`override`, "Auch auf diesem iPad
///   erinnern"). That is additive and the user's explicit choice.
/// - A failed device query (`devices == nil`) means the iPad plans: better twice
///   than not at all.
///
/// Pure, with the idiom and the clock injected.
public enum ReminderDevicePolicy {
    /// An iPhone not seen for this long no longer counts as the one that reminds.
    public static let activePhoneWindow: TimeInterval = 7 * 24 * 60 * 60

    public static func plansLocally(
        idiom: DeviceIdiom,
        devices: [ReminderDevice]?,
        override: Bool,
        now: Date
    ) -> Bool {
        guard idiom == .pad else { return true }
        if override { return true }
        guard let devices else { return true }
        return !hasActivePhone(devices, now: now)
    }

    /// Whether another iPhone of the account was seen inside the window.
    public static func hasActivePhone(_ devices: [ReminderDevice], now: Date) -> Bool {
        devices.contains { device in
            !device.isCurrent
                && device.label.lowercased().hasPrefix("iphone")
                && now.timeIntervalSince(device.lastSeenAt) < activePhoneWindow
        }
    }
}
