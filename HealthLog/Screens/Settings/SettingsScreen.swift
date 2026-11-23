import SwiftUI

/// Settings hub: a list of `NavigationLink` rows, each pushing a dedicated
/// sub-screen (`HealthLog/Screens/Settings/Sub/`) that mirrors the web's
/// `/settings/<slug>` routes. Every row leads to a real surface, never a
/// placeholder. `apiTokens` lists and revokes tokens but cannot mint one,
/// because the server has no generic `POST /api/tokens`.
///
/// Visual contract — per PA2 §17 ("Rainbow row-tints"):
/// - Hub list rows use a **single accent** (`Color.accentColor`) on every
///   `HLSettingsIconChip` so no row shouts louder than its neighbour.
/// - The sub-screens follow the monochrome doctrine (Theme-2.0
///   accent-restraint): `HLCard` carries no per-card title icon,
///   and the remaining icons render in `HLText.primary`.
/// - Sign-out and Delete-account stay at the bottom in their own dedicated
///   Sections with destructive role + footer copy (Apple HIG-correct;
///   web puts them inside the Account card, iOS keeps them visible).
struct SettingsScreen: View {
    @Environment(SettingsStore.self) private var store
    @Environment(HKReadinessStore.self) private var hkReadiness
    @Environment(AIProviderStore.self) private var aiProviderStore
    @Environment(\.appContainer) private var container

    @State private var refreshTick: Int = 0
    /// v0.6.0.8 Issue #10 fix A — drives the top-level "Mitteilungen
    /// aktivieren" call-out. Only the `denied` / `notDetermined` states
    /// render a card; once the user grants permission the call-out
    /// disappears so it doesn't permanently squat at the top of Settings.
    @State private var notificationAuthorizationStatus: NotificationsSystemStatus = .unknown

    var body: some View {
        // v0150 nav-scroll RCA (Bug 1): the inner `NavigationStack` was REMOVED.
        // `SettingsScreen` is only ever PUSHED onto `MoreScreen`'s `morePath`
        // stack (the gear `showSettings` binding + the `SettingsRoute.root`
        // deep-link), never a tab root — so wrapping it in its own stack made it
        // a nested `NavigationStack`. That split the navigation graph (a tapped
        // hub row pushed the INNER stack while a deep-link pushed the OUTER one)
        // and forced iOS to re-resolve two large-title bars + re-lay-out a
        // detached inner container on every pop — the operator's "ruckelt, als
        // würde was nachgeladen" on back. Relying on the host stack (like every
        // other Settings sub-screen, which own NO body NavigationStack) gives one
        // consistent back-stack and one navigation bar across the transition.
        Form {
            if notificationAuthorizationStatus.needsCallout {
                notificationsCalloutSection
            }
            // Sign-out + Delete-account moved out of this hub
            // into `SettingsAccountScreen` (Settings → Account). They are
            // account-lifecycle actions, not hub navigation, so they now
            // live next to the profile they govern.
            // The hub's sync footer is gone: the sync state has no
            // bearing on a list of settings, and the symbol beside the avatar
            // already carries it. The success haptic still confirms a pull.
            hubSection
        }
        .hlPageMargins()
        .navigationTitle("Settings")
        // A page under More: inline, like every other sub-page.
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if store.profile == nil {
                await store.load()
            }
            await hkReadiness.refresh()
            if aiProviderStore.config == nil { await aiProviderStore.load() }
            await refreshNotificationStatus()
        }
        .refreshable {
            await refresh()
        }
        // Success-haptic confirms the pull-to-refresh round-trip
        // completed (parallel to Apple Mail / Health pull-to-refresh confirm tick).
        .sensoryFeedback(.success, trigger: refreshTick)
        // SET-V2-C (C-6, operator-mandated) — the hub's `.task`/`.refreshable`
        // loads used to swallow errors silently (both stores set
        // `error: HLError?`, but nothing rendered it). Same canonical
        // banner-overlay pattern as Dashboard / Medications / Mood
        // (`hlErrorBannerOverlay`, audit-v021 C5): top-anchored, localized
        // via `HLError.userFacingDescription`, retry re-runs the refresh,
        // auto-hides once a load clears the store error.
        .hlErrorBannerOverlay(error: refreshError) {
            Task { await refresh() }
        }
    }

    /// First server-load error from the hub's refresh
    /// surfaces.
    private var refreshError: HLError? {
        store.error ?? aiProviderStore.error
    }

    /// Shared pull-to-refresh / banner-retry path — identical to the
    /// pre-C-6 `.refreshable` body so retry and the gesture stay in
    /// lockstep.
    private func refresh() async {
        await store.load()
        await hkReadiness.refresh()
        await aiProviderStore.load()
        await refreshNotificationStatus()
        refreshTick &+= 1
    }

    // MARK: - Notifications call-out

    /// Top-level recovery card for users who never reached the
    /// onboarding `NotificationsPermissionStep`. Renders only when the
    /// system reports `.notDetermined` or `.denied`; once the user
    /// grants permission the card disappears so it doesn't squat at the
    /// top of Settings forever. The row's subtitle says what a
    /// tap does; the footer that said it again is gone.
    private var notificationsCalloutSection: some View {
        Section {
            Button {
                Task { await runNotificationsCalloutAction() }
            } label: {
                // The action stands at the row's end in words, so the row
                // reads as something to tap, not as a notice.
                HLSettingsRow(
                    icon: "bell.badge.fill",
                    title: notificationsCalloutTitle,
                    subtitle: notificationsCalloutSubtitle
                ) {
                    Text(notificationsCalloutAction)
                        .hlText(.rowTitle)
                }
            }
            .buttonStyle(.hlRow)
            .accessibilityIdentifier("settings.notifications.callout")
        }
        .hlFormRowSurface()
    }

    private var notificationsCalloutTitle: LocalizedStringKey {
        switch notificationAuthorizationStatus {
        case .denied: "Notifications blocked"
        default: "Enable notifications"
        }
    }

    private var notificationsCalloutAction: LocalizedStringKey {
        switch notificationAuthorizationStatus {
        case .denied: "settings.notifications.callout.open"
        default: "settings.notifications.callout.enable"
        }
    }

    private var notificationsCalloutSubtitle: LocalizedStringKey {
        switch notificationAuthorizationStatus {
        case .denied: "Re-enable in iOS Settings"
        default: "For medication and mood reminders"
        }
    }

    private func runNotificationsCalloutAction() async {
        switch notificationAuthorizationStatus {
        case .notDetermined:
            #if canImport(UserNotifications) && canImport(UIKit)
                guard let notif = container?.notifications else { return }
                _ = await notif.requestAuthorization()
                await refreshNotificationStatus()
            #endif
        case .denied:
            #if canImport(UIKit)
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                await UIApplication.shared.open(url)
            #endif
        default:
            break
        }
    }

    private func refreshNotificationStatus() async {
        #if canImport(UserNotifications) && canImport(UIKit)
            guard let notif = container?.notifications else { return }
            let settings = await notif.currentSettings()
            notificationAuthorizationStatus = NotificationsSystemStatus(authorization: settings.authorizationStatus)
        #endif
    }

    // MARK: - Hub (usage-frequency order)

    /// NavigationLink rows for the Settings sub-screens, ordered by iOS
    /// usage frequency. Monochrome icon-chips with the single
    /// `Color.accentColor` accent, per PA2 §17: rainbow-tinted rows read as
    /// "clicky-bunt".
    private var hubSection: some View {
        Section {
            ForEach(HubRow.allCases) { row in
                // #153 follow-up — a value on the More stack,
                // resolved in `MoreScreen`, so the page comes back after the
                // privacy shield rebuilt the window.
                NavigationLink(value: row) {
                    HLSettingsRow(
                        icon: row.icon,
                        title: LocalizedStringKey(row.title),
                        subtitle: row.subtitle.map { LocalizedStringKey($0) }
                    )
                }
                .accessibilityIdentifier(row.accessibilityIdentifier)
            }
        }
        .hlFormRowSurface()
    }

    // MARK: - Konto

    //
    // Sign-out + Konto-löschen moved out of this hub onto
    // `SettingsAccountScreen` (Settings → Account). They are account-lifecycle
    // actions tied to the profile, so they now live next to it instead of as
    // two trailing sections under the hub navigation rows. The destructive
    // `DeleteAccountScreen` sheet moved with them.
}

// MARK: - Hub row catalogue

/// Catalogue of the hub rows — name, icon, subtitle (web `description`),
/// destination view, and accessibility identifier in one place so the hub
/// stays declarative.
///
/// Order follows iOS usage frequency, not the web sidebar: HIG favours
/// most-used first, so Account, Notifications and Appearance sit above the
/// power-user surface (Sources) and the rarely touched rows (Privacy &
/// Security, About). Some enum cases keep an older name (`dashboard`,
/// `advanced`, `sources`) because their accessibility identifiers are
/// selectors in tests and deep links.
///
/// **Internal, not private.** The hub's row descriptors are a
/// contract surface: R5-A1 requires every one of them to carry a subtitle in the
/// stated register, and `SettingsSubtitleTests` asserts that over `allCases`
/// rather than over a hand-kept copy of the list. A `private` model can only be
/// checked by scanning source text, which cannot see whether the copy is
/// catalogued or what it says in German.
enum HubRow: String, CaseIterable, Identifiable {
    case account
    case notifications
    case dashboard
    case integrations
    /// BLE device pairing. Sits right after Integrations (Apple Health /
    /// Withings) since "what's connected to my account" reads as one cluster.
    case devices
    /// Siri & Shortcuts discovery surface. Sits after Devices
    /// ("what's connected") and before Source priority: it's about how the OS
    /// reaches the app (voice / Shortcuts / Spotlight), a system-integration
    /// concern adjacent to Integrations and Devices.
    case siri
    /// MCP connector. Sits in the "what's connected to my
    /// account" cluster, right after Siri: it is the surface where a user sees
    /// and cuts an external assistant's live access to their record.
    case mcp
    /// API token management. Directly after MCP; both answer
    /// "which credentials can reach my data".
    case apiTokens
    case sources
    case ai
    case serverSync
    /// Generic backup and measurement export is a *setting* the user reaches
    /// for under Einstellungen. `SettingsExportScreen` hosts only the generic
    /// exports (full JSON/CSV backup and per-domain CSV); the doctor-handover
    /// surfaces live under Mehr → "Mit dem Arzt teilen" (`UnifiedSharingScreen`).
    case export
    /// Which pillars count toward the Health Score (server v1.35.0). Sits
    /// directly beside Modules because both answer "what does the app count
    /// for me"; the distinction the pair has to keep visible is that Modules
    /// says what gets *recorded* and this says what gets *counted*.
    case healthScore
    // Per-user feature-module on/off toggles (server v1.18.0). Sits before
    // Privacy & Security: "which parts of the app are on" reads as a
    // configuration concern, adjacent to Appearance/Source-priority.
    case modules
    case advanced
    case about

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .account: "person.crop.circle.fill"
        case .integrations: "link.circle.fill"
        // Same glyph `SettingsDevicesScreen` uses internally so the
        // hub→detail transition reads continuous.
        case .devices: "dot.radiowaves.left.and.right"
        case .notifications: "bell.fill"
        // Matches the Personalisierung card icon inside
        // SettingsDashboardScreen so the hub→detail transition reads as one
        // continuous surface.
        case .dashboard: "paintpalette.fill"
        case .siri: "mic.fill"
        // The "who can reach my data" pair. `powerplug`
        // matches the web MCP card's plug glyph; `key.fill` matches the web
        // API-token card.
        case .mcp: "powerplug.fill"
        case .apiTokens: "key.fill"
        case .sources: "square.stack.3d.up"
        case .ai: "sparkles"
        // `server.rack` matches the icon `SettingsServerScreen` uses, so
        // the hub→detail transition stays continuous.
        case .serverSync: "server.rack"
        // The down-arrow tray glyph keeps the hub→`SettingsExportScreen`
        // transition continuous.
        case .export: "square.and.arrow.down.fill"
        // Same glyph the screen's own card wears, so the hub→detail
        // transition reads continuous.
        case .healthScore: "slider.horizontal.3"
        // Feature-module switchboard.
        case .modules: "square.grid.2x2.fill"
        // The lock-shield glyph matches the screen's own security card and
        // reads as privacy and security at a glance.
        case .advanced: "lock.shield.fill"
        case .about: "info.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .account: "Account"
        case .integrations: "Integrations"
        case .devices: "Devices"
        case .notifications: "Notifications"
        // The sub-screen hosts the visual configuration (layout,
        // Erscheinungsbild picker, tile editor), so it is named for that.
        case .dashboard: "Appearance"
        case .siri: "Siri & Shortcuts"
        case .mcp: "MCP connector"
        case .apiTokens: "API tokens"
        // The row is priority-only (the cross-source ladder); the per-type
        // Apple Health toggles live on the Apple Health integration page.
        case .sources: "Source priority"
        // The screen owns the assistant provider and chain, the on-device
        // trend toggle and the Coach; tile customization is in Appearance.
        case .ai: "Assistant"
        case .serverSync: "Server & sync"
        // Generic backup and per-domain CSV.
        case .export: "Export"
        // Which pillars carry the composite.
        case .healthScore: "Health Score"
        // Feature-module switchboard.
        case .modules: "Modules"
        // Its content (audit log, LOINC review, biometric lock, delete
        // account) is exactly privacy and security.
        case .advanced: "Privacy & Security"
        case .about: "About this app"
        }
    }

    /// **UI-Standard R5, Amendment A1 (2026-08-23) — jede Hub-Zeile trägt einen
    /// Untertitel.**
    ///
    /// Die frühere Fassung dieses Kommentars führte fünf Zeilen auf, deren
    /// Untertitel nach R5 „gefallen" waren, weil sie den Titel nur umformuliert
    /// hätten. Diese Entscheidung (Einheit U7) ist von R5-A1 **namentlich
    /// aufgehoben**: der Betreiber liest die Mischung aus erklärten und
    /// unerklärten Zeilen nicht als Zurückhaltung, sondern als unfertige Arbeit
    /// („‚Konto' erklärt sich, ‚Geräte' sagt nichts"). Ein Untertitel, der nur
    /// umformuliert, fällt hier nicht mehr weg — er wird umgeschrieben, bis er
    /// etwas trägt.
    ///
    /// Register: eine kurze Aufzählung oder ein Teilsatz, **Komma als einziges
    /// Trennzeichen**, kein Schlusspunkt; passt in eine Zeile (seit 1.4 B2-c
    /// bricht ein zu langer Untertitel um, statt mit „…“ zu enden). Der
    /// Mittelpunkt ist raus (Betreiber-Urteil: wirkt KI-generiert). Jede Zeile
    /// ist Katalog-Inhalt — rohe Literale gibt es hier nicht mehr.
    ///
    /// **Prüfung:** `SettingsSubtitleTests` hält die Regel über
    /// `HubRow.allCases`, in beiden Sprachen.
    var subtitle: String? {
        switch self {
        case .account: "Profile, passkeys"
        // Was the raw literal "Apple Health · Withings": uncatalogued,
        // middle-dotted, and only naming two of the four providers the screen
        // hosts. Catalogued, comma-separated and complete.
        case .integrations: "Apple Health, Withings, WHOOP, Oura"
        // The five U7 nils, written. Each names what the screen
        // behind it actually contains, checked against that screen rather than
        // guessed: R7 outranks brevity.
        case .devices: "Paired devices, add new"
        case .notifications: "Reminders, channels, delivery"
        case .dashboard: "Tiles, rings, Insights layout"
        case .siri: "Voice logging, phrases, automations"
        case .mcp: "Connected assistants, tokens"
        case .apiTokens: "See and revoke API access"
        case .sources: "Which source wins per metric"
        // Insights customization moved to Appearance, so the
        // subtitle no longer promises tile customization here.
        // Shortened to fit one line (it ended in "KI-Anbi…").
        case .ai: "Coach, trend hints, AI provider"
        case .serverSync: "Connection, region, server version"
        // Generic exports only; the doctor-handover surfaces
        // moved to Mehr → "Mit dem Arzt teilen".
        case .export: "Full backup, CSV per area"
        // R5 — bleibt: grenzt ein statt umzuformulieren. „Health Score" allein
        // sagt nicht, dass hinter der Zeile eine Auswahl liegt und keine
        // Anzeige des Werts.
        case .healthScore: "Which pillars count"
        case .modules: "Which features are on"
        // Was "Sicherheit · Audit", which both leaked raw
        // German and collided with the old root Security section.
        // Glucose targets and injection sites moved
        // to their subject homes (Über mich / Medications), and the old
        // subtitle's "clinical mappings" had been stale since 08-06 removed
        // the LOINC sign-off. What the screen holds now is exactly one thing,
        // and the subtitle says exactly that.
        case .advanced: "Biometric app lock"
        // Deliberately does NOT promise a licence card: the screen has
        // the app card, the two links and the update note, and nothing else.
        case .about: "Version, privacy policy, docs"
        }
    }

    var accessibilityIdentifier: String {
        "settings.hub.\(rawValue)"
    }

    /// `@MainActor` because some destinations (e.g. `SettingsAIScreen`)
    /// now hold `@Environment` properties whose default values are main-actor
    /// isolated, making their synthesized `init()` main-actor isolated. The only
    /// consumer is `hubSection` inside a View body (already on the main actor).
    @ViewBuilder @MainActor
    var destination: some View {
        switch self {
        case .account: SettingsAccountScreen(routesByValue: true)
        case .integrations: SettingsIntegrationsScreen()
        case .devices: SettingsDevicesScreen()
        case .siri: SettingsSiriShortcutsScreen()
        case .mcp: SettingsMcpScreen()
        case .apiTokens: SettingsApiTokensScreen()
        case .notifications: SettingsNotificationsScreen()
        case .dashboard: SettingsDashboardScreen()
        case .sources: SettingsSourcesScreen()
        case .ai: SettingsAIScreen()
        case .serverSync: SettingsServerScreen()
        case .export: SettingsExportScreen()
        case .healthScore: SettingsHealthScoreScreen()
        case .modules: SettingsModulesScreen()
        case .advanced: SettingsAdvancedScreen()
        case .about: SettingsAboutScreen()
        }
    }
}
