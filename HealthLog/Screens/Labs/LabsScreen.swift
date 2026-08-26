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
    @Environment(\.appContainer) private var container
    /// v1.25 (GH iOS #38) — the "what changed since your last panel" awareness
    /// card's store. Server-authoritative, paired-only; the card self-suppresses
    /// when there are fewer than two panels.
    @Environment(ClinicalSignalsStore.self) private var clinicalSignalsStore
    @Environment(BackendAvailability.self) private var backend
    /// AUD-6 High — Labs is neither on the RootView foreground fan-out nor had a
    /// `scenePhase` handler, so a web/2nd-device lab edit was not picked up on
    /// return until a manual pull-to-refresh or cold launch. Drives a foreground
    /// revalidate, mirroring the Insights/Meds idiom.
    @Environment(\.scenePhase) private var scenePhase

    /// v0.15.3 LR1 — the two sort axes, mirroring Messwerte's
    /// `MeasurementsPickerScreen.Mode`. `.byType` groups by `analyte` (the
    /// closest analogue to Messwerte's per-`MetricKind` grouping); `.chronological`
    /// flattens to a single date-sorted list. In-memory like the Messwerte picker
    /// (no persistence — the picker pattern it copies keeps the choice per-visit).
    enum SortMode: Hashable {
        case byType
        case chronological
    }

    @State private var store: LabsStore?
    /// FW-LABS-BANNER (b210) — the panel date the labs-changes banner is currently
    /// dismissed for (seeded from `LabsChangesDismissStore`). While this equals the
    /// live `latestDate`, the banner stays hidden; a newer panel re-shows it.
    @State private var dismissedLabsPanelDate: String? = LabsChangesDismissStore.dismissedPanelDate()
    @State private var sortMode: SortMode = .byType
    @State private var showAddSheet = false
    /// Item 3.4 — the on-device lab-report scan (`labs.scan.*`). Sits beside
    /// manual entry in the add menu, mirroring the web add-menu split
    /// (`app/labs/page.tsx:117-144`).
    @State private var showScanSheet = false
    @State private var showCatalog = false
    @State private var editingResult: LabResultDTO?

    var body: some View {
        // v0151 nav-scroll RCA-2: STABLE SCROLL ROOT. The body used to swap its
        // root from a bare `ProgressView` to a `List` after `.task` resolved, which
        // re-bound the `.large` title bar to a late-appearing scroll view → content
        // shifted down after load. `HLAsyncListScreen` always renders the `List`
        // root from frame 1 (skeleton / empty / loaded are rows INSIDE it), so the
        // bar binds once. See `.planning/v0151-audit/RCA-nav-scroll-2.md`.
        HLAsyncListScreen(
            phase: phase,
            refresh: store.map { store in { await store.load() } },
            loading: { HLAsyncListSkeletonRows() },
            empty: { emptyRows },
            content: { if let store { loadedRows(store: store) } }
        )
        // LR1 — match the Messwerte canvas so the two surfaces feel like siblings:
        // the same `HLSurface.primary` token under a hidden list background + the
        // soft scroll-edge (`MeasurementListScreen.swift:181-189`,
        // `MeasurementsPickerScreen.swift:114-117`). `HLAsyncListScreen` renders the
        // `List` root but does not paint these; apply them here.
        .scrollContentBackground(.hidden)
        .background(HLSurface.primary)
        .hlScrollEdgeSoft()
        .navigationTitle(Text("labs.list.title"))
        // V1 — `.inline` (not `.large`). A `.large` title + trailing toolbar
        // pushed onto the titleless More root forces a navigation-bar inset
        // re-resolution on pop that shifts the More list down. `.inline` matches
        // the non-triggering screens (e.g. Vorsorge) and removes the reflow.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            // v1.18.6 PHI — prefer the container-owned singleton (joins the
            // logout cascade + SWR-dedupes loads); the factory is the fallback
            // only when the environment container is somehow absent.
            if store == nil {
                store = container?.labsStore ?? container.map(LabsScreenFactory.makeStore(container:))
            }
            await store?.load()
        }
        // v1.25 — warm the labs-changes awareness card (paired-only, daily SWR).
        .task {
            if backend.hasServer, !clinicalSignalsStore.hasSettledOnce {
                await clinicalSignalsStore.load()
            }
        }
        // AUD-6 High — foreground revalidate so a lab edited on web / a second
        // device is reflected on return (the repo is direct-fetch, so this is a
        // real round-trip; acceptable for a near-static list).
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await store?.load() }
            if backend.hasServer { Task { await clinicalSignalsStore.refresh() } }
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
        .navigationDestination(isPresented: $showCatalog) {
            if let store {
                BiomarkerCatalogScreen(store: store)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showCatalog = true
            } label: {
                Label("biomarker.catalog.title", systemImage: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("labs.toolbar.catalog")
        }
        ToolbarItem(placement: .topBarTrailing) {
            // Item 3.4 — manual entry and the on-device scan are siblings, as on
            // the web. A Menu (not a second toolbar button) keeps the bar at two
            // items and makes "Wert hinzufügen" the first, default-reading option.
            Menu {
                Button {
                    showAddSheet = true
                } label: {
                    Label("labs.add.title", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("labs.menu.add")
                Button {
                    showScanSheet = true
                } label: {
                    Label("labs.scan.title", systemImage: "doc.viewfinder")
                }
                .accessibilityIdentifier("labs.menu.scan")
            } label: {
                Label("labs.add.title", systemImage: "plus")
            }
            .accessibilityIdentifier("labs.toolbar.add")
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
            // AUD-5 H1 — a failed fetch with no cached rows is an ERROR, not an
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
            Section {
                LabsOptInView { await enableAndReload() }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                HLEmptyState(
                    icon: "testtube.2",
                    title: "labs.empty.title",
                    message: "labs.empty.subtitle"
                ) {
                    VStack(spacing: HLSpace.sm) {
                        HLButton("labs.add.title", icon: "plus", variant: .primary) {
                            showAddSheet = true
                        }
                        // Item 3.4 — the scan is the faster path out of an empty
                        // Labs screen: one photo of a panel beats 15 manual rows.
                        HLButton("labs.scan.title", icon: "doc.viewfinder", variant: .secondary) {
                            showScanSheet = true
                        }
                        Text("labs.scan.entry.footer")
                            .font(.hlFootnote)
                            .foregroundStyle(HLText.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
    }

    /// Loaded-phase rows: the sort-mode toggle, the sorted lab results + the
    /// trailing sync footer.
    @ViewBuilder
    private func loadedRows(store: LabsStore) -> some View {
        // v1.25 — "what changed since your last panel" awareness card. Self-
        // suppresses (renders nothing) when there are fewer than two panels.
        // FW-LABS-BANNER (b210) — also suppressed once the user dismisses it for
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
        // 14-03 (E1 / #67, Labs edition) — the failed half states itself beside
        // the healthy one. The rows below are real and current; only the
        // biomarker catalogue is missing, which is a statement about the
        // linking affordances and not about the readings. Same lockup and same
        // retry vocabulary as `DashboardMetricsErrorState`.
        if store.biomarkerCatalogError != nil {
            Section {
                LabsBiomarkerCatalogErrorState { await store.reloadBiomarkers() }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        sortModeSection
        switch sortMode {
        case .byType:
            // v0154 LR-REDO — the "by type" mode is a biomarker INDEX, not an
            // inline expansion of every reading (the b200 overcrowding bug). Each
            // analyte is ONE tappable item row → an Insights-class
            // `BiomarkerDetailScreen`. The named-analyte buckets are the index;
            // the blank-analyte bucket (legacy free-text rows with no analyte)
            // still renders its readings inline since they have no detail page.
            Section {
                ForEach(store.groupedByAnalyte.filter { $0.analyte != nil }) { group in
                    biomarkerIndexRow(group, store: store)
                }
            }
            if let blank = store.groupedByAnalyte.first(where: { $0.analyte == nil }) {
                Section {
                    ForEach(blank.rows) { row in
                        resultRow(row, store: store)
                    }
                } header: {
                    MeasurementListSectionHeader(
                        text: String(localized: "labs.analyte.none")
                    )
                }
            }
        case .chronological:
            Section {
                ForEach(store.sortedByDate) { row in
                    resultRow(row, store: store)
                }
            }
        }
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    /// FW-LABS-BANNER — the stable dismissal key for the labs-changes banner: the
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
            Picker(selection: $sortMode) {
                Text("labs.sort.byType").tag(SortMode.byType)
                Text("labs.sort.chronological").tag(SortMode.chronological)
            } label: {
                Text("labs.sort.label")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("labs.screen.sortModeSwitch")
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    /// One lab-result navigation row with its swipe actions. Shared by both sort
    /// modes so the row presentation never diverges across the toggle.
    private func resultRow(_ row: LabResultDTO, store: LabsStore) -> some View {
        NavigationLink {
            LabResultDetailScreen(store: store, resultID: row.id, summary: row)
        } label: {
            LabResultRow(row: row)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await deleteRow(row, store: store) }
            } label: {
                Label("labs.delete.action", systemImage: "trash")
            }
            Button {
                editingResult = row
            } label: {
                Label("labs.edit.action", systemImage: "pencil")
            }
            .tint(HLAccent.userBrandTint)
        }
    }

    /// v0154 LR-REDO — one biomarker index row (the "by type" item). Tapping it
    /// opens the Insights-class ``BiomarkerDetailScreen`` for the analyte. The
    /// matching catalog ``BiomarkerDTO`` (if the group's rows are linked) is
    /// passed through so the detail page can drive the editor gear + explainer.
    @ViewBuilder
    private func biomarkerIndexRow(_ group: LabsStore.AnalyteGroup, store: LabsStore) -> some View {
        let analyte = group.analyte ?? ""
        let marker = linkedBiomarker(for: group, store: store)
        NavigationLink {
            BiomarkerDetailScreen(store: store, analyte: analyte, biomarker: marker)
        } label: {
            BiomarkerIndexRow(
                name: marker?.name ?? analyte,
                latest: group.rows.first,
                count: group.rows.count
            )
        }
        .accessibilityIdentifier("labs.byType.item")
    }

    /// Resolve the catalog biomarker for an analyte group: the first row's
    /// `biomarkerId` resolved against the loaded catalog. `nil` for free-text
    /// (unlinked) analytes — the detail page falls back to the analyte name.
    private func linkedBiomarker(for group: LabsStore.AnalyteGroup, store: LabsStore) -> BiomarkerDTO? {
        guard let id = group.rows.first(where: { $0.biomarkerId != nil })?.biomarkerId else { return nil }
        return store.biomarkers.first { $0.id == id }
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
            HLButton("labs.optIn.action", icon: "checkmark.circle", variant: .primary, isLoading: isEnabling) {
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

/// v0154 LR-REDO — one biomarker index row in the "by type" mode. Shows the
/// biomarker name, its latest value + unit, a compact reading-count caption, and
/// the latest reading's NEUTRAL range badge. A `NavigationLink` to the
/// Insights-class detail page (the link chevron is supplied by the row's host).
struct BiomarkerIndexRow: View {
    let name: String
    let latest: LabResultDTO?
    let count: Int

    var body: some View {
        HStack(spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Text(name)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                Text(countCaption)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            }
            Spacer(minLength: HLSpace.sm)
            if let latest {
                VStack(alignment: .trailing, spacing: HLSpace.xxs) {
                    Text(valueLabel(latest))
                        .font(.hlMetric(.title3))
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                    LabRangeBadge(status: latest.rangeStatus)
                }
            }
        }
        .padding(.vertical, HLSpace.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var countCaption: String {
        let template = String(localized: "labs.byType.count")
        return String(format: template, count)
    }

    private func valueLabel(_ row: LabResultDTO) -> String {
        // Item 1.5 — qualitative rows render their result text, not a phantom 0.
        row.displayValue
    }

    private var accessibilityText: String {
        guard let latest else { return name }
        let template = String(localized: "labs.row.a11y")
        return String(format: template, name, valueLabel(latest), latest.rangeStatus.localizedLabel)
    }
}

/// Single lab-result list row: analyte + paneled value/unit + a NEUTRAL range
/// badge. Linked rows (`biomarkerId != nil`) show a small link glyph.
struct LabResultRow: View {
    let row: LabResultDTO

    var body: some View {
        HStack(spacing: HLSpace.md) {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                HStack(spacing: HLSpace.xs) {
                    Text(row.analyte)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    if row.isLinked {
                        Image(systemName: "link")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                            .accessibilityHidden(true)
                    }
                    if row.hasNote {
                        Image(systemName: "note.text")
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                Text(LabsDateFormat.mediumDate(row.takenAt))
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
            }
            Spacer(minLength: HLSpace.sm)
            VStack(alignment: .trailing, spacing: HLSpace.xxs) {
                Text(valueLabel)
                    // LR1 — match `MeasurementRow`'s `.hlMetric(.title3)` so the lab
                    // value reads at the same weight as a Messwerte value.
                    .font(.hlMetric(.title3))
                    .monospacedDigit()
                    .foregroundStyle(HLText.primary)
                LabRangeBadge(status: row.rangeStatus)
            }
        }
        .padding(.vertical, HLSpace.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var valueLabel: String {
        // Item 1.5 — qualitative rows render their result text, not a phantom 0.
        row.displayValue
    }

    private var accessibilityText: String {
        let template = String(localized: "labs.row.a11y")
        return String(format: template, row.analyte, valueLabel, row.rangeStatus.localizedLabel)
    }
}

/// **14-03 (E1 / the #67 pattern, Labs edition)** — the biomarker catalogue's
/// own failure, stated beside a healthy labs list rather than instead of it.
///
/// Reuses `DashboardMetricsErrorState`'s lockup (canonical `HLEmptyState`,
/// monochrome, the same `exclamationmark.arrow.circlepath` glyph and the same
/// "Try again" copy), because this is the same fact in a different section: one
/// subrequest failed, the rest of the surface is current, and the retry re-runs
/// only the half that failed.
///
/// The button variant is `.secondary`, not the `.restrained` its dashboard
/// sibling still carries: R9 is retiring `.ghost`/`.restrained`, the UI-standard
/// baseline is a debt display rather than an allow-list, and a full-width action
/// inside a card is exactly the "→ .secondary" case. The dashboard's own
/// occurrence is baselined debt and belongs to whoever sweeps it.
private struct LabsBiomarkerCatalogErrorState: View {
    let onRetry: () async -> Void

    @State private var isRetrying = false

    var body: some View {
        HLCard {
            HLEmptyState(
                icon: "exclamationmark.arrow.circlepath",
                title: "labs.biomarkerCatalog.error.title",
                message: "labs.biomarkerCatalog.error.message"
            ) {
                HLButton(
                    String(localized: "Try again"),
                    icon: "arrow.clockwise",
                    variant: .secondary,
                    isLoading: isRetrying
                ) {
                    Task {
                        isRetrying = true
                        await onRetry()
                        isRetrying = false
                    }
                }
            }
            .accessibilityIdentifier("labs.biomarkerCatalogErrorState")
        }
    }
}

/// Composition-root-free store factory. Builds a ``LabsStore`` from the public
/// container dependencies (`api` / `outbox` / `undoCoordinator`) without
/// touching `AppContainer`. Reconcile-pass note: replace with the
/// container-owned `labsStore` singleton.
enum LabsScreenFactory {
    @MainActor
    static func makeStore(container: AppContainer) -> LabsStore {
        // QOL-OFF-2 — pass the shared SWR coordinator so this factory-built store
        // reads labs + biomarkers cache-first (offline-readable), matching the
        // container-owned `labsStore` once its AppContainer wiring passes `swr`.
        let repo = LabsRepository(api: container.api, outbox: container.outbox, swr: container.swr)
        return LabsStore(repository: repo, undo: container.undoCoordinator)
    }
}
