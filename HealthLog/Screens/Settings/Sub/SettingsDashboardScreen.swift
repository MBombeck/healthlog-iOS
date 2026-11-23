import SwiftUI

/// `/settings/aussehen` — Aussehen (relabelled from "Dashboard" in
/// v0.6.2.6 E2 per operator directive 2026-05-24). Mirrors
/// `dashboard-section.tsx` (which delegates to
/// `dashboard-layout-section.tsx`). On iOS the equivalent surface
/// already lives in `DashboardCustomizationScreen`, so this hub-routed
/// screen embeds it directly under a card frame plus a
/// personalisation-focused section that owns the iOS-only
/// Erscheinungsbild + Dashboard-Layout-Style settings.
///
/// **v0.6.2.6 E2 rename:** the hub-row + page title moved from
/// "Dashboard" → "Aussehen" because the page consolidates everything
/// the operator can *change about how the app looks* — Layout-Dichte,
/// Erscheinungsbild (Light / Dark / System), and the Dashboard-tile
/// editor. The struct name + sub-route slug stay `SettingsDashboard*`
/// for source-level continuity and to keep `settings.hub.dashboard`
/// accessibility identifiers stable for any test or deep-link that
/// resolves them.
///
/// **v0.6.1 accent-picker deprecation:** the eight-swatch
/// `HLTint`-picker was removed when the app moved to a monochrome
/// design language with signal colours only. Light / Dark still
/// follows the system or the explicit Erscheinungsbild pick; the
/// `hl.settings.tint` UserDefaults key keeps its persisted value for
/// forward-compatibility but is no longer read by view code that
/// renders chrome. See `Tokens.swift` `HLTint` for the now-legacy
/// enum and `Stores/SettingsStore.swift` for the persisted property.
struct SettingsDashboardScreen: View {
    // The hero score-ring picker moved here from the dashboard (only the
    // ENTRY POINT moved; selection still persists via the widgets PUT).
    @Environment(DashboardLayoutStore.self) private var layoutStore
    @State private var showHeroRings = false
    // The Today hero-item picker lives on the same screen as the ring
    // picker: both answer "what shows at the top of Today", and both persist
    // through the same widgets PUT.
    @State private var showHeroItems = false

    var body: some View {
        HLPage {
            SettingsPersonalizationCard()
            // The Units card moved OUT of Appearance into the
            // PROFILE area (`SettingsAccountScreen`). Display units (kg/lb,
            // mmHg, mg/dL) are a personal-preference attribute of the user, not
            // a look-and-feel setting, so they belong next to the profile.
            customizeCard
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showHeroRings) {
            ScoreRingSelectionSheet(
                initialSelection: layoutStore.selectedScoreRings,
                initialOrder: layoutStore.heroRingOrder
            ) { chosen, order in
                Task { await layoutStore.setScoreRings(selected: chosen, heroOrder: order) }
            }
            .hlSheetPresentation(.standard)
        }
        .sheet(isPresented: $showHeroItems) {
            HeroItemKindSelectionSheet(
                initialSelection: layoutStore.enabledHeroItemKinds
            ) { chosen in
                Task { await layoutStore.setEnabledHeroItemKinds(chosen) }
            }
        }
        .task {
            // Cheap on hot launch (SWR returns cache); ensures the picker
            // pre-selects the current selection on a deep-link entry.
            await layoutStore.load()
        }
    }

    /// Everything this page lets the person arrange, as rows of one card:
    /// four cards with one row each read like four topics. Each row names
    /// its screen or sheet with the word that screen uses for itself, and
    /// keeps a detail line only where it says a limit or a place (rings: up
    /// to three, for the Insights; highlights: what fills "Worth a look").
    private var customizeCard: some View {
        HLCard("settings.appearance.customize.title", layout: .rows) {
            HLSettingsActionRow(title: "settings.appearance.dashboardTiles", presents: .push) {
                DashboardCustomizationScreen()
            }
            .accessibilityIdentifier("settings.dashboard.customizeRow")
            HLSettingsActionRow(
                title: "Score rings",
                subtitle: "settings.dashboard.heroRings.subtitle",
                presents: .sheet
            ) {
                showHeroRings = true
            }
            .accessibilityIdentifier("settings.dashboard.heroRingsRow")
            HLSettingsActionRow(
                title: "Today highlights",
                subtitle: "settings.dashboard.heroItems.subtitle",
                presents: .sheet
            ) {
                showHeroItems = true
            }
            .accessibilityIdentifier("settings.dashboard.heroItemsRow")
            HLSettingsActionRow(title: "settings.appearance.insightsTabs", presents: .push) {
                SettingsInsightsCustomizationScreen()
            }
            .accessibilityIdentifier("settings.dashboard.insightsCustomizeRow")
        }
    }
}

/// **#13 (2026-06-11).** The Personalization card (Appearance /
/// Compliance-heatmap pickers), extracted from `SettingsDashboardScreen` into
/// its own internal view so the render-verify harness
/// (`ComplianceHeatmapWindowScreenshotGenerator`) can rasterise the REAL
/// shipped rows via `ImageRenderer` — scroll-hosted pages paint empty there.
/// Behaviour and chrome are byte-identical to the prior inline card.
struct SettingsPersonalizationCard: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        HLCard("Personalization") {
            // The page is already called Appearance; the row says what it picks.
            stackedPickerRow(
                label: "settings.dashboard.colorScheme",
                identifier: "settings.dashboard.appearancePicker"
            ) {
                Picker(String(localized: "settings.dashboard.colorScheme"), selection: bindable(\.appearance)) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.label)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // Compliance-heatmap window length. Lives here because the
            // heatmap footprint is a look-and-feel concern (how much history
            // the Medications/Insights grid paints), matching the operator's
            // "Settings → Erscheinungsbild" placement ask. Monochrome menu
            // picker, same row chrome as Layout/Appearance above.
            stackedPickerRow(
                label: "Compliance heatmap",
                identifier: "settings.dashboard.complianceHeatmapWeeksPicker"
            ) {
                Picker(
                    String(localized: "Compliance heatmap"),
                    selection: bindable(\.complianceHeatmapWeeks)
                ) {
                    ForEach(ComplianceHeatmapWeeks.allCases) { option in
                        Text("\(option.rawValue) weeks").tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // W-B187 (Settings consolidation §A.1) — the time-format picker
            // (auto / 24h / 12h) moved OUT of Appearance into the PROFILE editor
            // (`EditProfileScreen`). It is server-backed (`User.timeFormat`) and a
            // personal attribute (how the user reads clocks), not a look-and-feel
            // choice, so it belongs next to the profile. Appearance is now purely
            // layout + light/dark + heatmap + tiles.
        }
    }

    // MARK: - Helpers

    private func stackedPickerRow(
        label: LocalizedStringKey,
        identifier: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let control = content()
        // At the accessibility sizes the picker moves under its label:
        // beside it, „Dunkel" broke into „Du / n- / kel" and ran into the
        // row below.
        return HLAdaptiveStack(alignment: .firstTextBaseline) { stacked in
            Text(label)
                .hlText(.rowTitle)
                .fixedSize(horizontal: false, vertical: true)
            if !stacked {
                Spacer(minLength: HLSpace.md)
            }
            control
        }
        .accessibilityIdentifier(identifier)
    }

    private func bindable<T>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        Binding(get: { store[keyPath: keyPath] }, set: { store[keyPath: keyPath] = $0 })
    }
}
