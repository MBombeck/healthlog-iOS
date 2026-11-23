import SwiftUI

/// Apple-Health-style customisation screen for the dashboard tile strip.
///
/// Lets the user toggle tile visibility and reorder rows. Mutations
/// persist via `PUT /api/dashboard/widgets` (full-array idempotent
/// replace — server merges chart-overlay prefs in from the existing
/// row, route.ts:124-138, so we never accidentally wipe them).
///
/// **Layout (matches Apple Health → Browse → Edit):**
///
/// - Section "Sichtbar" — every row with `effectiveTileVisible == true`,
///   ordered as it will appear on the dashboard. Drag-handle on the
///   right for reordering. Toggle on the left hides the row.
/// - Section "Ausgeblendet" — every row with `effectiveTileVisible ==
///   false`. Toggle on the left re-enables the tile, reorder is
///   visual-only because hidden rows have no tile-strip position.
///
/// The screen reads `DashboardLayoutStore.layout` and writes via
/// `toggleTileVisible(forId:)` / `reorder(_:)`. Optimistic UI: the
/// flip is visible instantly; failures roll back + surface via
/// `error`.
///
/// **Reduce motion** is respected — `List`'s native `.onMove` honours
/// the preference, but the haptic-on-drop is suppressed via the
/// `accessibilityReduceMotion` environment value when set.
struct DashboardCustomizationScreen: View {
    @Environment(DashboardLayoutStore.self) private var layoutStore

    var body: some View {
        List {
            visibleSection
            hiddenSection
            footerSection
        }
        .hlPageMargins()
        .listStyle(.insetGrouped)
        // Reordering is always on: the pinned rows show their handles and
        // move with one touch, so the bar needs no "Edit" in words.
        .environment(\.editMode, .constant(.active))
        // "Dashboard anpassen" was cut to "Dashboard an…" between
        // "Bearbeiten" and the reset button; the screen lists the tiles.
        .navigationTitle(String(localized: "dashboard.customize.screenTitle"))
        .navigationBarTitleDisplayMode(.inline)
        // The server holds the layout; pulling reads it again, as on every
        // other list, instead of a refresh symbol in the bar.
        .refreshable { await layoutStore.refresh() }
        .task {
            // Cheap on hot launch (SWR returns cache); the explicit task ensures
            // the picker shows current state on a deep-link entry.
            await layoutStore.load()
        }
        // The banner below still presents as this overlay; this
        // reserves its height at the top so it covers nothing.
        .hlReserveErrorBannerSpace(layoutStore.error)
        .overlay(alignment: .top) {
            ErrorBanner(error: layoutStore.error) {
                Task { await layoutStore.refresh() }
            }
        }
    }

    // MARK: - Surface gate

    /// `true` only for widget ids that actually
    /// surface on the iOS Home tab: every metric-mappable id (tile strip) +
    /// `medications` (the compliance ring/mini card, gated since H1). Rows
    /// like `mood` / `bpInTarget` / `achievements` / `recentWorkouts` have NO
    /// Home surface — pre-fix they rendered toggles that did nothing
    /// (operator-felt "customize is broken"), so they no longer appear here.
    /// Their layout rows survive untouched in the PUT payload (web keeps
    /// using them); see `moveVisible` for the slot-preserving reorder.
    ///
    /// **Build 9 (Server-Prefs) / 9.4 — drift-guard acceptance.** This is the
    /// canonical **module-filter semantics** the `ModuleKeyRegistryDrift` guard
    /// protects: the gate is a pure UI *display* filter over the widget
    /// catalogue — it decides which ids get an editable Home toggle, and NEVER
    /// mutates the layout the PUT round-trips (a non-Home id keeps its stored
    /// row + slot). A new server widget id that reaches iOS must either map to a
    /// `MetricKind` (tile-strip surface) or be deliberately excluded here; the
    /// drift test fails at PR time if the id catalogue and the registry disagree.
    private static func hasHomeSurface(_ id: String) -> Bool {
        DashboardWidgetId.metricKind(forId: id) != nil || id == DashboardWidgetId.medications
    }

    // MARK: - Visible section

    @ViewBuilder
    private var visibleSection: some View {
        let visible = layoutStore.layout.visibleTiles.filter { Self.hasHomeSurface($0.id) }
        Section {
            if visible.isEmpty {
                HLEmptyNote("No tiles active. Enable tiles below to see them on the dashboard.")
            } else {
                ForEach(visible) { row in
                    customizationRow(row, isVisible: true)
                }
                .onMove(perform: moveVisible)
            }
        } header: {
            HLSectionHeader("Pinned")
        }
        .hlFormRowSurface()
        // No footer explaining the drag: the always-on handles are the
        // affordance.
    }

    // MARK: - Hidden section

    @ViewBuilder
    private var hiddenSection: some View {
        let hidden = layoutStore.layout.widgets
            .filter { !$0.effectiveTileVisible && Self.hasHomeSurface($0.id) }
            .sorted { $0.order < $1.order }
        // Nothing hidden, no section: an empty "Hidden" list with
        // "you haven't hidden anything" under it said nothing.
        if !hidden.isEmpty {
            Section {
                ForEach(hidden) { row in
                    customizationRow(row, isVisible: false)
                }
            } header: {
                HLSectionHeader("Hidden")
            }
            .hlFormRowSurface()
        }
    }

    // MARK: - Footer section

    /// Resetting throws away the person's own order and choices, so it asks
    /// first, with the word of the act instead of "Delete".
    static func resetAction(perform: @escaping @MainActor () async -> Void) -> HLDeleteAction {
        .confirmed(title: "Reset to defaults?", word: "Reset", symbol: "arrow.uturn.backward", perform: perform)
    }

    private var footerSection: some View {
        Section {
            HLDeleteButton("Reset to default", form: .row, action: Self.resetAction {
                await layoutStore.resetToDefaults()
            })
        }
        .hlFormRowSurface()
        // UI-Standard R2 — der Footer („Stellt die Standard-Reihenfolge und
        // -Sichtbarkeit wieder her.") formulierte den Knopf „Auf Standard
        // zurücksetzen" direkt darüber um. Tautologie, gefallen.
        // (v0.14.8 AUDIT-HOME L14 hatte hier zuvor eine Kachel-Aufzählung
        // entfernt, die mit der echten Default-Reihenfolge nicht mehr stimmte.)
    }

    // MARK: - Row

    private func customizationRow(
        _ row: DashboardWidgetConfig,
        isVisible: Bool
    ) -> some View {
        HLRow(
            title: Text(verbatim: displayName(for: row.id)),
            detail: secondaryHint(for: row.id).map { Text(verbatim: $0) },
            accessory: .toggle(
                Binding(
                    get: { isVisible },
                    set: { _ in
                        Task { await layoutStore.toggleTileVisible(forId: row.id) }
                    }
                )
            )
        ) {
            HLRowGlyph(symbol: symbol(for: row))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(displayName(for: row.id))"))
        .accessibilityValue(
            Text(isVisible
                ? String(localized: "dashboard.customize.visible.value")
                : String(localized: "Hidden"))
        )
        .accessibilityHint(Text(String(localized: "Toggle the switch to change visibility")))
    }

    // MARK: - Reorder

    private func moveVisible(from source: IndexSet, to destination: Int) {
        // The `.onMove` indices refer to the
        // DISPLAYED rows (visible AND Home-surfaced). Apply the move to that
        // filtered list, then walk the full order-sorted widget array and
        // re-slot only the displayed ids: web-only rows (`mood`,
        // `bpInTarget`, …) and hidden rows keep their exact positions, so an
        // iOS drag never shuffles the web dashboard's row order.
        var displayed = layoutStore.layout.visibleTiles.filter { Self.hasHomeSurface($0.id) }
        displayed.move(fromOffsets: source, toOffset: destination)
        let displayedIdSet = Set(displayed.map(\.id))
        var rearranged = displayed.map(\.id).makeIterator()
        let newOrder: [String] = layoutStore.layout.widgets
            .sorted { $0.order < $1.order }
            .map { row in
                displayedIdSet.contains(row.id) ? (rearranged.next() ?? row.id) : row.id
            }
        Task { await layoutStore.reorder(newOrder) }
    }

    // MARK: - Display helpers

    /// The metric's own symbol, else the module's; drawn in the row's symbol
    /// column, monochrome like the tile chrome on Today.
    private func symbol(for row: DashboardWidgetConfig) -> String {
        if let kind = DashboardWidgetId.metricKind(forId: row.id) {
            return kind.descriptor.sfSymbol
        }
        return nonMetricSymbol(for: row.id)
    }

    private func displayName(for id: String) -> String {
        Self.displayName(for: id)
    }

    /// Never surface a raw server widget id
    /// to the user. Resolves a localized label for every catalogue id; an
    /// unknown id (server adds a new widget, or re-emits a mapped-but-non-metric
    /// one like `recentWorkouts`) used to render its literal id string in both
    /// languages — it now falls back to a neutral localized label.
    /// `recentWorkouts` is also hidden from this list by `hasHomeSurface` (no
    /// Home tile), so the raw-id leak only mattered defensively. Pure +
    /// `nonisolated static` so it is pinnable from Swift Testing without a
    /// SwiftUI render pass.
    nonisolated static func displayName(for id: String) -> String {
        if let kind = DashboardWidgetId.metricKind(forId: id) {
            return String(localized: kind.descriptor.title)
        }
        switch id {
        case DashboardWidgetId.mood: return String(localized: "Mood")
        case DashboardWidgetId.medications: return String(localized: "Medications")
        case DashboardWidgetId.bpInTarget: return String(localized: "Blood pressure in range")
        case DashboardWidgetId.achievements: return String(localized: "dashboard.widget.achievements.title")
        case DashboardWidgetId.vo2Max: return String(localized: "dashboard.widget.vo2Max.title")
        default: return String(localized: "home.widget.unknown.title")
        }
    }

    /// **UI-Standard R6 — von drei parallel gepflegten Erklärtabellen ist eine
    /// übrig.** Diese Tabelle führte fünf Zeilen-Untertitel; drei davon
    /// formulierten nur den Zeilentitel um („Blutdruck im Zielbereich" →
    /// „Anteil der Messungen im Zielbereich", „Erfolge" → „Letzte
    /// freigeschaltete Erfolge", „Stimmung" → „Tägliche Stimmungsabbildung")
    /// und sind gefallen.
    ///
    /// Übrig bleiben die zwei Zeilen, deren Titel die Kachel **nicht** erklärt:
    /// „VO₂ Max" ist ein Messbegriff, kein Kachelinhalt, und „Medikamente"
    /// zeigt hier die *heutige* Einnahme, nicht die Medikamentenliste. Keine
    /// dieser beiden Domänen trägt nach dem Umbau noch anderswo eine zweite
    /// Kurzbeschreibung.
    private func secondaryHint(for id: String) -> String? {
        switch id {
        case DashboardWidgetId.vo2Max:
            String(localized: "dashboard.widget.vo2Max.subtitle")
        case DashboardWidgetId.medications:
            String(localized: "Today's intake compliance")
        default:
            nil
        }
    }

    private func nonMetricSymbol(for id: String) -> String {
        switch id {
        case DashboardWidgetId.mood: "face.smiling"
        case DashboardWidgetId.medications: "pills.fill"
        case DashboardWidgetId.bpInTarget: "target"
        case DashboardWidgetId.achievements: "trophy.fill"
        case DashboardWidgetId.vo2Max: "lungs.fill"
        default: "circle.dashed"
        }
    }
}
