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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .hlScreenBackground()
        // v0.5.x C-9 — iOS 26+ soft scroll-edge so List content blurs into
        // the navigation Liquid Glass instead of clipping cleanly.
        // iOS 18-25: no-op (system stays flat-translucent).
        .hlScrollEdgeSoft()
        .navigationTitle(String(localized: "Customize dashboard"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // v0.14 b147 — explicit EditButton so the visible section shows
            // drag handles and `.onMove` becomes a ONE-TOUCH drag. Without an
            // active edit mode SwiftUI only reorders via a finicky long-press-
            // hold-drag (operator bug: "can barely move tiles"). Monochrome
            // toolbar styling matches the rest of the app via `.tint`.
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
                    .tint(HLText.primary)
            }
            // Read-current-layout marker: tap to refresh from server. Server
            // is single source of truth; the user can pull-to-refresh too.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await layoutStore.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .accessibilityLabel(Text(String(localized: "Refresh")))
                }
                .tint(HLText.primary)
            }
        }
        .task {
            // Cheap on hot launch (SWR returns cache); the explicit task ensures
            // the picker shows current state on a deep-link entry.
            await layoutStore.load()
        }
        .overlay(alignment: .top) {
            ErrorBanner(error: layoutStore.error) {
                Task { await layoutStore.refresh() }
            }
        }
    }

    // MARK: - Surface gate

    /// v0.14.8 AUDIT-HOME H1 — `true` only for widget ids that actually
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
    /// (Build 2) protects: the gate is a pure UI *display* filter over the widget
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
                Text(String(localized: "No tiles active. Enable tiles below to see them on the dashboard."))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            } else {
                ForEach(visible) { row in
                    customizationRow(row, isVisible: true)
                }
                .onMove(perform: moveVisible)
            }
        } header: {
            Text(String(localized: "Pinned"))
        }
        // UI-Standard R2 — der Abschnitts-Footer („Auf ‚Bearbeiten' tippen und
        // eine Zeile am Griff ziehen …") war eine Bedien-Nacherzählung und
        // damit ausdrücklich verboten. Der `EditButton` steht sichtbar in der
        // Toolbar und blendet die System-Griffe ein; das ist die Affordanz.
    }

    // MARK: - Hidden section

    @ViewBuilder
    private var hiddenSection: some View {
        let hidden = layoutStore.layout.widgets
            .filter { !$0.effectiveTileVisible && Self.hasHomeSurface($0.id) }
            .sorted { $0.order < $1.order }
        Section {
            if hidden.isEmpty {
                Text(String(localized: "All tiles are active. You haven't hidden anything."))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            } else {
                ForEach(hidden) { row in
                    customizationRow(row, isVisible: false)
                }
            }
        } header: {
            Text(String(localized: "Hidden"))
        }
    }

    // MARK: - Footer section

    private var footerSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await layoutStore.resetToDefaults() }
            } label: {
                Label(
                    String(localized: "Reset to default"),
                    systemImage: "arrow.uturn.backward"
                )
            }
        }
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
        HStack(spacing: HLSpace.md) {
            iconForRow(row)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(displayName(for: row.id))
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                if let hint = secondaryHint(for: row.id) {
                    Text(hint)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                }
            }
            Spacer()
            Toggle(
                "",
                isOn: Binding(
                    get: { isVisible },
                    set: { _ in
                        Task { await layoutStore.toggleTileVisible(forId: row.id) }
                    }
                )
            )
            .labelsHidden()
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
        // v0.14.8 AUDIT-HOME H1 — the `.onMove` indices refer to the
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

    private func iconForRow(_ row: DashboardWidgetConfig) -> some View {
        // C-1: customization-screen icons go monochrome (R1 Strategy C).
        // This row list mirrors the dashboard's tile chrome — both must
        // share the same "Dracula stays only in chart content" stance.
        // Per-metric `descriptor.tint` still survives for chart series.
        if let kind = DashboardWidgetId.metricKind(forId: row.id) {
            let descriptor = kind.descriptor
            return AnyView(
                Image(systemName: descriptor.sfSymbol)
                    .font(.hlIcon(HLIconSize.rowAction))
                    .foregroundStyle(HLText.secondary)
            )
        }
        let symbol = nonMetricSymbol(for: row.id)
        return AnyView(
            Image(systemName: symbol)
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.secondary)
        )
    }

    private func displayName(for id: String) -> String {
        Self.displayName(for: id)
    }

    /// v0.14.x AUDIT-HOME M8 / HOME-12 — never surface a raw server widget id
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

    // `nonMetricTint(for:)` removed in C-1 — icons now share the monochrome
    // chrome stance enforced by `iconForRow`. Reintroduce only if a later
    // phase brings per-widget colour back at a different surface.
}
