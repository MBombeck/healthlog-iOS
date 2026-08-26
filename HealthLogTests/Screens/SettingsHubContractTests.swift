import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// Locks the v0.5.0+ PB3 Settings-hub contract per PA2 §Recommended Pattern,
/// trimmed in fix/v05x-pb3-baustelle per operator AC18 ("Ich moechte keine
/// Fake-Sachen haben"):
///
/// - the hub MUST route only to sub-screens whose body contains working
///   content end-to-end — placeholder-only screens are forbidden
/// - each sub-screen MUST be a `View`
///
/// v0.8.0 W7 — `SettingsServerScreen` joined the list when Server was
/// promoted out of About's card into its own "Server & sync" hub row.
///
/// Pixel snapshots are deliberately avoided (per project convention;
/// see HLSettingsRowTests rationale) — the contract here is "does the IA
/// exist and compile?", which is sufficient to catch silent route
/// deletions in a future refactor.
@MainActor
@Suite("SettingsHub contract")
struct SettingsHubContractTests {
    /// Canonical Settings hub route list. If you change this list, AC18 is
    /// at risk — make sure the new route ships working content and not
    /// another "Demnaechst verfuegbar" placeholder.
    /// v0.14.1 (#134) — `SettingsExportScreen` moved out of the hub into the
    /// "Mehr" tab (Daten & Geräte). v0.14.7 C1 — it moved BACK into the hub
    /// (generic backup/measurements export is a setting); the doctor-handover
    /// surfaces split into Mehr → "Mit dem Arzt teilen" (`UnifiedSharingScreen` since 18-03,
    /// C2). The hub is back to 10 rows.
    static let expectedRouteCount = 10

    @Test("sub-screens compile and conform to View — locked route count")
    func subScreensCompile() {
        // Each anonymous closure constructs one sub-screen. Counting them
        // here is the anti-regression lock against AC18: someone adding
        // back `SettingsAPIScreen` or `SettingsThresholdsScreen` (both 100%
        // placeholder bodies in PB3) would need to also bump
        // `expectedRouteCount`, which surfaces the operator-rule violation
        // in code review.
        //
        // The two routes deliberately absent — `SettingsAPIScreen` and
        // `SettingsThresholdsScreen` — return when their editors actually
        // land (PB17 thresholds slider editor, PB26 token-management).
        let constructors: [() -> any View] = [
            { SettingsAccountScreen() },
            { SettingsIntegrationsScreen() },
            { SettingsNotificationsScreen() },
            { SettingsDashboardScreen() },
            { SettingsSourcesScreen() },
            { SettingsAIScreen() },
            { SettingsServerScreen() },
            { SettingsExportScreen() },
            { SettingsAdvancedScreen() },
            { SettingsAboutScreen() }
        ]

        #expect(constructors.count == Self.expectedRouteCount)

        for construct in constructors {
            _ = construct()
        }
    }

    @Test("HLSettingsCard renders header + body")
    func hlSettingsCardBody() {
        let card = HLSettingsCard(
            icon: "person.crop.circle.fill",
            title: "Profile",
            subtitle: "Beispiel-Untertitel",
            footer: "Beispiel-Footer"
        ) {
            Text("Body")
        }
        _ = card.body
    }

    @Test("HLSettingsCard trailing-slot initialiser composes")
    func hlSettingsCardTrailing() {
        let card = HLSettingsCard(
            icon: "link.circle.fill",
            title: "Withings",
            trailing: { HLStatusPill(.connected(label: "Verbunden")) },
            content: { Text("Body") }
        )
        _ = card.body
    }

    @Test("HLSettingsPage wraps a ScrollView header + content")
    func hlSettingsPageBody() {
        let page = HLSettingsPage(title: "Account") {
            HLSettingsCard(icon: "person.fill", title: "Profile") {
                Text("Body")
            }
        }
        _ = page.body
    }

    @Test("HLStatusPill resolves every state variant")
    func hlStatusPillStates() {
        for state in [
            HLStatusPill.State.connected(label: "OK"),
            .error(label: "Fehler"),
            .disconnected(label: "Aus"),
            .unknown(label: "?")
        ] {
            _ = HLStatusPill(state).body
        }
    }
}
