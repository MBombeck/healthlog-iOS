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
    @Environment(\.appContainer) private var container
    /// 1.5 MOVE (#133) — the `dawarich` entry of the consolidated status,
    /// display only. `nil` until read, on a server that does not list it, and
    /// after a failed read: the row then stays away.
    @State private var dawarich: DawarichIntegrationPayload.Entry?
    @State private var refreshTick: Int = 0

    var body: some View {
        HLSettingsPage(title: "Integrations") {
            appleHealthCard
            // W-B187 (Settings consolidation §A.3) — the Apple-Health-Import peer
            // row was FOLDED INTO `AppleHealthIntegrationDetailScreen` (the one
            // "Apple Health" detail page), so the Integrations list shows ONE
            // "Apple Health" row instead of two confusing peers. The one-shot
            // export.zip importer is now reached from inside that detail page.
            servicesCard
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
        if let api = container?.api {
            dawarich = try? await MovementRepository(api: api).integrationEntry()
        }
    }

    // MARK: - Apple Health

    /// **v0.11 Settings-IA-Restructure:** der frühere inline Apple-Health-Block
    /// (Status-Pill + Connect + Sync-now + Datentyp-Toggles + Transparenz-Rows)
    /// ist auf `AppleHealthIntegrationDetailScreen` gewandert. Die Integrationen-
    /// Liste liest jetzt uniform: jede Integration = eine Row → eigene
    /// Detailseite (wie Withings). Die Status-Pill bleibt hier als Trailing-
    /// Badge sichtbar, damit der Verbindungsstand auf einen Blick lesbar ist.
    ///
    /// 1.4 B4 — one row, one heading: "Apple Health" over "Apple Health
    /// öffnen" said the name twice. The card is its row now, with the state
    /// and the chevron like the services below.
    private var appleHealthCard: some View {
        HLSettingsCard { appleHealthRow }
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
        HLSettingsActionRow(
            icon: "heart.fill",
            title: "Apple Health",
            subtitle: "Read and write access to vitals",
            presents: .push,
            // POLISH-C (C2) — a value, so the page survives the privacy shield.
            value: SettingsRoute.appleHealthDetail,
            trailing: { appleHealthPill }
        )
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
    ///
    /// 1.4 B4 — `failed`: the status read failed. "Checking" would then stay
    /// forever, so the row shows no state until a read succeeds.
    @ViewBuilder
    private func connectedPill(isConnected: Bool?, health: ConnectionHealth? = nil, failed: Bool = false) -> some View {
        if backend.hasServer {
            switch isConnected {
            case .some(true):
                // #139 — a connected provider reads its state from `health`;
                // without it (server before v1.42.4) the plain "Connected".
                if let health {
                    HLStatusPill(ConnectionHealthPresentation(health: health).pill)
                } else {
                    HLStatusPill(.connected(label: String(localized: "Connected")))
                }
            case .some(false):
                HLStatusPill(.disconnected(label: String(localized: "Not connected")))
            case .none:
                if !failed {
                    HLStatusPill(.unknown(label: String(localized: "Checking")))
                }
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

    // MARK: - Services

    /// **1.4 B2-c — one list instead of seven cards.** Withings, WHOOP (v0.12),
    /// Oura, Polar, Fitbit, Nightscout (v1.18.7 web parity) and Strava
    /// (v1.28.11, #46) each had a card of its own: title, an "Import … from
    /// your … account" subtitle cut after one line, the status pill, and a
    /// single "Open …" row. They are rows of one card now: the provider's
    /// name, its pill, the chevron. The names say what they are.
    private var servicesCard: some View {
        HLSettingsCard(icon: "link.circle.fill", title: "settings.integrations.services") {
            serviceRow("Withings", icon: "link.circle.fill", identifier: "settings.integrations.withingsRow", route: .withings) {
                connectedPill(isConnected: withingsConnected, health: withings.status?.health, failed: withings.error != nil)
            }
            serviceRow("WHOOP", icon: "link.circle.fill", identifier: "settings.integrations.whoopRow", route: .whoop) {
                connectedPill(isConnected: whoopConnected, health: whoop.status?.health, failed: whoop.error != nil)
            }
            serviceRow("Oura", icon: "moon.fill", identifier: "settings.integrations.ouraRow", route: .oura) {
                connectedPill(isConnected: oura.isConnected, health: oura.status?.health, failed: oura.error != nil)
            }
            serviceRow("Polar", icon: "figure.run", identifier: "settings.integrations.polarRow", route: .polar) {
                connectedPill(isConnected: polar.isConnected, health: polar.status?.health, failed: polar.error != nil)
            }
            // KONTO (#149) — after the turndown the row says so; an account
            // that never had Fitbit is not offered the row at all.
            if fitbit.isOffered {
                serviceRow("Fitbit", icon: "figure.walk", identifier: "settings.integrations.fitbitRow", route: .fitbit) {
                    if fitbit.isRetired, backend.hasServer {
                        HLStatusPill(.disconnected(label: String(localized: "integration.fitbit.retired.pill")))
                    } else {
                        connectedPill(isConnected: fitbit.isConnected, health: fitbit.status?.health, failed: fitbit.error != nil)
                    }
                }
            }
            serviceRow("Strava", icon: "figure.outdoor.cycle", identifier: "settings.integrations.stravaRow", route: .strava) {
                connectedPill(isConnected: strava.isConnected, health: strava.status?.health, failed: strava.error != nil)
            }
            serviceRow("Nightscout", icon: "drop.circle.fill", identifier: "settings.integrations.nightscoutRow", route: .nightscout) {
                connectedPill(isConnected: nightscout.isConnected, health: nightscout.status?.health, failed: nightscout.error != nil)
            }
            dawarichRow
        }
    }

    /// 1.5 MOVE (#133) — Dawarich is connected on the web; the app shows
    /// its state and nothing to tap. Its days appear under Environment.
    @ViewBuilder
    private var dawarichRow: some View {
        if backend.hasServer, let dawarich {
            HLSettingsRow(
                icon: "location.circle.fill",
                title: "Dawarich",
                subtitle: dawarich.connected ? nil : "integration.dawarich.webOnly"
            ) {
                connectedPill(isConnected: dawarich.connected, health: dawarich.health)
            }
            .accessibilityIdentifier("settings.integrations.dawarichRow")
        }
    }

    /// One provider: chip, name, status pill, chevron into its detail screen.
    /// POLISH-C (C2) — pushed as a value (``IntegrationRoute``), resolved by
    /// ``IntegrationRouteDestination`` on the More stack, so the provider page
    /// comes back after the privacy shield.
    private func serviceRow(
        _ name: LocalizedStringKey,
        icon: String,
        identifier: String,
        route: IntegrationRoute,
        @ViewBuilder pill: () -> some View
    ) -> some View {
        HLSettingsActionRow(icon: icon, title: name, presents: .push, value: SettingsRoute.integration(route), trailing: pill)
            .accessibilityIdentifier(identifier)
    }

    // v0.6.1.5 Y5: the legacy `statRow` helper was removed alongside the
    // Apple Health card rebuild — the new hierarchy stack uses `Text`
    // primitives at `hlSubhead` (description) and `hlCaption` (status
    // line) directly. Withings + Apple-Health-Import + HK-Diagnostics
    // surfaces don't render stat-rows.
}

/// POLISH-C (C2) — the page behind each provider row of Integrations.
struct IntegrationRouteDestination: View {
    let route: IntegrationRoute

    var body: some View {
        switch route {
        case .withings:
            WithingsIntegrationScreen()
        case .whoop:
            WhoopIntegrationScreen()
        case .oura:
            OAuthIntegrationScreen<OuraIntegrationStore>(
                displayName: "Oura",
                placeholderSurface: String(localized: "cloud_derived.surface.oura")
            )
        case .polar:
            OAuthIntegrationScreen<PolarIntegrationStore>(
                displayName: "Polar",
                placeholderSurface: String(localized: "cloud_derived.surface.polar")
            )
        case .fitbit:
            OAuthIntegrationScreen<FitbitIntegrationStore>(
                displayName: "Fitbit",
                placeholderSurface: String(localized: "cloud_derived.surface.fitbit")
            )
        case .strava:
            OAuthIntegrationScreen<StravaIntegrationStore>(
                displayName: "Strava",
                placeholderSurface: String(localized: "cloud_derived.surface.strava")
            )
        case .nightscout:
            NightscoutIntegrationScreen()
        }
    }
}
