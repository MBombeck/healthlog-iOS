import SwiftUI

/// Native labs surface (v1.18.1 `W-LABS`). Lists the user's lab results grouped
/// by panel, each row showing analyte + value + unit + a NEUTRAL range badge.
/// Reached from the "Health records" section of `MoreScreen` (gated
/// `ModuleGate.isEnabled(.labs)`); the biomarker catalog is reached from this
/// screen's toolbar.
///
/// **Store wiring.** The screen builds its ``LabsStore`` lazily from the
/// `appContainer` (`api` + `outbox` + `undoCoordinator`) so the surface compiles
/// + gates without an `AppContainer` edit. The reconcile pass SHOULD promote
/// `labsRepo` / `labsStore` to container-owned singletons and inject them here
/// (see the agent's reconcile spec); the lazy fallback keeps the build green in
/// the meantime.
struct LabsScreen: View {
    @Environment(\.appContainer) var container
    /// v1.25 — the "what changed since your last panel" awareness
    /// card's store. Server-authoritative; the card self-suppresses when there
    /// are fewer than two panels.
    @Environment(ClinicalSignalsStore.self) private var clinicalSignalsStore
    /// AUD-6 High — Labs is neither on the RootView foreground fan-out nor had a
    /// `scenePhase` handler, so a web/2nd-device lab edit was not picked up on
    /// return until a manual pull-to-refresh or cold launch. Drives a foreground
    /// revalidate, mirroring the Insights/Meds idiom.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The two sort axes, mirroring Messwerte's
    /// `MeasurementsPickerScreen.Mode`. `.byType` groups by `analyte` (the
    /// closest analogue to Messwerte's per-`MetricKind` grouping); `.chronological`
    /// flattens to a single date-sorted list. In-memory like the Messwerte picker
    /// (no persistence — the picker pattern it copies keeps the choice per-visit).
    enum SortMode: Hashable {
        case byType
        case chronological
    }

    @State private var store: LabsStore?
    /// The panel date the labs-changes banner is currently
    /// dismissed for (seeded from `LabsChangesDismissStore`). While this equals the
    /// live `latestDate`, the banner stays hidden; a newer panel re-shows it.
    @State private var dismissedLabsPanelDate: String? = LabsChangesDismissStore.dismissedPanelDate()
    @State private var sortMode: SortMode = .byType
    @State private var showAddSheet = false
    /// The on-device lab-report scan (`labs.scan.*`). Sits beside
    /// manual entry in the add menu, mirroring the web add-menu split
    /// (`app/labs/page.tsx:117-144`).
    @State private var showScanSheet = false
    @State private var showCatalog = false
    @State private var editingResult: LabResultDTO?
    /// The marker whose history stands beside the table. Screen state, not a
    /// second navigation stack: it survives a change of width and resolves to
    /// nothing once the marker is gone from the list.
    @State var selection = HLPaneSelection<String>()
    /// Categories the person opened or closed by hand on this screen, by
    /// the server's opaque key. The `groupsOpen` choice sets the start.
    @State var openGroups: [String: Bool] = [:]
    /// The editor, spellings and merge of the marker beside the table. They
    /// stand here, on the screen, so an open sheet survives the pane leaving
    /// the tree when the window narrows.
    @State private var markerSheet: BiomarkerSheet?
    /// Whether the history stands beside the table: then the selected
    /// marker's (i) and edit stand in this screen's bar, the history has no
    /// head of its own.
    @State private var showsDetailBeside = false

    var body: some View {
        // v0151 nav-scroll RCA-2: STABLE SCROLL ROOT. The body used to swap its
        // root from a bare `ProgressView` to a `List` after `.task` resolved, which
        // re-bound the `.large` title bar to a late-appearing scroll view → content
        // shifted down after load. `HLAsyncListScreen` always renders the `List`
        // root from frame 1 (skeleton / empty / loaded are rows INSIDE it), so the
        // bar binds once. See `.planning/v0151-audit/RCA-nav-scroll-2.md`.
        HLListDetail(detailAvailable: hasDetail) { layout in
            listRoot(layout)
                .onChange(of: layout.isSideBySide, initial: true) { _, beside in showsDetailBeside = beside }
        } detail: {
            detailPane
        }
        // Inline when pushed; as a sidebar tab the list heads itself.
        .hlSectionRootTitle(Text("labs.list.title"), headsItself: !phase.isError)
        .hlPageActions(pageActions)
        // Asks before the delete in the marker's more menu (#191 QoL).
        .hlDeleteConfirmation()
        .task {
            // v1.18.6 PHI — prefer the container-owned singleton (joins the
            // logout cascade + SWR-dedupes loads); the factory is the fallback
            // only when the environment container is somehow absent.
            if store == nil {
                store = container?.labsStore ?? container.map(LabsScreenFactory.makeStore(container:))
            }
            await store?.load()
        }
        // v1.25 — warm the labs-changes awareness card (daily SWR).
        .task {
            if !clinicalSignalsStore.hasSettledOnce {
                await clinicalSignalsStore.load()
            }
        }
        // AUD-6 High — foreground revalidate so a lab edited on web / a second
        // device is reflected on return (the repo is direct-fetch, so this is a
        // real round-trip; acceptable for a near-static list).
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await store?.load() }
            Task { await clinicalSignalsStore.refresh() }
        }
        .sheet(isPresented: $showAddSheet) {
            if let store {
                AddLabResultSheet(store: store)
            }
        }
        .sheet(item: $editingResult) { result in
            if let store {
                EditLabResultSheet(store: store, result: result)
            }
        }
        .sheet(isPresented: $showScanSheet) {
            if let store {
                LabScanSheet(labsStore: store)
            }
        }
        .sheet(item: $markerSheet) { sheet in
            if let store, let marker = presentedMarker(in: store) {
                switch sheet {
                case .editor: BiomarkerEditorSheet(store: store, existing: marker)
                case .aliases: BiomarkerAliasesSheet(store: store, marker: marker)
                case .merge: BiomarkerMergeSheet(store: store, target: marker)
                }
            }
        }
        .navigationDestination(for: LabMarkerRoute.self) { route in
            if let store {
                BiomarkerDetailScreen(
                    store: store,
                    analyte: route.analyte,
                    biomarker: route.biomarkerId.flatMap { id in store.biomarkers.first { $0.id == id } },
                    overviewLatest: route.latest
                )
            }
        }
        .navigationDestination(for: LabHistoryRoute.self) { route in
            if let store {
                BiomarkerHistoryScreen(title: route.title, store: store) { route.liveRows(in: store) }
            }
        }
        .navigationDestination(isPresented: $showCatalog) {
            if let store {
                BiomarkerCatalogScreen(store: store)
            }
        }
    }

    /// The list: the stable root of the screen, in a table once it is wide
    /// enough.
    private func listRoot(_ layout: HLListDetailLayout.Resolution) -> some View {
        HLAsyncListScreen(
            phase: phase,
            refresh: store.map { store in { await store.load() } },
            loading: {
                SectionRootHeader("labs.list.title", inList: true)
                HLAsyncListSkeletonRows()
            },
            empty: {
                SectionRootHeader("labs.list.title", inList: true)
                emptyRows
            },
            content: {
                SectionRootHeader("labs.list.title", inList: true)
                if let store { loadedRows(store: store, layout: layout) }
            }
        )
        // The page's margins, row grid and canvas on the stable list root.
        .hlPageMargins()
        .hlScrollEdgeSoft()
    }

    /// Whether a history stands beside the list: only in the by-type view
    /// (its rows are markers) and while there is a marker to show.
    private var hasDetail: Bool {
        guard phase == .loaded, sortMode == .byType, let store else { return false }
        return !store.markerIndex.isEmpty
    }

    /// The history of the selected marker beside the table: the marker page
    /// as the pushed screen shows it, under its own heading.
    @ViewBuilder
    private var detailPane: some View {
        if let store, let entry = LabMarkerSections.resolvedEntry(selection: selection, in: store.markerSections) {
            let marker = entry.biomarkerId.flatMap { id in store.biomarkers.first { $0.id == id } }
            BiomarkerDetailScreen(
                store: store,
                analyte: entry.analyte,
                biomarker: marker,
                overviewLatest: entry.latest,
                overviewCount: entry.count,
                isEmbedded: true,
                externalSheet: $markerSheet
            )
            // One page per marker: its period and history start over.
            .id(entry.id)
        } else {
            Color.clear.background(HLSurface.primary)
        }
    }

    /// The catalog marker the open sheet is about: the one beside the table.
    private func presentedMarker(in store: LabsStore) -> BiomarkerDTO? {
        guard let entry = LabMarkerSections.resolvedEntry(selection: selection, in: store.markerSections),
              let id = entry.biomarkerId,
              let marker = store.biomarkers.first(where: { $0.id == id }) else { return nil }
        return store.resolvedBiomarker(marker)
    }

    /// Adding a value is the plus at the outer edge; the scan and the
    /// catalog wait in the more menu beside it.
    private var pageActions: HLTabHeaderActions {
        HLTabHeaderActions(selectedMarkerActions + [
            .more(identifier: "labs.toolbar.more") {
                Button("labs.scan.title", systemImage: "doc.viewfinder") {
                    showScanSheet = true
                }
                .accessibilityIdentifier("labs.menu.scan")
                Button("biomarker.catalog.title", systemImage: "list.bullet.rectangle") {
                    showCatalog = true
                }
                .accessibilityIdentifier("labs.toolbar.catalog")
            },
            .add(label: "labs.add.title", identifier: "labs.toolbar.add") {
                showAddSheet = true
            }
        ])
    }

    /// The (i) and the edit of the marker beside the table, ahead of the
    /// screen's own actions; none while no history stands beside it.
    private var selectedMarkerActions: [HLTabHeaderAction] {
        guard showsDetailBeside, let store,
              let entry = LabMarkerSections.resolvedEntry(selection: selection, in: store.markerSections) else { return [] }
        let marker = entry.biomarkerId.flatMap { id in store.biomarkers.first { $0.id == id } }.map(store.resolvedBiomarker)
        return BiomarkerDetailScreen.markerActions(marker: marker, analyte: entry.analyte, sheet: $markerSheet) { id in
            if await store.deleteBiomarker(id: id) { selection.select(nil) }
        }
    }

    /// Maps store state to the stable-root render phase. `nil` store (pre-`.task`)
    /// and the first in-flight load both render the skeleton; the disabled module
    /// and the no-data case both render the `empty` rows (the disabled card is the
    /// "empty" content for a 403'd module); otherwise the real rows.
    private var phase: HLAsyncListPhase {
        guard let store else { return .loading }
        if store.isDisabled { return .empty }
        if store.labs.isEmpty {
            if store.isLoading { return .loading }
            // A failed fetch with no cached rows is an ERROR, not an
            // empty list. Offer Retry instead of the misleading "Add your first
            // lab result" + plus button.
            if store.lastError != nil {
                return .error(retry: { await store.load() })
            }
            return .empty
        }
        return .loaded
    }

    /// Empty-phase rows, rendered INSIDE the stable `List` root (not a sibling
    /// `ScrollView`). Carries both the module-disabled card and the no-data card.
    @ViewBuilder
    private var emptyRows: some View {
        if store?.isDisabled == true {
            // audit 02 · H-3 — Labs is a USER-switchable module (Settings →
            // Modules), so a disabled Labs surface must offer a way back in, not
            // the operator-gated `FeatureDisabledCard` (which deliberately has no
            // "turn it on" affordance). Mirror the Documents / Illness opt-in:
            // an enable CTA that flips `labs` on via `ModuleGate` and reloads.
            //
            // **Audit A-7 —** unless the switch is not the person's. Under
            // `not_granted` / `unavailable` / a state this build cannot name the
            // module is off because somebody else decided so, and the CTA would
            // invite a PATCH the server refuses. Then the server's own sentence
            // takes its place, with no affordance.
            Section {
                switch container?.moduleGate.optInPresentation(.labs) ?? .offerOptIn {
                case let .explain(reason):
                    FeatureDisabledCard(variant: .hero, reason: reason)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                case .offerOptIn:
                    LabsOptInView { await enableAndReload() }
                        .hlFreeAreaListRow()
                }
            }
        } else {
            healthRecordsSection
            Section {
                // The one action adds the first value where the eye already
                // is; the plus in the bar stays.
                HLEmptyState(
                    icon: "testtube.2",
                    title: "labs.empty.title",
                    message: "labs.empty.subtitle"
                ) {
                    HLButton("labs.add.title", systemImage: "plus", variant: .secondary) { showAddSheet = true }
                        .accessibilityIdentifier("labs.empty.add")
                }
                .hlFreeAreaListRow()
            }
        }
    }

    /// Loaded-phase rows: the sort-mode toggle, the sorted lab results + the
    /// trailing sync footer.
    @ViewBuilder
    private func loadedRows(store: LabsStore, layout: HLListDetailLayout.Resolution) -> some View {
        // v1.25 — "what changed since your last panel" awareness card. Self-
        // suppresses (renders nothing) when there are fewer than two panels.
        // Also suppressed once the user dismisses it for
        // the current panel; a newer panel (different `latestDate`) re-shows it.
        if let changes = clinicalSignalsStore.labsChanges,
           changes.hasContent,
           labsBannerPanelKey(changes) != dismissedLabsPanelDate
        {
            Section {
                LabsChangesCard(changes: changes) {
                    let key = labsBannerPanelKey(changes)
                    dismissedLabsPanelDate = key
                    LabsChangesDismissStore.setDismissedPanelDate(key)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: HLSpace.xs, leading: 0, bottom: HLSpace.xs, trailing: 0))
            }
        }
        // #180 — lab results from Health Records, offered once.
        healthRecordsSection
        // 14-03 (E1 / #67, Labs edition) — the failed half states itself beside
        // the healthy one. The rows below are real and current; only the
        // biomarker catalogue is missing, which is a statement about the
        // linking affordances and not about the readings. Same lockup and same
        // retry vocabulary as `DashboardMetricsErrorState`.
        if store.biomarkerCatalogError != nil {
            Section {
                HLErrorState("labs.biomarkerCatalog.error.message") { await store.reloadBiomarkers() }
                    .accessibilityIdentifier("labs.biomarkerCatalogErrorState")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        sortModeSection
        switch sortMode {
        case .byType:
            byTypeRows(store: store, layout: layout)
        case .chronological:
            Section {
                ForEach(store.sortedByDate) { row in
                    resultRow(row, store: store)
                }
            }
            .hlFormRowSurface()
        }
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    /// The rows of the "by type" mode.
    @ViewBuilder
    private func byTypeRows(store: LabsStore, layout: HLListDetailLayout.Resolution) -> some View {
        // The "by type" mode is a biomarker INDEX, not an
        // inline expansion of every reading (the b200 overcrowding bug). Each
        // marker is ONE row: it opens the Insights-class `BiomarkerDetailScreen`,
        // or, with the table beside its history, selects it there. The
        // blank-analyte bucket (legacy free-text rows with no analyte)
        // still renders its readings inline since they have no detail page.
        //
        // The rows come from `markerSections`: the server's categories
        // over the per-marker overview (whole history, never cut at a page
        // size), or one flat alphabetical list when the server does not
        // group or is older than the overview.
        let columns = LabsTableLayout.columns(layout, typeSize: dynamicTypeSize)
        let sections = store.markerSections
        let selectedID = layout.isSideBySide
            ? LabMarkerSections.resolvedEntry(selection: selection, in: sections)?.id
            : nil
        ForEach(sections) { section in
            markerSection(section, store: store, layout: layout, columns: columns, selectedID: selectedID)
        }
        let blank = store.blankAnalyteRows
        if !blank.isEmpty {
            Section {
                ForEach(blank) { row in
                    resultRow(row, store: store)
                }
            } header: {
                HLSectionHeader(verbatim: String(localized: "labs.analyte.none"), rank: .group)
            }
            .hlFormRowSurface()
        }
    }

    /// The stable dismissal key for the labs-changes banner: the
    /// panel's `latestDate`, or a sentinel when the wire omitted it (rare, but a
    /// nil key must still be dismissable). A newer panel yields a different key, so
    /// the dismissal auto-expires and the banner returns.
    private func labsBannerPanelKey(_ changes: InsightsLabsChangesDTO) -> String {
        changes.latestDate ?? "__present__"
    }

    /// The segmented sort-mode switch — "By type" / "Chronological". Mirrors
    /// `MeasurementsPickerScreen.modePicker`: an in-memory `@State`, segmented
    /// `Picker`, defaulting to `.byType` so entry is unchanged. Mounted as the
    /// first list section (it only renders in the loaded phase, so it never paints
    /// over the empty/disabled states — same gating intent as Messwerte's chips).
    private var sortModeSection: some View {
        Section {
            sortModePicker
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                // On the card edge, not on the text inset of a row.
                .listRowInsets(EdgeInsets(top: HLSpace.xs, leading: 0, bottom: HLSpace.xs, trailing: 0))
        }
    }

    private var sortModePicker: some View {
        HLAdaptiveSegmentedPicker(
            "labs.sort.label",
            selection: $sortMode,
            labels: ["labs.sort.byType", "labs.sort.chronological"]
        ) {
            Text("labs.sort.byType").tag(SortMode.byType)
            Text("labs.sort.chronological").tag(SortMode.chronological)
        }
        .accessibilityIdentifier("labs.screen.sortModeSwitch")
    }

    /// One lab-result navigation row with its swipe actions. Shared by both sort
    /// modes so the row presentation never diverges across the toggle.
    private func resultRow(_ row: LabResultDTO, store: LabsStore) -> some View {
        LabResultRow(row: row)
            .hlRowLink(inList: true) {
                LabResultDetailScreen(store: store, resultID: row.id, summary: row)
            }
            // The store keeps the way back: the reading goes at once with the
            // undo hint.
            .hlSwipeDelete(.undoable { await deleteRow(row, store: store) }, also: {
                Button("labs.edit.action", systemImage: "pencil") {
                    editingResult = row
                }
                .tint(HLAccent.userBrandTint)
            })
    }

    private func deleteRow(_ row: LabResultDTO, store: LabsStore) async {
        let message = String(localized: "labs.delete.undo")
        await store.deleteLab(id: row.id, undoMessage: message)
    }

    /// audit 02 · H-3 — flip the `labs` module back on (per-key
    /// `PATCH /api/auth/me/modules {labs:true}` via `ModuleGate`) and reload. The
    /// load clears `store.isDisabled` on success, so the surface swaps from the
    /// opt-in card to the real (empty or populated) list.
    private func enableAndReload() async {
        _ = await container?.moduleGate.setEnabled(.labs, enabled: true)
        await store?.load()
    }
}

// MARK: - LabsOptInView

/// The enable-CTA shown when the user-switchable `labs` module is off (audit 02 ·
/// H-3). Mirrors `DocumentsOptInView`: a calm explainer + an "Enable" button that
/// flips the module on via `ModuleGate` and reloads the surface.
struct LabsOptInView: View {
    let onEnable: () async -> Void
    @State private var isEnabling = false

    var body: some View {
        HLEmptyState(
            icon: "testtube.2",
            title: "labs.optIn.title",
            message: "labs.optIn.description"
        ) {
            // The one empty-state form: its one action is `.secondary`.
            HLButton("labs.optIn.action", systemImage: "checkmark.circle", variant: .secondary, isLoading: isEnabling) {
                Task {
                    isEnabling = true
                    await onEnable()
                    isEnabling = false
                }
            }
            .accessibilityIdentifier("labs.optIn.enable")
        }
    }
}

/// One biomarker index row in the "by type" mode: the marker name, one
/// detail line (number of readings, date of the latest), the latest value and
/// its range as quiet text. The whole row opens the marker's detail page; no
/// chevron, as on every data row.
struct BiomarkerIndexRow: View {
    let name: String
    let latest: LabResultDTO?
    let count: Int

    var body: some View {
        HLRow(
            title: Text(verbatim: name),
            detail: HLRowDetail.text([Self.countCaption(count), latest.map { LabsDateFormat.labDate($0.takenAt) }]),
            value: latest.map { Text(verbatim: $0.displayValue) },
            status: latest?.rangeStatus.rowStatus
        )
        .accessibilityLabel(accessibilityText)
    }

    /// The shared plural key; the format template read "1 Werte".
    static func countCaption(_ count: Int) -> String {
        String(localized: "\(count) values")
    }

    private var accessibilityText: String {
        guard let latest else { return name }
        let template = String(localized: "labs.row.a11y")
        return String(format: template, name, latest.displayValue, latest.rangeStatus.localizedLabel)
    }
}

/// Single lab-result list row: the analyte, no marks beside it (where a
/// reading comes from is said on its page), one detail line (date, and the printed value of a converted reading), the
/// value and its range as quiet text. Two lines on each side at most.
struct LabResultRow: View {
    let row: LabResultDTO

    var body: some View {
        HLRow(
            title: Text(verbatim: row.analyte),
            detail: HLRowDetail.text(Self.detailParts(row)),
            value: Text(verbatim: row.displayValue),
            status: row.rangeStatus.rowStatus
        )
        .accessibilityLabel(accessibilityText)
    }

    /// The facts of the detail line, in reading order. The printed range of a
    /// converted reading stays on the reading's own page.
    static func detailParts(_ row: LabResultDTO) -> [String?] {
        [LabsDateFormat.labDate(row.takenAt), LabConversion(row).convertedLine]
    }

    private var accessibilityText: String {
        let template = String(localized: "labs.row.a11y")
        return String(format: template, row.analyte, row.displayValue, row.rangeStatus.localizedLabel)
    }
}

/// Composition-root-free store factory. Builds a ``LabsStore`` from the public
/// container dependencies (`api` / `outbox` / `undoCoordinator`) without
/// touching `AppContainer`. Reconcile-pass note: replace with the
/// container-owned `labsStore` singleton.
enum LabsScreenFactory {
    @MainActor
    static func makeStore(container: AppContainer) -> LabsStore {
        // Pass the shared SWR coordinator so this factory-built store
        // reads labs + biomarkers cache-first (offline-readable), matching the
        // container-owned `labsStore` once its AppContainer wiring passes `swr`.
        let repo = LabsRepository(api: container.api, outbox: container.outbox, swr: container.swr)
        return LabsStore(repository: repo, undo: container.undoCoordinator)
    }
}
