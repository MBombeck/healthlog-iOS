import SwiftUI

/// **W-B187 (Settings consolidation §A.3) — Apple Health Import, folded in.**
///
/// The one-shot `export.zip` bulk-import entry point used to sit as a separate
/// peer row in `SettingsIntegrationsScreen` ("Apple Health" + "Apple Health
/// Import"), which read as a confusing second Apple-Health provider. It was
/// folded INTO `AppleHealthIntegrationDetailScreen` so the Integrations list
/// shows ONE "Apple Health" row → one detail page that owns every Apple-Health
/// concern (connect / sync / data types / special syncs / import / transparency).
///
/// The destination (`SettingsAppleHealthImportScreen`) is unchanged — only the
/// entry point moved. Server-only: the caller gates the card on
/// `backend.hasServer` (the XML-parse pipeline lives on the server). Split into
/// its own extension file to keep the host type under the body-length budget.
extension AppleHealthIntegrationDetailScreen {
    var importCard: some View {
        // 1.4 B2-c — the "export ZIP" subtitle is gone. 1.4 B4 — one row,
        // one heading: the row names its screen.
        HLSettingsCard {
            HLSettingsActionRow(title: "settings.applehealth_import.hero_title", presents: .push) {
                SettingsAppleHealthImportScreen()
            }
            .accessibilityIdentifier("settings.integrations.appleHealthImportRow")
        }
    }
}
