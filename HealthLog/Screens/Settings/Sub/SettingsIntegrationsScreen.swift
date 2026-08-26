import SwiftUI

/// Pure, data-driven per-provider connected-state derivation for the
/// integrations list badges. Kept off the View so the predicate is unit-
/// testable. `nil` ⇒ status not loaded yet (render the calm `.unknown` pill,
/// never a false "Connected").
enum IntegrationConnectedState {
    /// Withings is connected when the server status reports `connected`.
    static func withings(_ status: WithingsStatus?) -> Bool? {
        status.map(\.connected)
    }

    /// WHOOP is connected only when the credentials are configured AND the
    /// OAuth link is live — mirrors `WhoopIntegrationStore.stage == .connected`.
    static func whoop(_ status: WhoopStatus?) -> Bool? {
        guard let status else { return nil }
        return (status.configured ?? false) && status.connected
    }
}

/// `/settings/integrations` — Integrationen. Ships the integrations with real
/// connect/sync paths: Apple Health (pulled up from the legacy "Apple Health"
/// section of the old monolithic SettingsScreen), Withings and WHOOP (each a
/// full sub-screen).
///
/// **v0.14.1 #4 — no MoodLog integration.** The MoodLog placeholder PB3 once
/// shipped here is permanently gone (operator: unused + confusing, handled
/// elsewhere). Do NOT re-add a MoodLog integration row — mood lives in its own
/// surface, not as a connectable provider on this page.
///
/// Withings has a dedicated full-screen sub (`WithingsIntegrationScreen`) —
/// we route into it from a single nav row rather than duplicating its
/// connect/sync/disconnect surface here.
///
/// **v0.12 W4-4:** the Apple-Health-Import card (a permanently-disabled
/// "Coming soon v0.6" placeholder pushing a no-op CTA screen) was REMOVED — it
/// read as abandoned stub UI. The real one-shot ZIP-import path lands in its own
/// wave against the live `/api/import/apple-health-export` endpoint, which
/// re-introduces the entry point wired to a working CTA.
struct SettingsIntegrationsScreen: View {
    @Environment(HKReadinessStore.self) private var hkReadiness
    @Environment(BackendAvailability.self) private var backend
    @Environment(WithingsIntegrationStore.self) private var withings
    @Environment(WhoopIntegrationStore.self) private var whoop
    // v1.18.7 web-parity (❌-7) — the four additional server-OAuth /
    // self-hoster integrations whose data already flows server-side but had no
    // iOS manage card. Each mirrors the Withings/WHOOP Store→Repo→Screen shape.
    @Environment(OuraIntegrationStore.self) private var oura
    @Environment(PolarIntegrationStore.self) private var polar
    @Environment(FitbitIntegrationStore.self) private var fitbit
    // v1.28.11 (#46) — Strava workout/activity connector.
    @Environment(StravaIntegrationStore.self) private var strava
    @Environment(NightscoutIntegrationStore.self) private var nightscout
    @State private var refreshTick: Int = 0

    var body: some View {
        HLSettingsPage(title: "Integrations") {
            appleHealthCard
            // W-B187 (Settings consolidation §A.3) — the Apple-Health-Import peer
            // row was FOLDED INTO `AppleHealthIntegrationDetailScreen` (the one
            // "Apple Health" detail page), so the Integrations list shows ONE
            // "Apple Health" row instead of two confusing peers. The one-shot
            // export.zip importer is now reached from inside that detail page.
            withingsCard
            whoopCard
            // v1.18.7 web-parity (❌-7) — Oura / Polar / Fitbit / Nightscout.
            ouraCard
            polarCard
            fitbitCard
            stravaCard
            nightscoutCard
        }
        .navigationTitle("Integrations")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await hkReadiness.refresh()
            // Server-backed providers only — standalone has no status endpoint.
            if backend.hasServer {
                await loadServerStatuses()
            }
        }
        .refreshable {
            await hkReadiness.refresh()
            if backend.hasServer {
                await loadServerStatuses()
            }
            refreshTick &+= 1
        }
        // POLISH-SWEEP: success-tick confirms pull-to-refresh round-trip.
        .sensoryFeedback(.success, trigger: refreshTick)
    }

    /// Loads every server-backed integration's status. Sequential on the main
    /// actor — the stores are `@MainActor @Observable`, and Settings status
    /// reads are low-rate, so a serial walk keeps it simple and isolation-safe.
    private func loadServerStatuses() async {
        await withings.loadStatus()
        await whoop.loadStatus()
        await oura.loadStatus()
        await polar.loadStatus()
        await fitbit.loadStatus()
        await strava.loadStatus()
        await nightscout.loadStatus()
    }

    // MARK: - Apple Health

    /// **v0.11 Settings-IA-Restructure:** der frühere inline Apple-Health-Block
    /// (Status-Pill + Connect + Sync-now + Datentyp-Toggles + Transparenz-Rows)
    /// ist auf `AppleHealthIntegrationDetailScreen` gewandert. Die Integrationen-
    /// Liste liest jetzt uniform: jede Integration = eine Row → eigene
    /// Detailseite (wie Withings). Die Status-Pill bleibt hier als Trailing-
    /// Badge sichtbar, damit der Verbindungsstand auf einen Blick lesbar ist.
    private var appleHealthCard: some View {
        HLSettingsCard(
            icon: "heart.text.square.fill",
            title: "Apple Health",
            subtitle: "Read and write access to vitals",
            trailing: { appleHealthPill },
            content: { appleHealthRow }
        )
    }

    /// Eine Ableitung, ein Maler — siehe ``HealthKitStatusPill``. Diese Fläche
    /// malte `.partiallyGranted` unbesehen rot, während dieselbe Lage eine
    /// Ebene tiefer „Verbunden“ las (Betreiber-Befund 2026-07-31).
    private var appleHealthPill: some View {
        HealthKitStatusPill()
    }

    /// R8/R10 — war eine handgebaute Chevron-Zeile; das Trailing-Glyph gehört
    /// jetzt dem Primitive, und `.push` kapselt den `NavigationLink`.
    private var appleHealthRow: some View {
        HLSettingsActionRow(title: "Open Apple Health", presents: .push) {
            AppleHealthIntegrationDetailScreen()
        }
        .accessibilityIdentifier("settings.integrations.appleHealthRow")
    }

    // W-B187 (Settings consolidation §A.3) — `appleHealthImportCard` was folded
    // into `AppleHealthIntegrationDetailScreen`; the import is no longer a peer
    // row on this list.

    // MARK: - Generic connected badge

    /// Data-driven connected badge shared by every server-backed integration
    /// row (Withings, WHOOP, …). One connected-status input per row — the row
    /// shows "Connected" iff that provider is actually connected. Before the
    /// status loads (`isConnected == nil`) it stays in the calm `.unknown`
    /// state so no false "Connected" flashes. Standalone (no server) renders
    /// nothing.
    @ViewBuilder
    private func connectedPill(isConnected: Bool?) -> some View {
        if backend.hasServer {
            switch isConnected {
            case .some(true):
                HLStatusPill(.connected(label: String(localized: "Connected")))
            case .some(false):
                HLStatusPill(.disconnected(label: String(localized: "Not connected")))
            case .none:
                HLStatusPill(.unknown(label: String(localized: "Checking")))
            }
        }
    }

    /// Withings is connected when the server status reports `connected`.
    private var withingsConnected: Bool? {
        IntegrationConnectedState.withings(withings.status)
    }

    /// WHOOP is connected when the credentials are configured AND the OAuth
    /// link is live — mirrors `WhoopIntegrationStore.stage == .connected`.
    private var whoopConnected: Bool? {
        IntegrationConnectedState.whoop(whoop.status)
    }

    // MARK: - Withings

    private var withingsCard: some View {
        HLSettingsCard(
            icon: "link.circle.fill",
            title: "Withings",
            subtitle: "Import vitals and activity from your Withings account.",
            trailing: { connectedPill(isConnected: withingsConnected) },
            content: { withingsRow }
        )
    }

    private var withingsRow: some View {
        HLSettingsActionRow(title: "Open Withings", presents: .push) {
            WithingsIntegrationScreen()
        }
        .accessibilityIdentifier("settings.integrations.withingsRow")
    }

    // MARK: - WHOOP

    private var whoopCard: some View {
        HLSettingsCard(
            icon: "link.circle.fill",
            title: "WHOOP",
            subtitle: "Import recovery, strain and sleep from your WHOOP account.",
            trailing: { connectedPill(isConnected: whoopConnected) },
            content: { whoopRow }
        )
    }

    private var whoopRow: some View {
        HLSettingsActionRow(title: "Open WHOOP", presents: .push) {
            WhoopIntegrationScreen()
        }
        .accessibilityIdentifier("settings.integrations.whoopRow")
    }

    // MARK: - v1.18.7 web-parity (❌-7): Oura / Polar / Fitbit / Nightscout

    private var ouraCard: some View {
        HLSettingsCard(
            icon: "moon.fill",
            title: "Oura",
            subtitle: "Import sleep, readiness and activity from your Oura account.",
            trailing: { connectedPill(isConnected: oura.isConnected) },
            content: {
                integrationRow(label: "Open Oura", identifier: "settings.integrations.ouraRow") {
                    OAuthIntegrationScreen<OuraIntegrationStore>(
                        displayName: "Oura",
                        placeholderSurface: String(localized: "cloud_derived.surface.oura")
                    )
                }
            }
        )
    }

    private var polarCard: some View {
        HLSettingsCard(
            icon: "figure.run",
            title: "Polar",
            subtitle: "Import workouts, heart rate and recovery from your Polar account.",
            trailing: { connectedPill(isConnected: polar.isConnected) },
            content: {
                integrationRow(label: "Open Polar", identifier: "settings.integrations.polarRow") {
                    OAuthIntegrationScreen<PolarIntegrationStore>(
                        displayName: "Polar",
                        placeholderSurface: String(localized: "cloud_derived.surface.polar")
                    )
                }
            }
        )
    }

    private var fitbitCard: some View {
        HLSettingsCard(
            icon: "figure.walk",
            title: "Fitbit",
            subtitle: "Import steps, sleep and heart rate from your Fitbit account.",
            trailing: { connectedPill(isConnected: fitbit.isConnected) },
            content: {
                integrationRow(label: "Open Fitbit", identifier: "settings.integrations.fitbitRow") {
                    OAuthIntegrationScreen<FitbitIntegrationStore>(
                        displayName: "Fitbit",
                        placeholderSurface: String(localized: "cloud_derived.surface.fitbit")
                    )
                }
            }
        )
    }

    private var stravaCard: some View {
        HLSettingsCard(
            icon: "figure.outdoor.cycle",
            title: "Strava",
            subtitle: "Import workouts and activities from your Strava account.",
            trailing: { connectedPill(isConnected: strava.isConnected) },
            content: {
                integrationRow(label: "Open Strava", identifier: "settings.integrations.stravaRow") {
                    OAuthIntegrationScreen<StravaIntegrationStore>(
                        displayName: "Strava",
                        placeholderSurface: String(localized: "cloud_derived.surface.strava")
                    )
                }
            }
        )
    }

    private var nightscoutCard: some View {
        HLSettingsCard(
            icon: "drop.circle.fill",
            title: "Nightscout",
            subtitle: "Connect your own Nightscout instance for continuous glucose data.",
            trailing: { connectedPill(isConnected: nightscout.isConnected) },
            content: {
                integrationRow(label: "Open Nightscout", identifier: "settings.integrations.nightscoutRow") {
                    NightscoutIntegrationScreen()
                }
            }
        )
    }

    /// Shared nav row used by the new integration cards (one label → its detail
    /// screen), matching the Withings/WHOOP row shape.
    private func integrationRow(
        label: LocalizedStringKey,
        identifier: String,
        @ViewBuilder destination: @escaping () -> some View
    ) -> some View {
        HLSettingsActionRow(title: label, presents: .push, destination: destination)
            .accessibilityIdentifier(identifier)
    }

    // v0.6.1.5 Y5: the legacy `statRow` helper was removed alongside the
    // Apple Health card rebuild — the new hierarchy stack uses `Text`
    // primitives at `hlSubhead` (description) and `hlCaption` (status
    // line) directly. Withings + Apple-Health-Import + HK-Diagnostics
    // surfaces don't render stat-rows.
}
