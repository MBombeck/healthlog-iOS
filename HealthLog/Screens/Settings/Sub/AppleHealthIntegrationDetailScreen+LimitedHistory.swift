import SwiftUI

extension AppleHealthIntegrationDetailScreen {
    /// **1.4 / iOS 27 — limited Health history.** One calm line in the
    /// connection card, only while the person lets HealthLog read a recent
    /// window instead of the whole history. It says from when Apple Health
    /// shares data and that nothing already in HealthLog goes away. Same row as
    /// the write-back notice; no badge, nothing on any other screen.
    @ViewBuilder
    var limitedHistoryRow: some View {
        if let start = hkReadiness.limitedHistoryStart {
            noticeRow(
                "settings.applehealth.limitedHistory \(start.formatted(.dateTime.day().month(.wide).year()))",
                icon: "clock.arrow.circlepath"
            )
            .accessibilityIdentifier("settings.integrations.appleHealth.limitedHistory")
        }
    }
}
