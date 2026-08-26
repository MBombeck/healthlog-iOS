import SwiftUI

/// v0.6.1.10 Y9-D2/D3 — operator-facing customization surface for the
/// Insights tile grid. One Toggle row per tile-ID, reorderable via the
/// native `List` `.onMove` (the VoiceOver-correct, Dynamic-Type-correct
/// reorder path that complements the in-grid drag on the Insights screen).
///
/// **v0.8.0 W10 — server-first.** Persistence moved off iOS-local
/// `@AppStorage` onto `/api/insights/layout` via `InsightsLayoutStore`
/// (optimistic write-through + Outbox replay). The visibility toggle flips
/// `visible`; the drag reorders. Both flow to the same store the Insights
/// screen reads, so a change here reflects on the grid on next render.
///
/// **Discovery flow:** Settings → Erweitert → "Insights anpassen" → here,
/// and (new) the Insights header menu → "Customise insights".
///
/// **Catalogue source:** the server layout's tile-id list is the authority.
/// Each row maps its server slug back to a localized label.
struct SettingsInsightsCustomizationScreen: View {
    @Environment(InsightsLayoutStore.self) private var layoutStore
    /// v0141 — per-card hide state for the Insights-overview wellness score
    /// cards (Recovery / Cardio-fitness / … cards a watch-less user can never
    /// fill). Local UI-pref; the toggles below are the "an- und abwählbar"
    /// re-enable surface for cards hidden via the card's long-press action.
    @Environment(WellnessCardVisibilityStore.self) private var cardVisibility
    /// Backs the score-cards list — a card only appears once it is renderable
    /// (has data) or has been explicitly hidden, so the list never shows a card
    /// the operator can't act on.
    @Environment(DerivedInsightsStore.self) private var derivedStore
    /// Parity Build 4 · 4.3 — the server-synced ring selection, which owns the
    /// three score-card ids it covers (see `scoreCardIDs`).
    /// Optional so a preview / render harness mounting this screen outside the
    /// app environment resolves to "no explicit selection" instead of trapping.
    @Environment(DashboardLayoutStore.self) private var dashboardLayoutStore: DashboardLayoutStore?

    var body: some View {
        List {
            tilesSection
            InsightsOverviewSectionsList()
            scoreCardsSection
            footerSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
        // I-3 ITEM 6 — the top-right "Bearbeiten"/EditButton was removed. The
        // visibility toggles persist immediately and `.onMove` drag-reorder works
        // on an always-on inset-grouped List (long-press to lift a row) without
        // an explicit edit mode, so the button was redundant. Reorder + toggle
        // both flow through `InsightsLayoutStore` (server-first + Outbox) exactly
        // as before — nothing depended on the edit-mode flag.
        // W3b B3 — iOS 26+ soft scroll-edge (no-op on iOS 18-25).
        .hlScrollEdgeSoft()
        .navigationTitle("Customize tab strip")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Cold-launch: hydrate the layout so the list isn't empty on a
            // fresh deep link straight into this screen.
            await layoutStore.load()
        }
        .overlay(alignment: .top) {
            ErrorBanner(error: layoutStore.error) {
                Task { await layoutStore.refresh() }
            }
        }
    }

    /// v0.14.1 — the strip-customise rows: every chartable-metric / special-page
    /// tile EXCEPT `overview`. "Übersicht" is the mandatory first pill (rendered
    /// as a pinned, non-interactive header row below) and never appears here, so
    /// it can be neither hidden nor dragged out of the leading position.
    private var orderedTiles: [InsightsLayoutTile] {
        layoutStore.layout.stripCustomizableTiles.filter { tile in
            // Only tabs that can actually render a strip pill: a chartable
            // metric, or one of the three special pages. (e.g. `audio-events`
            // round-trips in the layout but has no pill — hide it from the
            // customise list so the operator never toggles a phantom tab.)
            InsightsTabSlug.metricKind(forSlug: tile.id) != nil
                || InsightsSpecialPage.page(forSlug: tile.id) != nil
        }
    }

    private var tilesSection: some View {
        Section {
            // "Übersicht" — the mandatory, always-first pill. Shown as a pinned
            // info row (no toggle, no drag handle) so the operator sees it is
            // present but cannot hide it or move it off the leading edge.
            overviewPinnedRow
            if orderedTiles.isEmpty {
                Text(String(localized: "No targets loaded yet. Tap Refresh on the Insights page."))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            } else {
                ForEach(orderedTiles) { tile in
                    toggleRow(for: tile)
                }
                .onMove(perform: moveTiles)
            }
        } header: {
            // R12 — Abschnitts-Header eines List-Gerüsts ist der System-Default
            // (roher `Text`, versal). Die eigene Schrift/Tinte ist gefallen.
            Text(String(localized: "Tabs"))
        } footer: {
            // UI-Standard R3/R5 — auf diesem Screen standen drei
            // Mechanik-Footer untereinander, die alle „ziehen zum Sortieren"
            // und „ohne Daten bleibt es ausgeblendet" sagten. Der Satz hat hier
            // seine Heimat und ist auf die zwei nicht sichtbaren Folgen
            // gekürzt: Der einleitende Halbsatz wiederholte den Seitentitel,
            // die Zieh-Anleitung war eine Bedien-Nacherzählung (R2), und
            // „Übersicht bleibt zuerst" steht bereits an der angehefteten
            // Zeile selbst.
            Text(String(
                localized: "Hidden tabs leave the strip and their page. Tabs without data stay hidden even when enabled."
            ))
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
        }
    }

    /// The pinned, non-interactive "Übersicht" row. It carries no toggle and no
    /// drag handle, communicating that the overview tab is mandatory and always
    /// leads the strip.
    private var overviewPinnedRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(label(for: InsightsLayoutTileId.overview))
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                Text(String(localized: "Always shown first."))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
            Spacer()
            Image(systemName: "pin.fill")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
        }
        .moveDisabled(true)
        .accessibilityIdentifier("settings.insights.row.overview.pinned")
    }

    // MARK: - Score cards (v0141 — per-card hide, local UI-pref)

    /// The wellness score cards the operator can act on: renderable now (has
    /// data) OR explicitly hidden. Ordered by the block's canonical card order so
    /// the list mirrors the on-screen grid.
    ///
    /// **Parity Build 4 · 4.3 — one owner per card.** Once the operator has an
    /// EXPLICIT ring selection, the three ids that selection covers
    /// (`READINESS` / `SLEEP_SCORE` / `RECOVERY_SCORE`) are governed by it —
    /// server-synced, visible to web — so they are dropped from this local
    /// hidden-set list. Two controls for one card, one of them invisible to the
    /// other client, is exactly the duplication this build removes.
    private var scoreCardIDs: [String] {
        let governed = dashboardLayoutStore?.hasExplicitScoreRingSelection == true
            ? InsightsScoreCardResolution.selectionGovernedIDs(
                catalogue: InsightsScoreCardsBlock.hideableCardOrder
            )
            : []
        return InsightsScoreCardsBlock.hideableCardOrder.filter { id in
            guard !governed.contains(id) else { return false }
            return InsightsScoreCardsBlock.isCardPresent(id, in: derivedStore.metrics)
                || cardVisibility.isHidden(id)
        }
    }

    /// Toggle list to re-enable (or hide) individual wellness score cards.
    /// Self-suppresses entirely when there is no card to act on, so a
    /// score-less user never sees a dangling empty section.
    @ViewBuilder
    private var scoreCardsSection: some View {
        let ids = scoreCardIDs
        if !ids.isEmpty {
            Section {
                ForEach(ids, id: \.self) { id in
                    scoreToggleRow(for: id)
                }
            } header: {
                Text(String(localized: "Score cards"))
            }
            // UI-Standard R3/R4 — der Abschnitts-Footer ist ersatzlos gefallen.
            // Sein erster Satz erzählte den Schalter daneben nach, sein zweiter
            // wiederholte die „ohne Daten"-Aussage aus dem Tabs-Footer, und
            // sein dritter war ein Wegweiser („… stellst du unter Aussehen →
            // Ringe ein"). Nach R4 gehört dorthin ein Absprung oder nichts —
            // die Ringauswahl liegt genau einen Zurück-Tipp entfernt auf der
            // Seite, von der dieser Screen aufgerufen wird, ein Push dorthin
            // wäre eine Navigationsschleife. Also nichts.
        }
    }

    private func scoreToggleRow(for id: String) -> some View {
        Toggle(isOn: scoreCardBinding(for: id)) {
            // `InsightsDerivedBlock.title(for:)` returns an already-localized
            // String, so `Text(_: String)` renders it verbatim (no re-lookup).
            Text(InsightsDerivedBlock.title(for: id))
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
        }
        .accessibilityIdentifier("settings.insights.scoreCard.\(id)")
    }

    /// Toggle ON = card visible. Writes the inverse into the hidden-set.
    private func scoreCardBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !cardVisibility.isHidden(id) },
            set: { isVisible in cardVisibility.setHidden(id, !isVisible) }
        )
    }

    private var footerSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await layoutStore.resetToDefaults() }
            } label: {
                Label(String(localized: "Reset to default"), systemImage: "arrow.uturn.backward")
            }
        }
    }

    /// **UI-Standard R6 — die zweite der drei parallel gepflegten
    /// Erklärtabellen ist ersatzlos gefallen.** `subtitle(for:)` führte sechs
    /// Zeilen-Untertitel, die alle den Tab-Namen umformulierten („Gewicht" →
    /// „Aktuelles Gewicht und 7-Tage-Trend.", „Schlaf" → „Schlafdauer und
    /// Verlauf der Woche.", „Stimmung" → „Stimmungs-Score aus dem Tagebuch."
    /// …). Diese Liste sagt, welche Tabs in der Leiste erscheinen — nicht, was
    /// eine Metrik bedeutet. Damit trägt jede Domäne ihre Kurzbeschreibung
    /// wieder an genau einer Stelle.
    private func toggleRow(for tile: InsightsLayoutTile) -> some View {
        Toggle(isOn: binding(for: tile.id)) {
            Text(label(for: tile.id))
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
        }
        .accessibilityIdentifier("settings.insights.toggle.\(tile.id)")
    }

    /// `.onMove` callback — reorders via the server-first store. "Übersicht" is
    /// force-prepended so it always keeps the leading strip slot regardless of
    /// how the operator drags the metric / special rows (it has no row of its
    /// own here, so it can never be dragged). Any tile not in the strip set
    /// (e.g. `audio-events`, which round-trips but has no pill) is appended by
    /// the store's `reordering` tail rule, so its relative sequence survives.
    private func moveTiles(from source: IndexSet, to destination: Int) {
        var ids = orderedTiles.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        let ordered = [InsightsLayoutTileId.overview] + ids
        Task { await layoutStore.reorder(ordered) }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: {
                layoutStore.layout.tiles.first(where: { $0.id == id })?.visible ?? false
            },
            set: { _ in
                Task { await layoutStore.toggleVisible(forId: id) }
            }
        )
    }

    /// Localized label per server tile-id slug.
    private func label(for id: String) -> String {
        switch id {
        case InsightsLayoutTileId.overview: String(localized: "Overview")
        case InsightsLayoutTileId.bloodPressure: String(localized: "Blood pressure")
        case InsightsLayoutTileId.pulse: String(localized: "Pulse")
        case InsightsLayoutTileId.oxygen: String(localized: "Oxygen saturation")
        case InsightsLayoutTileId.bodyTemperature: String(localized: "Body temperature")
        case InsightsLayoutTileId.weight: String(localized: "Weight")
        case InsightsLayoutTileId.bmi: String(localized: "BMI")
        case InsightsLayoutTileId.activeEnergy: String(localized: "Steps")
        case InsightsLayoutTileId.workouts: String(localized: "Workouts")
        case InsightsLayoutTileId.sleep: String(localized: "Sleep")
        case InsightsLayoutTileId.restingPulse: String(localized: "Resting heart rate")
        case InsightsLayoutTileId.hrv: String(localized: "HRV")
        case InsightsLayoutTileId.mood: String(localized: "Mood")
        case InsightsLayoutTileId.medications: String(localized: "Compliance")
        // Fall back to the canonical metric / special-page display name so strip
        // tabs beyond the original 14-id set (the full chartable universe +
        // workouts/mood) read with a human label, never a raw slug.
        default: fallbackLabel(for: id)
        }
    }

    /// Canonical display name for a slug outside the curated `label(for:)` cases:
    /// a chartable metric's `displayName`, a special page's title, else the raw
    /// slug. Extracted to keep `label(for:)` under the complexity budget.
    private func fallbackLabel(for id: String) -> String {
        if let kind = InsightsTabSlug.metricKind(forSlug: id) {
            return kind.displayName
        }
        if let page = InsightsSpecialPage.page(forSlug: id) {
            return page.title
        }
        return id
    }
}
