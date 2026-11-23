import SwiftUI

extension View {
    /// The screens behind every value the More stack can hold.
    ///
    /// One registration set for each stack that hosts More content: the More
    /// tab itself and, on a regular-width window, every sidebar section tab.
    /// A value pushed by a row, a header glyph or the router resolves to the
    /// same screen on whichever of those stacks it lands.
    func hlMoreDestinations() -> some View {
        modifier(MoreDestinations())
    }
}

/// The six `navigationDestination` registrations behind `hlMoreDestinations()`.
private struct MoreDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content
            // #153 follow-up — the Settings hub rows push
            // their `HubRow` as a value, so the stack in the container's
            // router remembers them across the privacy shield.
            .navigationDestination(for: HubRow.self) { row in
                row.destination
            }
            // The rows of the More list and the header share glyph, as values
            // for the same reason (`MoreRoute`).
            .navigationDestination(for: MoreRoute.self) { route in
                MoreRouteDestination(route: route)
            }
            // Typed deep-link destinations on the Mehr stack.
            // The router appends these to `morePath` for
            // `healthlog://personal-records/<id>` and
            // `healthlog://settings/notifications`; before this they
            // dead-ended because no `navigationDestination` consumed them.
            .navigationDestination(for: PersonalRecordRoute.self) { route in
                // No per-record detail screen exists — personal records
                // live in the `PersonalRecordsScreen` list (hero + grid +
                // streak rail). The list scrolls to the linked record.
                PersonalRecordsScreen(focusedRecordID: route.id)
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
            // The dead-tap safety net's landing surface. A
            // dashboard tile whose `MetricKind` has no Insights slug used to
            // do nothing at all when tapped; `AppRouter.selectInsightsMetric`
            // now pushes `MeasurementListRoute` here instead, which is the
            // very same values table the Messwerte row reaches.
            .navigationDestination(for: MeasurementListRoute.self) { route in
                MeasurementListScreen(kind: route.kind)
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                SettingsRouteDestination(route: route)
            }
    }
}

/// #153 follow-up — the screen behind each `MoreRoute`
/// value. The rows push values instead of views so the page they open comes
/// back after the privacy shield rebuilt the window.
struct MoreRouteDestination: View {
    let route: MoreRoute

    var body: some View {
        switch route {
        case .shareWithDoctor: UnifiedSharingScreen()
        case .aboutMe, .lifeCircumstances: AboutMeRouteDestination(route: route)
        case .labs: LabsScreen()
        case .illness: IllnessJournalScreen()
        case .seizures: SeizuresScreen()
        case .documents: DocumentsScreen()
        case .nutrients: NutrientListScreen()
        case .environment: EnvironmentScreen()
        case .medicalSources: MedicalSourcesScreen()
        case .personalRecords: PersonalRecordsScreen()
        case .achievements: AchievementsScreen()
        case .workouts: WorkoutsScreen()
        case .measurements: MeasurementsPickerScreen()
        case .timeline: TimelineScreen()
        }
    }
}

/// The screen behind each `SettingsRoute` value on a More-content stack.
private struct SettingsRouteDestination: View {
    let route: SettingsRoute

    var body: some View {
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
            // Settings → Assistant hub. The router pushes
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
            // Settings → Integrationen → Apple-Health-Import.
            // The router pushes `.root` THEN `.integrations` THEN
            // this (`requestAppleHealthImport()`), so the ECG empty
            // state's "archive import" affordance lands on the one
            // surface that can actually get an ECG into HealthLog,
            // with the real IA behind the back button. Same screen
            // the Apple-Health integration detail row pushes.
            SettingsAppleHealthImportScreen()
        case .appleHealthDetail:
            // Settings → Integrationen → Apple Health. The
            // router pushes `.root` THEN `.integrations` THEN this
            // (`requestAppleHealthSettings()`), so the ECG empty
            // state's "turn the upload on" affordance lands on the
            // switch itself, with the real IA behind the back
            // button. Same screen the Integrations list row pushes.
            AppleHealthIntegrationDetailScreen()
        case .security:
            // A security alert's push lands here, the same
            // screen Account pushes. On the More
            // stack its rows push values.
            SettingsSecurityScreen(routesByValue: true)
        case .checkups:
            // The push path `/checkups`: Vorsorge, the
            // same screen the clinical-spine row links to.
            MeasurementRemindersScreen()
        case .cycle:
            // The push path `/cycle`, the same screen the
            // cycle row links to.
            CycleScreen()
        case .serverAccessHeaders:
            // #153 follow-up — Settings › Server › Access
            // headers, pushed as a value by `SettingsServerScreen`.
            ServerAccessHeadersScreen()
        case .sessions:
            SessionsScreen()
        case .passkeys:
            PasskeyManagementScreen()
        case .twoFactor:
            TwoFactorManagementScreen()
        case let .integration(provider):
            IntegrationRouteDestination(route: provider)
        }
    }
}

/// The root screen of a sidebar tab: the screen its More row opens.
struct SidebarDestinationScreen: View {
    let destination: SidebarDestination

    var body: some View {
        switch destination {
        case .timeline: MoreRouteDestination(route: .timeline)
        case .measurements: MoreRouteDestination(route: .measurements)
        case .illness: MoreRouteDestination(route: .illness)
        case .seizures: MoreRouteDestination(route: .seizures)
        case .cycle: CycleScreen()
        case .mentalWellbeing: MentalWellbeingScreen()
        case .workouts: MoreRouteDestination(route: .workouts)
        case .labs: MoreRouteDestination(route: .labs)
        case .documents: MoreRouteDestination(route: .documents)
        case .checkups: MeasurementRemindersScreen()
        case .medicalSources: MoreRouteDestination(route: .medicalSources)
        }
    }
}
