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
    // v0141 — the hero score-ring picker moved here from the dashboard (only the
    // ENTRY POINT moved; selection still persists via the widgets PUT).
    @Environment(DashboardLayoutStore.self) private var layoutStore
    @State private var showHeroRings = false
    // CU-34 — the Today hero-item picker lives on the same screen as the ring
    // picker: both answer "what shows at the top of Today", and both persist
    // through the same widgets PUT.
    @State private var showHeroItems = false

    var body: some View {
        HLSettingsPage(title: "Appearance") {
            SettingsPersonalizationCard()
            // v0.14.1 (#134) — the Units card moved OUT of Appearance into the
            // PROFILE area (`SettingsAccountScreen`). Display units (kg/lb,
            // mmHg, mg/dL) are a personal-preference attribute of the user, not
            // a look-and-feel setting, so they belong next to the profile.
            layoutCard
            heroRingsCard
            heroItemsCard
            insightsCustomizationCard
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
            .presentationBackground(HLColor.surface)
        }
        .sheet(isPresented: $showHeroItems) {
            HeroItemKindSelectionSheet(
                initialSelection: layoutStore.enabledHeroItemKinds
            ) { chosen in
                Task { await layoutStore.setEnabledHeroItemKinds(chosen) }
            }
            .hlSheetPresentation(.standard)
            .presentationBackground(HLColor.surface)
        }
        .task {
            // Cheap on hot launch (SWR returns cache); ensures the picker
            // pre-selects the current selection on a deep-link entry.
            await layoutStore.load()
        }
    }

    /// UI-Standard R1/R2 — der Karten-Subtitle ist gefallen. Er sagte
    /// „Standard: alle Kacheln sichtbar. Hier ausblenden oder umsortieren." —
    /// eine Voreinstellungs-Ansage plus eine Bedien-Nacherzählung, beide auf
    /// der R2-Verbotsliste. Die Zielseite zeigt „Angeheftet"/„Ausgeblendet"
    /// als eigene Abschnitte und trägt die Aussage damit zustandsabhängig (R3).
    private var layoutCard: some View {
        HLSettingsCard(
            icon: "square.grid.2x2",
            title: "Customize tiles"
        ) {
            HLSettingsActionRow(title: "Open tile layout", presents: .push) {
                DashboardCustomizationScreen()
            }
            .accessibilityIdentifier("settings.dashboard.customizeRow")
        }
    }

    /// Score-ring picker entry. Opens the shared ``ScoreRingSelectionSheet``;
    /// the choice persists via `DashboardLayoutStore.setScoreRings(...)`
    /// (widgets PUT).
    ///
    /// **Parity Build 4 · 4.3 — copy fix.** This card used to be titled "Hero
    /// rings" and promised the scores would appear "at the top of your
    /// dashboard". That surface no longer exists as described: the rings render
    /// on the dashboard hero AND (new in Build 4) drive the Insights score
    /// cards, and the picker now also sets their ORDER. The old copy sold a
    /// destination the user could not find, which is why the setting read as
    /// doing nothing. The title/subtitle now name both surfaces honestly.
    ///
    /// **UI-Standard R2 — dieser Subtitle bleibt bewusst stehen.** Er trägt
    /// eine harte Grenze („bis zu drei") und eine nicht sichtbare Folge (die
    /// Auswahl wirkt auf Startseite *und* Insights). Beides sind
    /// R2-Kategorien, keine Umformulierung des Titels.
    private var heroRingsCard: some View {
        HLSettingsCard(
            icon: "circle.hexagongrid",
            title: "Score rings",
            subtitle: "Pick up to three scores and their order. They appear on your dashboard and in Insights."
        ) {
            // R10 — die Zeile öffnet ein Sheet, also `pencil` statt Chevron.
            HLSettingsActionRow(title: "Choose score rings", presents: .sheet) {
                showHeroRings = true
            }
            .accessibilityIdentifier("settings.dashboard.heroRingsRow")
        }
    }

    /// **CU-34 (Brief C6) — the Today hero-item picker entry.** Opens
    /// ``HeroItemKindSelectionSheet``; the choice persists via
    /// `DashboardLayoutStore.setEnabledHeroItemKinds(_:)` (widgets PUT, the
    /// only save that sends `enabledHeroItemKinds`).
    ///
    /// Sits directly under the ring picker because both configure the same
    /// place — the top of Today — and the subtitle names the section heading the
    /// user actually sees there ("Worth a look"), so the setting is findable
    /// from the surface it changes.
    private var heroItemsCard: some View {
        HLSettingsCard(
            icon: "list.star",
            title: "Today highlights",
            subtitle: "Choose which item types can appear under Worth a look on Today."
        ) {
            // R10 — Sheet, also `pencil`. R3: derselbe Satz stand bis U5 auch
            // im Sheet selbst; er lebt jetzt nur noch hier, vor der Entscheidung.
            HLSettingsActionRow(title: "Choose item types", presents: .sheet) {
                showHeroItems = true
            }
            .accessibilityIdentifier("settings.dashboard.heroItemsRow")
        }
    }

    /// v0.8.0 W7 W1/C1 — Insights-tile customization, moved here from
    /// the overloaded "Assistant & Insights" screen. Both the dashboard
    /// tiles (above) and the Insights tiles are "what shows on which
    /// grid" — a display/layout concern that belongs under Appearance,
    /// not next to the server AI provider keys. Pushes the same
    /// `SettingsInsightsCustomizationScreen` destination the AI screen
    /// used; tile state is `@AppStorage`-backed so no store rewiring.
    ///
    /// UI-Standard R2 — der Subtitle („Wähle, welche Insights-Kacheln
    /// erscheinen und in welcher Reihenfolge.") formulierte den Kartentitel um
    /// und ist ersatzlos gefallen.
    private var insightsCustomizationCard: some View {
        HLSettingsCard(
            icon: "rectangle.stack.fill",
            title: "Customize Insights tiles"
        ) {
            HLSettingsActionRow(title: "Open Insights layout", presents: .push) {
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
        HLSettingsCard(
            icon: "paintpalette.fill",
            title: "Personalization"
        ) {
            stackedPickerRow(
                label: "Appearance",
                identifier: "settings.dashboard.appearancePicker"
            ) {
                Picker(String(localized: "Appearance"), selection: bindable(\.appearance)) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.label)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // #13 — compliance-heatmap window length. Lives here because the
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
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.md)
            content()
        }
        .accessibilityIdentifier(identifier)
    }

    private func bindable<T>(_ keyPath: ReferenceWritableKeyPath<SettingsStore, T>) -> Binding<T> {
        Binding(get: { store[keyPath: keyPath] }, set: { store[keyPath: keyPath] = $0 })
    }
}
