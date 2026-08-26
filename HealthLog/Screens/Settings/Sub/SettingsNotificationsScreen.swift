import SwiftUI

/// `/settings/notifications` — Benachrichtigungen. Thin wrapper around the
/// existing `NotificationsScreen` so it lands under the new Settings hub.
///
/// The existing `NotificationsScreen` is feature-rich and uses its own
/// `List`-based IA tuned for the current shape. PA2 §10 will eventually
/// re-skin it onto `HLSettingsCard` for full web-parity (per-channel
/// reliability card; ntfy / telegram / web-push cards). For PB3 we route
/// to the existing screen so functionality is preserved.
struct SettingsNotificationsScreen: View {
    var body: some View {
        NotificationsScreen()
    }
}
