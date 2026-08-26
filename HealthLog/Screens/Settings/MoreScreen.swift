import SwiftUI

/// "Mehr" tab — **W1-6 flatten per R5 #3 + v0.6.1.5 Y5 Sicherheit section.**
///
/// Was: an Apple-Health-style Browse grid (5 rainbow-tinted 44pt-icon
/// tiles in 4 sections, with a searchable bar on the navigation
/// drawer + its own NavigationStack nested under the shell's). R5
/// identified this as architecturally over-engineered for 5
/// destinations — operator quote: "wenn ich auf mehr klicke, das ist
/// irgendwie komisch".
///
/// Now: a plain `List` of `NavigationLink` rows using
/// `HLSettingsRow` — same row primitive Settings hub uses, so "Mehr"
/// reads as a peer of Settings rather than a separate world.
///
/// - **No** searchable bar (5 destinations doesn't need one).
/// - **No** rainbow tile tints — single purple accent on every chip,
///   matching the Settings-hub monochrome rule.
/// - **No** nested NavigationStack — `AuthenticatedShell.TabView`
///   provides the navigation container per tab.
struct MoreScreen: View {
    @Environment(AppRouter.self) private var router
    /// v0.14.8 C5 — read the cycle gate so the women-only "Cycle" content row is
    /// only ever built when `CycleGate.isCycleTrackingAvailable` (hard-gated
    /// behind `FeatureFlag.cycleTracking`). An ineligible / opted-out user never
    /// sees the row, so `CycleScreen` is unreachable for them by construction.
    @Environment(\.appContainer) private var container

    // v0.5.5 — local binding driving the gear-button-triggered push to
    // SettingsScreen. Mirrors the Dashboard-avatar pattern (see
    // `DashboardProfileToolbar.swift`): plain `Button` flips this binding,
    // a sibling `.navigationDestination(isPresented:)` resolves the push,
    // SwiftUI's back-swipe / back-button flips it back to `false` without
    // an extra observer. We deliberately avoid `NavigationLink` here because
    // its row-style label rendering re-introduces a chevron + tap-area
    // expansion the operator screenshot flagged on v0.5.4.2.
    @State private var showSettings = false

    /// v0.14.8 (Task D) — binding driving the share-glyph-triggered push to
    /// `UnifiedSharingScreen`. Mirrors `showSettings` exactly: a bare `Button`
    /// in `MoreHeader` flips this, a sibling `.navigationDestination(isPresented:)`
    /// at the NavigationStack root resolves the push (no NavigationLink, no
    /// chevron). The "Mit dem Arzt teilen" list row was removed in favour of the
    /// header share glyph (left of the gear) per operator directive.
    @State private var showShareWithDoctor = false

    // v0.6.1.10 Y9-C — Sicherheit section relocated to SettingsScreen
    // per operator walkthrough on 2026-05-23: "Abmelden und Konto
    // löschen gehört unter Einstellungen, nicht unter Mehr." The Y5
    // grouping intent (single section, two rows) is preserved; only
    // the host moved. MoreScreen no longer owns the destructive
    // confirmation sheet — SettingsScreen does.

    var body: some View {
        // v0.11 IA — the orphan `MoreRoute.mood` typed-route destination was
        // removed (no UI row reached it; the live mood deep-link routes to
        // quick-entry). Mood logging lives on Erfassen; mood analysis/history
        // moved to Insights, so the former More→Stimmung row was dropped.
        @Bindable var router = router
        return NavigationStack(path: $router.morePath) {
            content
                // v0.5.5 — sibling destination push driven by the
                // gear-button binding (see `showSettings` above + the
                // `MoreHeader` in the List). Lives at the NavigationStack
                // root so the push uses the same stack the typed-route
                // destinations above use; no nested stacks.
                .navigationDestination(isPresented: $showSettings) {
                    SettingsScreen()
                }
                // v0.14.8 (Task D) — sibling destination push driven by the
                // header share-glyph binding (see `showShareWithDoctor` above +
                // the `MoreHeader` in the List). Same stack-root pattern as
                // `showSettings`; lands the operator on the doctor-handover hub.
                .navigationDestination(isPresented: $showShareWithDoctor) {
                    UnifiedSharingScreen()
                }
                // v0.12 W0-1 — typed deep-link destinations on the Mehr stack.
                // The router appends these to `morePath` for
                // `healthlog://personal-records/<id>` and
                // `healthlog://settings/notifications`; before this they
                // dead-ended because no `navigationDestination` consumed them.
                .navigationDestination(for: PersonalRecordRoute.self) { _ in
                    // No per-record detail screen exists — personal records
                    // live in the `PersonalRecordsScreen` list (hero + grid +
                    // streak rail). Land the operator there; the id is
                    // preserved on the route for a future record-detail surface.
                    PersonalRecordsScreen()
                }
                // #42 (v1.27.6) — typed destination for the mental-health
                // check-in. The router appends `MentalWellbeingRoute` to
                // `morePath` when a screening reminder (PHQ9/GAD7/WHO5) is
                // actioned, so a derived screening score routes to the self-check
                // surface instead of a numeric capture form. Same stack the More
                // NavigationLink to `MentalWellbeingScreen` uses.
                .navigationDestination(for: MentalWellbeingRoute.self) { _ in
                    MentalWellbeingScreen()
                }
                // Parity 1.10 — the dead-tap safety net's landing surface. A
                // dashboard tile whose `MetricKind` has no Insights slug used to
                // do nothing at all when tapped; `AppRouter.selectInsightsMetric`
                // now pushes `MeasurementListRoute` here instead, which is the
                // very same values table the Messwerte row below reaches.
                .navigationDestination(for: MeasurementListRoute.self) { route in
                    MeasurementListScreen(kind: route.kind)
                }
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .root:
                        SettingsScreen()
                    case .notifications:
                        // Same destination the Settings hub row pushes
                        // (`HubRow.notifications`). The router pushes
                        // `.root` THEN `.notifications` so the back stack is
                        // Mehr → Settings → Notifications.
                        SettingsNotificationsScreen()
                    case .assistant:
                        // v0.14.1 — Settings → Assistant hub. The router pushes
                        // `.root` THEN `.assistant` (`requestSettingsAssistant()`)
                        // so the Coach's "External AI needs a server provider"
                        // CTA lands the operator where the provider/BYO key is
                        // configured. Same screen the Settings hub `.ai` row pushes.
                        SettingsAIScreen()
                    case .integrations:
                        // Web-parity `TodayHero` — Settings → Integrations. The
                        // router pushes `.root` THEN `.integrations`
                        // (`requestSettingsIntegrations()`) so the daily-digest
                        // rail's `sync.reconnect` action lands where a broken
                        // integration is reconnected. Same screen the Settings hub
                        // integrations row pushes.
                        SettingsIntegrationsScreen()
                    case .appleHealthImport:
                        // CU-37 — Settings → Integrationen → Apple-Health-Import.
                        // The router pushes `.root` THEN `.integrations` THEN
                        // this (`requestAppleHealthImport()`), so the ECG empty
                        // state's "archive import" affordance lands on the one
                        // surface that can actually get an ECG into HealthLog,
                        // with the real IA behind the back button. Same screen
                        // the Apple-Health integration detail row pushes.
                        SettingsAppleHealthImportScreen()
                    case .appleHealthDetail:
                        // GH #74 — Settings → Integrationen → Apple Health. The
                        // router pushes `.root` THEN `.integrations` THEN this
                        // (`requestAppleHealthSettings()`), so the ECG empty
                        // state's "turn the upload on" affordance lands on the
                        // switch itself, with the real IA behind the back
                        // button. Same screen the Integrations list row pushes.
                        AppleHealthIntegrationDetailScreen()
                    }
                }
        }
    }

    private var content: some View {
        List {
            // v0.5.5 — gear-icon moved back to the trailing edge per
            // operator real-device walkthrough. The HP4 attempt at a
            // leading-edge gear (mirroring the Dashboard-avatar rhythm)
            // felt off in hand because the operator's mental model maps
            // "settings = top-right" across iOS — Apple's Health,
            // Fitness, and the system Settings app all park their
            // gear/profile shortcut on the trailing edge of the header.
            // The MoreHeader now reads `[Mehr title] [Spacer] [Gear]`,
            // chevron-free (still a plain `Button` flipping
            // `showSettings`, no `NavigationLink`). The accessibility
            // identifier (`more.toolbar.gear`) stays stable — pinned by
            // `MoreScreenLayoutTests` and the XCUI assertion in
            // `WalkthroughDashboardTest.test_mehr_header_gear_is_right_of_title`.
            MoreHeader(
                showSettings: $showSettings,
                showShareWithDoctor: $showShareWithDoctor,
                showsShareWithDoctor: container?.moduleGate.isEnabled(.doctorReport) != false
            )
            .listRowInsets(EdgeInsets(top: HLSpace.md, leading: HLSpace.lg, bottom: HLSpace.md, trailing: HLSpace.lg))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            // v0.5.1-F5 — merged "Mentale Gesundheit" + "Vitalwerte & Verlauf"
            // into a single section per operator feedback.
            // v0.11 IA — the Trends row (→ `ChartsScreen`) was cut: it was a
            // duplicate per-metric list. Insights is now the single metric hub
            // (tile → `ChartDetailScreen`), with the Dashboard tile as the one
            // shortcut. Stimmung + Erfolge remain as the cohesive surface.
            // v0.11 IA — Stimmung row removed. Mood analysis/history now lives
            // in Insights (the single metric hub); a duplicate More→Stimmung
            // entry pointing at `MoodAnalysisScreen` was redundant. The section
            // now holds only Achievements, so its heading was retitled to match.
            // The legacy `.mood` typed-route deep-link (older notifications) is
            // still consumed elsewhere — only the visible row was dropped.
            // v0.14.1 (#134) — combined section: Persönliche Rekorde + Erfolge
            // grouped together (the operator reads "my best results + my
            // milestones" as one achievement story), followed by Workouts.
            // v0.14.8 C5 — the women-only cycle home (mirror of web `/cycle`):
            // hero ring + phase explainer + calendar + prediction/stats. The
            // CycleGate hides this row for ineligible / opted-out users, and it
            // is hard-gated behind `FeatureFlag.cycleTracking` (default OFF), so
            // nothing surfaces until the feature ships.
            // v0.15 W-FRONTDOORS — the clinical-spine section, mirroring the web
            // nav-model's grouping (Vorsorge · Labs · Illness as peers, Coach as
            // the labeled nav home). These are the four features the web promotes
            // to top-level front doors that iOS previously buried under the gear
            // (Vorsorge) or in the generic "Records & achievements" drawer
            // (Labs/Illness) / had no nav home at all (Coach). Cycle (women-only,
            // gated) joins this clinical group when eligible.
            Section(LocalizedStringKey(Layout.clinicalSectionTitle)) {
                // v1.26 W-ABOUT-ME — "Über mich" leads the clinical spine: one
                // calm home for everything the user records about themselves —
                // the read-only profile basics (name + email + Krankenkasse) and
                // the three re-parented self / medical-history modules (condition
                // journal, allergies, family history). Those three underlying
                // screens + their data wiring are unchanged; only their entry
                // point moved one hop deeper into `AboutMeScreen`. The
                // illness/allergies/family descriptors still live in `Layout`
                // (consumed by the hub), just no longer as direct rows here.
                NavigationLink {
                    AboutMeScreen()
                } label: {
                    HLSettingsRow(
                        icon: Layout.aboutMeRow.icon,
                        title: LocalizedStringKey(Layout.aboutMeRow.title),
                        subtitle: Layout.aboutMeRow.subtitle.map { LocalizedStringKey($0) }
                    )
                }
                .accessibilityIdentifier(Layout.aboutMeRow.accessibilityIdentifier)
                // v0150 design-M2 — row order mirrors the web `NAV_DESTINATIONS`
                // clinical spine EXACTLY (Cycle · Labs · Illness · Vorsorge ·
                // Coach; web's Insights sits between Vorsorge and Coach but is an
                // iOS top-level tab, not a More row, so it is omitted here). The
                // earlier iOS order (Vorsorge-first, Coach last after the gated
                // Cycle row) drifted from web parity; this restores it.
                // v0.14.8 C5 — the women-only cycle home (mirror of web `/cycle`).
                // The CycleGate hides this row for ineligible / opted-out users, and
                // it is hard-gated behind `FeatureFlag.cycleTracking` (default OFF).
                if container?.cycleGate.isCycleTrackingAvailable == true {
                    NavigationLink {
                        CycleScreen()
                    } label: {
                        HLSettingsRow(
                            icon: Layout.cycleRow.icon,
                            title: LocalizedStringKey(Layout.cycleRow.title),
                            subtitle: Layout.cycleRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.cycleRow.accessibilityIdentifier)
                }
                // Build 9 (Server-Prefs) / C7 — the cycle SETTINGS entry, mirroring
                // the web settings row. Gated identically to the cycle home row
                // above (`isCycleTrackingAvailable`: flag ON *and* eligible —
                // opted-in OR female OR HK-female OR server module on). The raw
                // flag defaults TRUE, so gating on it leaked a "Zyklus" row (→ the
                // Apple-Health screen) to every user incl. non-cycle males — a
                // dead end. A non-eligible user who wants to opt in still can, via
                // the opt-in toggle on the Apple-Health integration screen directly.
                if container?.cycleGate.isCycleTrackingAvailable == true {
                    NavigationLink {
                        AppleHealthIntegrationDetailScreen()
                    } label: {
                        HLSettingsRow(
                            icon: Layout.cycleSettingsRow.icon,
                            title: LocalizedStringKey(Layout.cycleSettingsRow.title),
                            subtitle: Layout.cycleSettingsRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.cycleSettingsRow.accessibilityIdentifier)
                }
                // v1.18.1 (#30) — Lab results + biomarker catalog. Gated behind the
                // `labs` server module (default-on). Promoted out of the generic
                // "Records & achievements" drawer into the clinical spine (web parity).
                if container?.moduleGate.isEnabled(.labs) != false {
                    NavigationLink {
                        LabsScreen()
                    } label: {
                        HLSettingsRow(
                            icon: Layout.labsRow.icon,
                            title: LocalizedStringKey(Layout.labsRow.title),
                            subtitle: Layout.labsRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.labsRow.accessibilityIdentifier)
                }
                // v1.18.3 (§1) — illness/condition journal, default-ON.
                // v1.26 W-ABOUT-ME → v1.26.1 W-ABOUT-ME-RECONCILE — briefly
                // re-parented into the "Über mich" hub, then RESTORED here as a
                // direct clinical-spine row next to Labs. The operator clarified
                // the Beschwerden-Tagebuch is an ongoing complaint/symptom LOG,
                // not static self-info, so it does not belong in the hub. The
                // `IllnessJournalScreen` + its `.illness` module gate are
                // unchanged; only the entry point moved back out of the hub.
                if container?.moduleGate.isEnabled(.illness) != false {
                    NavigationLink {
                        IllnessJournalScreen()
                    } label: {
                        HLSettingsRow(
                            icon: Layout.illnessRow.icon,
                            title: LocalizedStringKey(Layout.illnessRow.title),
                            subtitle: Layout.illnessRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.illnessRow.accessibilityIdentifier)
                }
                // Document vault ("Dokumente") — opt-in `inboundDocuments` module
                // (server ships it OFF by default). Same `!= false` gate idiom; the
                // vault self-gates to an enable-CTA if the route 403's mid-flight.
                if container?.moduleGate.isEnabled(.inboundDocuments) != false {
                    NavigationLink {
                        DocumentsScreen()
                    } label: {
                        HLSettingsRow(
                            icon: Layout.documentsRow.icon,
                            title: LocalizedStringKey(Layout.documentsRow.title),
                            subtitle: Layout.documentsRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.documentsRow.accessibilityIdentifier)
                }
                // Build 7.6 (GH #48) — nutrient read/display front door. Opt-in
                // `nutrients` module (server ships it OFF by default). Same
                // default-on `!= false` idiom; the screen self-gates to the
                // enable-in-settings hint if the route 403's mid-flight.
                if container?.moduleGate.isEnabled(.nutrients) != false {
                    NavigationLink {
                        NutrientListScreen()
                    } label: {
                        HLSettingsRow(
                            icon: Layout.nutritionRow.icon,
                            title: LocalizedStringKey(Layout.nutritionRow.title),
                            subtitle: Layout.nutritionRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.nutritionRow.accessibilityIdentifier)
                }
                // Build 7 Item 7.7 — environmental-context front door. Default-ON
                // `environment` module (server v1.29.1). Same `!= false` idiom as
                // the rows above; the screen self-gates to the disabled hint if the
                // `/api/environment` route 403's mid-flight.
                if container?.moduleGate.isEnabled(.environment) != false {
                    NavigationLink {
                        EnvironmentScreen()
                    } label: {
                        HLSettingsRow(
                            icon: Layout.environmentRow.icon,
                            title: LocalizedStringKey(Layout.environmentRow.title),
                            subtitle: Layout.environmentRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.environmentRow.accessibilityIdentifier)
                }
                // v1.25 W-MENTAL-HEALTH — WHO-5 / PHQ-9 / GAD-7 self-assessment.
                // Additive to mood, never a replacement. A More front-door, NOT a
                // per-metric Insights tab and NOT a Coach surface (the score
                // signals are kept off the AI).
                //
                // Build 2 / 2.6 — gated on the `mentalHealth` module. The server
                // grew the key in v1.29.1; until now this row mounted
                // unconditionally and the screen 403'd (`module.disabled`) for
                // anyone who had switched the module off. Same default-on
                // `!= false` idiom as the illness/documents rows above.
                if container?.moduleGate.isEnabled(.mentalHealth) != false {
                    NavigationLink {
                        MentalWellbeingScreen()
                    } label: {
                        HLSettingsRow(
                            icon: Layout.mentalWellbeingRow.icon,
                            title: LocalizedStringKey(Layout.mentalWellbeingRow.title),
                            subtitle: Layout.mentalWellbeingRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.mentalWellbeingRow.accessibilityIdentifier)
                }
                // v0.15 W-FRONTDOORS (GAP 1) — Vorsorge front door. CORE, never
                // module-gated (a reminder can target core vitals weight/BP/pulse
                // or be free-text — gating would orphan reminders the user can
                // still create). The deep path (gear → Notifications → preventive
                // card → Manage) still works; this is the direct front door.
                NavigationLink {
                    MeasurementRemindersScreen()
                } label: {
                    HLSettingsRow(
                        icon: Layout.vorsorgeRow.icon,
                        title: LocalizedStringKey(Layout.vorsorgeRow.title),
                        subtitle: Layout.vorsorgeRow.subtitle.map { LocalizedStringKey($0) }
                    )
                }
                .accessibilityIdentifier(Layout.vorsorgeRow.accessibilityIdentifier)
                // v0152 W-COACH-CLEANUP (C2) — the "Mehr" Coach row was removed.
                // The operator flagged it as a stray coach entry ("das wird auch
                // ein Fehler sein dass die da drin ist") that opened the coach
                // against his External-AI pick. The manual coach entry returns as
                // an inline button on the Insights metric pages (next wave); the
                // proactive nudge still surfaces server-side. Coach settings
                // (Past conversations, memory) stay reachable under Settings →
                // Coach. No More-row coach affordance here.
            }
            Section(LocalizedStringKey(Layout.recordsSectionTitle)) {
                NavigationLink {
                    PersonalRecordsScreen()
                } label: {
                    HLSettingsRow(
                        icon: Layout.personalRecordsRow.icon,
                        title: LocalizedStringKey(Layout.personalRecordsRow.title),
                        subtitle: Layout.personalRecordsRow.subtitle.map { LocalizedStringKey($0) }
                    )
                }
                .accessibilityIdentifier(Layout.personalRecordsRow.accessibilityIdentifier)
                // #30 — gated behind the `achievements` server module.
                if container?.moduleGate.isEnabled(.achievements) != false {
                    NavigationLink {
                        AchievementsScreen()
                    } label: {
                        HLSettingsRow(
                            icon: Layout.achievementsRow.icon,
                            title: LocalizedStringKey(Layout.achievementsRow.title),
                            subtitle: Layout.achievementsRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.achievementsRow.accessibilityIdentifier)
                }
                // #30 — gated behind the `workouts` server module.
                if container?.moduleGate.isEnabled(.workouts) != false {
                    NavigationLink {
                        WorkoutsScreen()
                    } label: {
                        HLSettingsRow(
                            icon: Layout.workoutsRow.icon,
                            title: LocalizedStringKey(Layout.workoutsRow.title),
                            subtitle: Layout.workoutsRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.workoutsRow.accessibilityIdentifier)
                }
                // v0.14.2 (#136) — Messwerte: a metric-type picker that pushes
                // the EXISTING `MeasurementListScreen(kind:)` values table (the
                // Apple-Health-style bucketed list previously only reachable via
                // the chart drill-down). v0.14.8 W2 (Audit §3.c) — folded into
                // this section: after Geräte (v0.14.10 §3) and Export (v0.14.7
                // C1) moved back to the Settings hub, the "Data & devices"
                // section held only this row under a heading that promised
                // devices it no longer had. Browsing one's own results is the
                // same content navigation as records/workouts, so it lives
                // here and the stale section was dropped.
                NavigationLink {
                    MeasurementsPickerScreen()
                } label: {
                    HLSettingsRow(
                        icon: Layout.measurementsRow.icon,
                        title: LocalizedStringKey(Layout.measurementsRow.title),
                        subtitle: Layout.measurementsRow.subtitle.map { LocalizedStringKey($0) }
                    )
                }
                .accessibilityIdentifier(Layout.measurementsRow.accessibilityIdentifier)
                // v0.15 W-FRONTDOORS — Labs + Illness rows were PROMOTED out of
                // this generic "Records & achievements" drawer into the dedicated
                // clinical-spine section above (web parity — they are clinical
                // features, not records footnotes). See `clinicalSectionTitle`.
            }
            // v0.14.8 W2 (Audit §3.c) — the "Data & devices" section was
            // removed: Geräte (v0.14.10 §3) and Export (v0.14.7 C1) moved back
            // to the Settings hub, leaving a one-row section whose title
            // promised devices that lived elsewhere. Its remaining Messwerte
            // row folded into "Records & achievements" above.
            // v0.14.8 (Task D) — the "Mit dem Arzt teilen" LIST section was
            // removed per operator directive: "Ich hätte gerne, dass man das
            // 'Mehr — kann ich mit dem Arzt teilen?' komplett weg hat." The
            // doctor-handover path stays — it is now
            // reached via the share glyph in the `MoreHeader` (left of the gear),
            // mirroring the gear's push mechanism (`showShareWithDoctor` binding
            // + sibling `.navigationDestination(isPresented:)` at the stack root).
            // v0.6.1.5 Y5 — the clinical section (LOINC review row) moved out
            // of MoreScreen into Erweiterte Einstellungen per operator
            // walkthrough on 2026-05-23. 08-06 then removed the feature
            // outright at both ends: the entry row, the destination screen and
            // the registry that backed it are gone, because a name typed on
            // this device never was clinical review. Nothing replaced it here;
            // the pending-review truth lives in `MetricFHIRMapper` and the FHIR
            // export disclaimer, neither of which any local surface can flip.
            //
            // v0.5.4.1 — "App → Einstellungen" row removed. The gear-icon
            // toolbar trailing item (NF-2) is the canonical entry point to
            // SettingsScreen now. Operator quote on walkthrough: "unter
            // Mehr gibt's jetzt oben rechts. Die Einstellung finde ich
            // super dann brauchen wir die unten nicht mehr." v0.8.0 W7 G3
            // dropped the now-dead `appRows` / `settingsRow` /
            // `clinicalSectionTitle` / `appSectionTitle` descriptors.

            // v0.6.1.10 Y9-C — Sicherheit section moved to SettingsScreen.
            // Pre-Y9 lived here at the bottom of MoreScreen (per Y5);
            // operator walkthrough on 2026-05-23 asked us to host the
            // two destructive rows under Einstellungen instead so the
            // Mehr tab stays focussed on content navigation. The row
            // descriptors (`Layout.signOutRow`, `Layout.deleteAccountRow`)
            // stay in `Layout` so `SettingsAccountScreen` reads from a single
            // source of truth. v0.17 settings-hygiene — the dead
            // `Layout.sicherheitSectionTitle` + `Layout.sicherheitRows` array
            // (test-only, no production reader) were removed.
        }
        // v0152 W-COACH-CLEANUP (C2) — the Coach-row unread dot was removed
        // alongside the More Coach row, so the on-appear nudge refresh that drove
        // it is gone too. The proactive nudge signal still refreshes app-wide via
        // `AppContainer.scenePhase` foreground (server-authoritative) and will
        // drive the dot on the Insights inline coach entry (next wave).
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
        // v0.5.x C-9 — iOS 26+ soft scroll-edge so List content blurs into
        // the navigation Liquid Glass instead of clipping cleanly.
        // iOS 18-25: no-op (system stays flat-translucent).
        .hlScrollEdgeSoft()
        // v0.5.4.2 — large-title slot replaced by the inline MoreHeader
        // at the top of the List (mirrors DashboardHeader rhythm; the
        // dashboard root also intentionally omits `.navigationTitle`).
        // Pushed children (AchievementsScreen, WorkoutsScreen, ...) still inherit
        // the navigation bar and own their own titles.
    }
}

/// v0.6.1.5 Y5 — inline title row for the Mehr-tab.
///
/// **Layout:** `[Mehr title] [Spacer] [GearButton]`. The gear glyph sits
/// on the trailing edge so the operator's "settings = top-right" mental
/// model carries through — Apple's Health, Fitness, and system Settings
/// app all park their gear/profile shortcut on the trailing edge of the
/// header.
///
/// **Y5 visual update (handbook §3.1 Flavour B):** the round
/// `HLSurface.secondary` backplate + hairline border was removed. The
/// gear now renders as a bare 22pt `HLText.primary` glyph sized to read
/// at the same visual weight as the `Mehr` title next to it — mirroring
/// the `MedicationsHeader` `+` affordance introduced in v0.6.1.3 Y4.1.
/// The 44pt tap target is preserved via `.frame(minWidth/minHeight:)`
/// on the button label.
///
/// **Push mechanism:** plain `Button` flipping the parent's
/// `showSettings` binding, paired with a sibling
/// `.navigationDestination(isPresented:)` at the NavigationStack root.
/// Same affordance the Dashboard-avatar uses (see
/// `DashboardProfileToolbar.swift`) — no NavigationLink, no chevron, no
/// chevron-via-list-row-style inheritance.
///
/// The accessibility identifier (`more.toolbar.gear`) stays stable so
/// `MoreScreenLayoutTests` and the XCUI walkthrough still resolve it.
private struct MoreHeader: View {
    @Binding var showSettings: Bool
    /// v0.14.8 (Task D) — flips the parent's `showShareWithDoctor` push, so the
    /// header share glyph lands on `UnifiedSharingScreen` (the former list-row
    /// destination). Threaded exactly like `showSettings`.
    @Binding var showShareWithDoctor: Bool
    /// #30 — when the `doctorReport` server module is OFF, the header share
    /// glyph (the sole entry to the doctor-handover / FHIR-export hub) is hidden.
    var showsShareWithDoctor: Bool = true

    /// Tap-target footprint — matches the `MedicationsHeader` `+` button
    /// so the two inline-title affordances feel identical in hand. HIG
    /// ≥ 44pt is satisfied without an explicit chrome surface.
    private static let buttonSize: CGFloat = 44

    var body: some View {
        HStack(alignment: .center, spacing: HLSpace.md) {
            Text(LocalizedStringKey(MoreScreen.Layout.navigationTitle))
                .font(.hlLargeTitle)
                .foregroundStyle(HLText.primary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            // v0.14.8 (Task D) — share affordance, sitting immediately LEFT of
            // the gear so the trailing cluster reads `[share] [gear]`. Same bare
            // treatment as the gear (glyph only, .hlTitle2, HLText.primary, 44pt
            // tap target) so the two header affordances feel identical in hand.
            if showsShareWithDoctor {
                Button {
                    showShareWithDoctor = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.hlTitle2)
                        .foregroundStyle(HLText.primary)
                        .frame(width: Self.buttonSize, height: Self.buttonSize)
                        .contentShape(Rectangle())
                        .accessibilityLabel(Text(LocalizedStringKey(MoreScreen.Layout.shareToolbarAccessibilityLabel)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(MoreScreen.Layout.shareToolbarAccessibilityIdentifier)
            }

            Button {
                showSettings = true
            } label: {
                // Y8 M-3: lift the gear glyph off the raw 22pt literal
                // onto .hlTitle2 (22pt @L) so it scales with the
                // .hlLargeTitle title beside it under accessibility
                // text-size pref instead of locking small.
                Image(systemName: "gearshape")
                    .font(.hlTitle2)
                    .foregroundStyle(HLText.primary)
                    .frame(width: Self.buttonSize, height: Self.buttonSize)
                    .contentShape(Rectangle())
                    .accessibilityLabel(Text(LocalizedStringKey(MoreScreen.Layout.gearToolbarAccessibilityLabel)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(MoreScreen.Layout.gearToolbarAccessibilityIdentifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
