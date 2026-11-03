import SwiftUI

/// **1.4 B2 — what the notification screens' (i) explains.**
///
/// The Focus filter used to be a card of text between the settings, and the
/// webhook formats a paragraph under their picker; the advanced diagnostics
/// explained two of their numbers in card footers. The cards now hold the
/// controls, and the explanations stand here, one section each.
extension NotificationsScreen {
    var info: HLInfoContent {
        var sections = [
            HLInfoContent.Section(
                title: String(localized: "focus.filter.card.title"),
                paragraphs: [
                    String(localized: "focus.filter.card.body"),
                    String(localized: "focus.filter.card.footer")
                ]
            )
        ]
        // The webhook card renders whenever the channel services are loaded.
        if servicesStore != nil {
            sections.append(HLInfoContent.Section(
                title: String(localized: "notifications.webhook.title"),
                paragraphs: [
                    String(localized: "notifications.webhook.format.generic.footer"),
                    String(localized: "notifications.webhook.format.gotify.footer")
                ]
            ))
        }
        return HLInfoContent(
            title: String(localized: "Notifications"),
            identifier: "notifications.info.sheet",
            sections: sections
        )
    }
}

enum NotificationDiagnosticsInfo {
    static var content: HLInfoContent {
        HLInfoContent(
            title: String(localized: "Advanced diagnostics"),
            identifier: "notifications.diagnostics.info.sheet",
            sections: [
                HLInfoContent.Section(
                    title: String(localized: "Medication data"),
                    paragraphs: [String(
                        localized: "Doses the server has already created for today. The app fills in the remaining ones from your schedule."
                    )]
                ),
                HLInfoContent.Section(
                    title: String(localized: "Scheduled notifications"),
                    paragraphs: [String(
                        localized: "Local reminders iOS has already scheduled. Server pushes do not appear here."
                    )]
                )
            ]
        )
    }
}
