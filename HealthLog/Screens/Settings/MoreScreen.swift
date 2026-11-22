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
    /// Read the cycle gate so the women-only "Cycle" content row is
    /// only ever built when `CycleGate.isCycleTrackingAvailable`. An ineligible / opted-out user never
    /// sees the row, so `CycleScreen` is unreachable for them by construction.
    /// 1.0.3 (Task 4b) — widened from `private` to internal: `clinicalSectionRows`
    /// in `MoreScreen+ClinicalSection.swift` reads this from a sibling file.
    @Environment(\.appContainer) var container
    /// The server version the last probe recorded: the timeline row needs 1.42.
    @AppStorage(KnownServerVersion.defaultsKey) private var serverVersion: String?

    // The gear and the share glyph in the tab header are plain
    // `Button`s (no `NavigationLink`, no chevron). #153 follow-up
    // (SET-ROUTE): they append a value to `router.morePath` instead of flipping
    // local `@State`, so the pushed page survives the privacy shield, which
    // rebuilds the window whenever the scene goes inactive.

    // Sicherheit section relocated to SettingsScreen
    // per operator walkthrough on 2026-05-23: "Abmelden und Konto
    // löschen gehört unter Einstellungen, nicht unter Mehr." The Y5
    // grouping intent (single section, two rows) is preserved; only
    // the host moved. MoreScreen no longer owns the destructive
    // confirmation sheet — SettingsScreen does.

    var body: some View {
        // The orphan `MoreRoute.mood` typed-route destination was
        // removed (no UI row reached it; the live mood deep-link routes to
        // quick-entry). Mood logging lives on Erfassen; mood analysis/history
        // moved to Insights, so the former More→Stimmung row was dropped.
        @Bindable var router = router
        return NavigationStack(path: $router.morePath) {
            content
                // The screens behind every More value live in
                // `hlMoreDestinations()`, shared with the sidebar section stacks.
                .hlMoreDestinations()
        }
    }

    /// Whether the list carries the row for `destination`. On a regular-width
    /// window a destination with its own sidebar tab is reached there, so More
    /// lists only what stays here. Compact lists every row, as always.
    func listsRow(for destination: SidebarDestination) -> Bool {
        Self.listsRow(for: destination, in: router.shellLayout)
    }

    /// The rule behind ``listsRow(for:)``: a row stays in More unless its
    /// destination is a sidebar tab in `layout`. The row's own module gate is
    /// checked where the row is built.
    static func listsRow(for destination: SidebarDestination, in layout: ShellLayout) -> Bool {
        !layout.visibleSections.contains(destination)
    }

    /// The share glyph (when the doctor report module is on) and the gear.
    private var barActions: HLTabHeaderActions {
        var items: [HLTabHeaderAction] = []
        if container?.moduleGate.isEnabled(.doctorReport) != false {
            items.append(HLTabHeaderAction(
                role: .share,
                systemImage: "square.and.arrow.up",
                label: LocalizedStringKey(Layout.shareToolbarAccessibilityLabel),
                identifier: Layout.shareToolbarAccessibilityIdentifier,
                isSelected: false,
                kind: .button { router.morePath.append(MoreRoute.shareWithDoctor) }
            ))
        }
        items.append(HLTabHeaderAction(
            role: .more,
            systemImage: "gearshape",
            label: LocalizedStringKey(Layout.gearToolbarAccessibilityLabel),
            identifier: Layout.gearToolbarAccessibilityIdentifier,
            isSelected: false,
            kind: .button { router.morePath.append(SettingsRoute.root) }
        ))
        return HLTabHeaderActions(items)
    }

    private var content: some View {
        List {
            // Gear-icon moved back to the trailing edge per
            // operator real-device walkthrough. The HP4 attempt at a
            // leading-edge gear (mirroring the Dashboard-avatar rhythm)
            // felt off in hand because the operator's mental model maps
            // "settings = top-right" across iOS — Apple's Health,
            // Fitness, and the system Settings app all park their
            // gear/profile shortcut on the trailing edge of the header.
            // The tab header now reads `[Mehr title] [Spacer] [Gear]`,
            // chevron-free (still a plain `Button` flipping
            // `openSettings`, no `NavigationLink`). The accessibility
            // identifier (`more.toolbar.gear`) stays stable — pinned by
            // `MoreScreenLayoutTests` and the XCUI assertion in
            // `WalkthroughDashboardTest.test_mehr_header_gear_is_right_of_title`.
            // The share glyph and the gear stand beside the title on a phone
            // and in the system bar in a regular width, as on every tab.
            HLTabHeader(
                LocalizedStringResource(String.LocalizationValue(Layout.navigationTitle)),
                actions: barActions
            )
            .hlTabHeaderListRow()
            // Merged "Mentale Gesundheit" + "Vitalwerte & Verlauf"
            // into a single section per operator feedback.
            // The Trends row (→ `ChartsScreen`) was cut: it was a
            // duplicate per-metric list. Insights is now the single metric hub
            // (tile → `ChartDetailScreen`), with the Dashboard tile as the one
            // shortcut. Stimmung + Erfolge remain as the cohesive surface.
            // Stimmung row removed. Mood analysis/history now lives
            // in Insights (the single metric hub); a duplicate More→Stimmung
            // entry pointing at `MoodAnalysisScreen` was redundant. The section
            // now holds only Achievements, so its heading was retitled to match.
            // The legacy `.mood` typed-route deep-link (older notifications) is
            // still consumed elsewhere — only the visible row was dropped.
            // Combined section: Persönliche Rekorde + Erfolge
            // grouped together (the operator reads "my best results + my
            // milestones" as one achievement story), followed by Workouts.
            // The women-only cycle home (mirror of web `/cycle`):
            // hero ring + phase explainer + calendar + prediction/stats. The
            // CycleGate hides this row for ineligible / opted-out users.
            // The clinical-spine section, mirroring the web
            // nav-model's grouping (Vorsorge · Labs · Illness as peers, Coach as
            // the labeled nav home). These are the four features the web promotes
            // to top-level front doors that iOS previously buried under the gear
            // (Vorsorge) or in the generic "Records & achievements" drawer
            // (Labs/Illness) / had no nav home at all (Coach). Cycle (women-only,
            // gated) joins this clinical group when eligible.
            Section {
                clinicalSectionRows
            } header: {
                HLSectionHeader(LocalizedStringKey(Layout.clinicalSectionTitle))
            }
            .hlFormRowSurface()
            Section {
                if TimelineRepository.isTimelineAvailable(serverVersion: serverVersion), listsRow(for: .timeline) {
                    NavigationLink(value: MoreRoute.timeline) {
                        HLSettingsRow(
                            icon: Layout.timelineRow.icon,
                            title: LocalizedStringKey(Layout.timelineRow.title),
                            subtitle: Layout.timelineRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.timelineRow.accessibilityIdentifier)
                    // The person's opening, which turns a phone across, is
                    // noted by the router when this value lands on the stack
                    // (`AppRouter.morePath`). A second tap gesture here fought
                    // the row's own tap on a device: it opened only after
                    // several taps.
                }
                NavigationLink(value: MoreRoute.personalRecords) {
                    HLSettingsRow(
                        icon: Layout.personalRecordsRow.icon,
                        title: LocalizedStringKey(Layout.personalRecordsRow.title),
                        subtitle: Layout.personalRecordsRow.subtitle.map { LocalizedStringKey($0) }
                    )
                }
                .accessibilityIdentifier(Layout.personalRecordsRow.accessibilityIdentifier)
                // Gated behind the `achievements` server module.
                if container?.moduleGate.isEnabled(.achievements) != false {
                    NavigationLink(value: MoreRoute.achievements) {
                        HLSettingsRow(
                            icon: Layout.achievementsRow.icon,
                            title: LocalizedStringKey(Layout.achievementsRow.title),
                            subtitle: Layout.achievementsRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.achievementsRow.accessibilityIdentifier)
                }
                // Gated behind the `workouts` server module.
                if container?.moduleGate.isEnabled(.workouts) != false, listsRow(for: .workouts) {
                    NavigationLink(value: MoreRoute.workouts) {
                        HLSettingsRow(
                            icon: Layout.workoutsRow.icon,
                            title: LocalizedStringKey(Layout.workoutsRow.title),
                            subtitle: Layout.workoutsRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.workoutsRow.accessibilityIdentifier)
                }
                // Messwerte: a metric-type picker that pushes the
                // `MeasurementListScreen(kind:)` values table. Browsing one's
                // own results is the same content navigation as records and
                // workouts, so it lives in this section.
                if listsRow(for: .measurements) {
                    NavigationLink(value: MoreRoute.measurements) {
                        HLSettingsRow(
                            icon: Layout.measurementsRow.icon,
                            title: LocalizedStringKey(Layout.measurementsRow.title),
                            subtitle: Layout.measurementsRow.subtitle.map { LocalizedStringKey($0) }
                        )
                    }
                    .accessibilityIdentifier(Layout.measurementsRow.accessibilityIdentifier)
                }
                // Labs and Illness live in the clinical section above: they are
                // clinical features, not records footnotes.
            } header: {
                HLSectionHeader(LocalizedStringKey(Layout.recordsSectionTitle))
            }
            .hlFormRowSurface()
            // The Mehr tab is content navigation only. The doctor handover is
            // the share glyph in the tab header (left of the gear), pushed through
            // `showShareWithDoctor` from the stack root; settings and the two
            // destructive account rows sit behind the gear. Their descriptors
            // (`Layout.signOutRow`, `Layout.deleteAccountRow`) stay in `Layout`
            // so `SettingsAccountScreen` reads from a single source of truth.
        }
        .hlPageMargins()
        // In a regular width the tab's actions stand in the system bar: the
        // doctor handover, then the gear at the trailing edge. Both push onto
        // the More stack.
        .hlTabRootBarActions(barActions)
        // The inline tab header at the top of the List takes the large-title
        // slot (as DashboardHeader does; the dashboard root also omits
        // `.navigationTitle`). Pushed children still own their titles.
    }
}
