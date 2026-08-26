import SwiftUI

/// Settings hub. **PB3 v0.5.0+ rewrite per PA2 §Recommended Pattern,
/// trimmed in fix/v05x-pb3-baustelle per operator AC18 ruling.**
///
/// Previously a single monolithic `Form` painting nine inline sections
/// with rainbow-tinted icon-chips per row — the dominant source of the
/// "super clicky-bunt" user feedback in v0.4.2. PB3 collapsed the body
/// into a hub of 11 `NavigationLink` rows that each pushed a dedicated
/// sub-screen (`HealthLog/Screens/Settings/Sub/`) mirroring the web's
/// `/settings/<slug>` routes column-for-column. The Baustelle-reconcile
/// then dropped the two routes whose entire body was a placeholder
/// (`api`, `thresholds`) per operator directive "Ich möchte keine
/// Fake-Sachen haben". The `thresholds` editor has since shipped as
/// `TargetEditorSheet` (More → Goals → pencil), and `api`
/// (token-management, PB26) shipped in Build 2 / 2.8 as `apiTokens` —
/// list + revoke, no mint, because the server removed the generic
/// `POST /api/tokens`. Build 2 / 2.7 added the sibling `mcp` route.
/// Both are real surfaces, not placeholders.
///
/// Visual contract — per PA2 §17 ("Rainbow row-tints"):
/// - Hub list rows use a **single accent** (`Color.accentColor`) on every
///   `HLSettingsIconChip` so no row shouts louder than its neighbour.
/// - The sub-screens follow the monochrome doctrine (Theme-2.0
///   accent-restraint): `HLSettingsCard` dropped its per-card title icon
///   entirely (W1-4, R5 #2 finding #3), and surviving icons render in
///   `HLText.primary` — no purple tint.
/// - Sign-out and Delete-account stay at the bottom in their own dedicated
///   Sections with destructive role + footer copy (Apple HIG-correct;
///   web puts them inside the Account card, iOS keeps them visible).
///
/// The 9-section v0.4.1 layout is preserved in spirit: every toggle /
/// picker / action that lived inline still works — it just moved one
/// navigation hop deeper into its proper sub-screen.
struct SettingsScreen: View {
    @Environment(SettingsStore.self) private var store
    @Environment(AuthStore.self) private var authStore
    @Environment(HKReadinessStore.self) private var hkReadiness
    @Environment(AIProviderStore.self) private var aiProviderStore
    @Environment(SyncModeStore.self) private var syncMode
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
            if syncMode.isStandalone {
                pairServerSection
            }
            if notificationAuthorizationStatus.needsCallout {
                notificationsCalloutSection
            }
            // v0.11 IA — Sign-out + Delete-account moved out of this hub
            // into `SettingsAccountScreen` (Settings → Account). They are
            // account-lifecycle actions, not hub navigation, so they now
            // live next to the profile they govern. The standalone gating
            // (a local install has no server account to sign out of or
            // delete) moved with them.
            hubSection
            // v0.14.8 W2-SYNCUX — canonical sync-status footer (same
            // primitive as Dashboard/Insights). Complements the existing
            // success-haptic so the pull-to-refresh gesture reads
            // identically to the content screens: spinner → tick →
            // caption. Self-suppressing (standalone shows nothing).
            Section {} footer: {
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
        // v0.5.x C-9 — iOS 26+ soft scroll-edge so Form content blurs
        // into the navigation Liquid Glass instead of clipping cleanly.
        // iOS 18-25: no-op (system stays flat-translucent).
        .hlScrollEdgeSoft()
        .navigationTitle("Settings")
        .task {
            // Standalone users have no server profile to fetch —
            // /api/user/profile would 401, which the 401-bridge would
            // interpret as logout. Gate the call.
            if !syncMode.isStandalone, store.profile == nil {
                await store.load()
            }
            await hkReadiness.refresh()
            if aiProviderStore.config == nil { await aiProviderStore.load() }
            await refreshNotificationStatus()
        }
        .refreshable {
            await refresh()
        }
        // POLISH-SWEEP: success-haptic confirms the pull-to-refresh round-trip
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

    /// SET-V2-C (C-6) — first server-load error from the hub's refresh
    /// surfaces. Standalone is suppressed wholesale: `store.load()` is
    /// gated off there (no profile to fetch) and there is no server to
    /// revalidate against, mirroring `HLSyncStatusFooter`'s
    /// self-suppression.
    private var refreshError: HLError? {
        guard !syncMode.isStandalone else { return nil }
        return store.error ?? aiProviderStore.error
    }

    /// Shared pull-to-refresh / banner-retry path — identical to the
    /// pre-C-6 `.refreshable` body so retry and the gesture stay in
    /// lockstep.
    private func refresh() async {
        if !syncMode.isStandalone { await store.load() }
        await hkReadiness.refresh()
        await aiProviderStore.load()
        await refreshNotificationStatus()
        refreshTick &+= 1
    }

    // MARK: - Notifications call-out (v0.6.0.8 Issue #10 fix A)

    /// Top-level recovery card for users who never reached the
    /// onboarding `NotificationsPermissionStep`. Renders only when the
    /// system reports `.notDetermined` or `.denied`; once the user
    /// grants permission the card disappears so it doesn't squat at the
    /// top of Settings forever. Footer copy adapts to the underlying
    /// status so the operator knows exactly what tapping the button
    /// will do.
    private var notificationsCalloutSection: some View {
        Section {
            Button {
                Task { await runNotificationsCalloutAction() }
            } label: {
                HLSettingsRow(
                    icon: "bell.badge.fill",
                    title: notificationsCalloutTitle,
                    subtitle: notificationsCalloutSubtitle
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.notifications.callout")
        } footer: {
            Text(notificationsCalloutFooter)
        }
    }

    private var notificationsCalloutTitle: LocalizedStringKey {
        switch notificationAuthorizationStatus {
        case .denied: "Notifications blocked"
        default: "Enable notifications"
        }
    }

    private var notificationsCalloutSubtitle: LocalizedStringKey {
        switch notificationAuthorizationStatus {
        case .denied: "Re-enable in iOS Settings"
        default: "For medication and mood reminders"
        }
    }

    private var notificationsCalloutFooter: LocalizedStringKey {
        switch notificationAuthorizationStatus {
        case .denied:
            "Without notification permission we can't send you reminders. Tap above to jump straight to iOS Settings."
        default:
            "iOS hasn't shown the permission dialog since login yet. Tap above to open it now."
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

    // MARK: - Standalone Pair-Server (B4-Onboarding)

    /// Pair-later entry-point. Only renders when the user is in standalone
    /// mode — tap drops back into the OnboardingFlow Server branch with
    /// the user's local data intact, so they can convert without re-install.
    private var pairServerSection: some View {
        Section {
            Button {
                authStore.beginServerPairing()
            } label: {
                HLSettingsRow(
                    icon: "icloud.and.arrow.up.fill",
                    title: "Connect to server",
                    subtitle: "Local values are preserved — you will be guided through the server steps."
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.pairServerRow")
        } header: {
            Text("Server connection")
        } footer: {
            Text(
                "In local mode everything runs on this iPhone. With a server you get sync, assistant insights, Health Score, Doctor Report and Coach."
            )
        }
    }

    // MARK: - Hub (usage-frequency order; `api` token-management deferred)

    /// NavigationLink rows for the Settings sub-screens, ordered by iOS
    /// usage frequency (v0.8.0 W7 — no longer web-sidebar parity). The
    /// `thresholds` editor shipped as `TargetEditorSheet` (More → Goals);
    /// only the `api` route (PB26 token-management) stays absent until its
    /// iOS editor ships.
    /// Monochrome icon-chips with the single `Color.accentColor` accent —
    /// per PA2 §17, the rainbow-tinted shape of the v0.4.1 hub was the
    /// dominant "clicky-bunt" signal.
    private var hubSection: some View {
        Section {
            ForEach(HubRow.allCases) { row in
                NavigationLink {
                    row.destination
                } label: {
                    HLSettingsRow(
                        icon: row.icon,
                        title: LocalizedStringKey(row.title),
                        subtitle: row.subtitle.map { LocalizedStringKey($0) }
                    )
                }
                .accessibilityIdentifier(row.accessibilityIdentifier)
            }
        }
    }

    // MARK: - Konto

    //
    // v0.11 IA: Sign-out + Konto-löschen moved out of this hub onto
    // `SettingsAccountScreen` (Settings → Account). They are account-lifecycle
    // actions tied to the profile, so they now live next to it instead of as
    // two trailing sections under the hub navigation rows. The destructive
    // `DeleteAccountScreen` sheet + the standalone gating moved with them.
}

// MARK: - Hub row catalogue

/// Catalogue of the hub rows — name, icon, subtitle (web `description`),
/// destination view, and accessibility identifier in one place so the hub
/// stays declarative.
///
/// v0.8.0 W7 — order is now iOS usage-frequency, not the web sidebar
/// (`section-slugs.ts`) order it used to mirror. HIG favours most-used
/// first: Account, Notifications, Appearance sit above the power-user
/// surface (Sources) and the rarely-touched ones (Privacy & Security,
/// About). v0.11 IA — the `devices` row (BLE device pairing) moved out of
/// this hub into the "Mehr" tab: it is content navigation, not a setting.
/// `serverSync` was promoted out of About's Server card
/// into its own row; `advanced` was renamed to "Privacy & Security" (its
/// enum case + a11y id stay `advanced` for selector stability — same
/// trick `dashboard`→Appearance already uses). The `thresholds` route
/// shipped as `TargetEditorSheet` (More → Goals); the `api` route
/// (PB26 token-management) landed in Build 2 / 2.8 as `apiTokens`, alongside
/// the new `mcp` connector surface (2.7).
/// **Internal, not private, since 17-05.** The hub's row descriptors are a
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
    /// v0.14.10 §3 — Geräte (BLE device pairing) moved BACK into the Settings hub
    /// per operator directive. It sits right after Integrations (Apple Health /
    /// Withings) since "what's connected to my account" reads as one cluster.
    case devices
    /// v0.15 W-SIRI — Siri & Shortcuts discovery surface. Sits after Devices
    /// ("what's connected") and before Source priority: it's about how the OS
    /// reaches the app (voice / Shortcuts / Spotlight), a system-integration
    /// concern adjacent to Integrations and Devices.
    case siri
    /// Build 2 / 2.7 — MCP connector. Sits in the "what's connected to my
    /// account" cluster, right after Siri: it is the surface where a user sees
    /// and cuts an external assistant's live access to their record.
    case mcp
    /// Build 2 / 2.8 — API token management. Directly after MCP; both answer
    /// "which credentials can reach my data". This closes the `api` route the
    /// hub comment below has been holding open since PB26.
    case apiTokens
    case sources
    case ai
    case serverSync
    /// v0.14.7 C1 — `export` moved BACK into the Settings hub. v0.14.1 (#134/FB9)
    /// had relocated it to "Mehr" (grouped with Geräte under "Daten & Geräte"),
    /// but the operator walkthrough reverted that one move: generic
    /// backup/measurements export is a *setting* the user reaches for under
    /// Einstellungen. `SettingsExportScreen` was simultaneously split (C1/C2) — it
    /// now hosts ONLY the generic exports (full JSON/CSV backup + per-domain CSV);
    /// the doctor-handover surfaces (PDF report, FHIR, health-record ZIP, clinician
    /// share-link) regrouped under Mehr → "Mit dem Arzt teilen"
    /// (`UnifiedSharingScreen` since 18-03; `ShareWithDoctor…` in C2).
    case export
    /// v1.35.0 (GH #83) — which pillars count toward the Health Score. Sits
    /// directly beside Modules because both answer "what does the app count
    /// for me"; the distinction the pair has to keep visible is that Modules
    /// says what gets *recorded* and this says what gets *counted*.
    case healthScore
    // #30 (v1.18.0) — per-user feature-module on/off toggles. Sits before
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
        // v0.14.10 §3 — same glyph `SettingsDevicesScreen` uses internally so the
        // hub→detail transition reads continuous.
        case .devices: "dot.radiowaves.left.and.right"
        case .notifications: "bell.fill"
        // v0.6.2.6 E2 — `dashboard` hub-row was relabelled "Aussehen"
        // (operator directive 2026-05-24) so the icon swaps from the
        // grid glyph to `paintpalette.fill`, matching the
        // Personalisierung card icon inside SettingsDashboardScreen so
        // the hub→detail transition reads as one continuous surface.
        // The enum case + accessibility identifier stay `dashboard` so
        // a11y selectors and any future deep-link routes continue to
        // resolve.
        case .dashboard: "paintpalette.fill"
        case .siri: "mic.fill"
        // Build 2 / 2.7–2.8 — the "who can reach my data" pair. `powerplug`
        // matches the web MCP card's plug glyph; `key.fill` matches the web
        // API-token card.
        case .mcp: "powerplug.fill"
        case .apiTokens: "key.fill"
        case .sources: "square.stack.3d.up"
        case .ai: "sparkles"
        // v0.8.0 W7 — Server promoted out of About into its own row.
        // `server.rack` matches the icon `SettingsServerScreen` +
        // About's former server card both used, so the hub→detail
        // transition stays continuous.
        case .serverSync: "server.rack"
        // v0.14.7 C1 — Export back in the hub. The down-arrow tray glyph
        // matches the former `MoreScreen.Layout.exportRow` icon so the
        // hub→`SettingsExportScreen` transition reads continuous.
        case .export: "square.and.arrow.down.fill"
        // GH #83 — same glyph the screen's own card wears, so the hub→detail
        // transition reads continuous.
        case .healthScore: "slider.horizontal.3"
        // #30 — feature-module switchboard.
        case .modules: "square.grid.2x2.fill"
        // v0.8.0 W7 — `advanced` relabelled "Privacy & Security"; the
        // lock-shield glyph matches the screen's own security card and
        // reads as privacy/security at a glance instead of the generic
        // wrench "catch-all" tools metaphor.
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
        // v0.6.2.6 E2 — relabelled from "Dashboard" → "Aussehen" per
        // operator directive 2026-05-24 ("den Bereich Dashboard
        // sollten wir umbenennen in Aussehen oder so und da diese
        // ganzen Sachen, die wir verändern können reinbringen"). The
        // sub-screen already hosts the consolidated visual-config
        // surface (Layout + Erscheinungsbild picker + tile editor) so
        // no rows needed to move — only the label.
        case .dashboard: "Appearance"
        // v0.11 Settings-IA-Restructure — the per-Apple-Health-type sync
        // toggles moved into the dedicated Apple-Health integration sub-page;
        // this hub row is now priority-only (cross-source ladder), so it reads
        // "Source priority". The enum case + a11y id stay `sources` for
        // selector stability (same trick `dashboard`→Appearance uses).
        case .siri: "Siri & Shortcuts"
        case .mcp: "MCP connector"
        case .apiTokens: "API tokens"
        case .sources: "Source priority"
        // v0.8.0 W7 — relabelled "Assistant & Insights" → "Assistant".
        // The Insights-tile customization moved to Appearance (a layout
        // concern), so the screen now owns only the assistant
        // provider/chain config + on-device trend toggle + Coach.
        case .ai: "Assistant"
        case .serverSync: "Server & sync"
        // v0.14.7 C1 — Export back in the hub (generic backup + per-domain CSV).
        case .export: "Export"
        // GH #83 — which pillars carry the composite.
        case .healthScore: "Health Score"
        // #30 — feature-module switchboard.
        case .modules: "Modules"
        // v0.8.0 W7 — relabelled "Advanced" → "Privacy & Security". Its
        // remaining content (audit log, LOINC review, biometric lock,
        // delete account) is exactly privacy/security; "Advanced" was a
        // catch-all that collided with the old root Security section.
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
    /// Trennzeichen**, kein Schlusspunkt, `lineLimit(1)` unverändert. Der
    /// Mittelpunkt ist raus (Betreiber-Urteil: wirkt KI-generiert). Jede Zeile
    /// ist Katalog-Inhalt — rohe Literale gibt es hier nicht mehr.
    ///
    /// **Prüfung:** `SettingsSubtitleTests` (E12) hält die Regel über
    /// `HubRow.allCases`, in beiden Sprachen.
    var subtitle: String? {
        switch self {
        case .account: "Profile, passkeys"
        // 17-05 — was the raw literal "Apple Health · Withings": uncatalogued,
        // middle-dotted, and only naming two of the four providers the screen
        // hosts. Catalogued, comma-separated and complete.
        case .integrations: "Apple Health, Withings, WHOOP, Oura"
        // 17-05 (R5-A1) — the five U7 nils, written. Each names what the screen
        // behind it actually contains, checked against that screen rather than
        // guessed: R7 outranks brevity.
        case .devices: "Paired devices, add new"
        case .notifications: "Reminders, channels, delivery"
        case .dashboard: "Tiles, rings, Insights layout"
        case .siri: "Voice logging, phrases, automations"
        case .mcp: "Connected assistants, tokens"
        case .apiTokens: "See and revoke API access"
        case .sources: "Which source wins per metric"
        // v0.8.0 W7 — Insights customization moved to Appearance, so the
        // subtitle no longer promises tile customization here.
        case .ai: "On-device coach, trend hints, AI provider"
        case .serverSync: "Connection, region, server version"
        // v0.14.7 C1 — generic exports only; the doctor-handover surfaces
        // moved to Mehr → "Mit dem Arzt teilen" (C2).
        case .export: "Full backup, CSV per area"
        // R5 — bleibt: grenzt ein statt umzuformulieren. „Health Score" allein
        // sagt nicht, dass hinter der Zeile eine Auswahl liegt und keine
        // Anzeige des Werts.
        case .healthScore: "Which pillars count"
        case .modules: "Which features are on"
        // v0.8.0 W7 N5 — was "Sicherheit · Audit", which both leaked raw
        // German and collided with the old root Security section. The
        // screen is now the canonical privacy/security home.
        case .advanced: "Biometric lock, clinical mappings"
        // R7 — deliberately does NOT promise a licence card: the screen has
        // the app card, the two links and the update note, and nothing else.
        case .about: "Version, privacy policy, docs"
        }
    }

    var accessibilityIdentifier: String {
        "settings.hub.\(rawValue)"
    }

    /// v0.13 W3 — `@MainActor` because some destinations (e.g. `SettingsAIScreen`)
    /// now hold `@Environment` properties whose default values are main-actor
    /// isolated, making their synthesized `init()` main-actor isolated. The only
    /// consumer is `hubSection` inside a View body (already on the main actor).
    @ViewBuilder @MainActor
    var destination: some View {
        switch self {
        case .account: SettingsAccountScreen()
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
