import SwiftUI

/// Apple-Health-style drill-down list of all `Measurement` rows for one
/// `MetricKind`. Pushed from `ChartDetailScreen.DrillDownRow`.
///
/// **Sectioning rules (v0.4.1 — `MeasurementBucketing`):**
/// - Last 7 days → per-day raw rows (no aggregation).
/// - 7 to 90 days → if a week carries more than `weeklyThreshold` (5) items
///   it collapses to a single `weeklySummary` row (avg/min/max + chevron
///   to expand). Otherwise per-day raw rows.
/// - Older than 90 days → if a month carries more than `monthlyThreshold`
///   (20) items it collapses to `monthlySummary` rows.
///
/// User pain solved: a daily BP logger had thousands of rows in a single
/// "Older" section before this — Apple-Health's solution is exactly the
/// same per-period summary rollup we adopt here.
///
/// Each section is one grouped block of history rows under a day, week or
/// month header; the `List` stays so swipe-to-delete and multi-select keep
/// working row by row.
struct MeasurementListScreen: View {
    let kind: MetricKind

    @Environment(\.appContainer) private var container
    /// Routes the empty-state CTA to the capture sheet prefilled
    /// to this metric kind, so the empty list has a next step.
    @Environment(AppRouter.self) private var router
    /// A11Y — gates the edit-mode toggle animations below so
    /// selection mode snaps instead of sliding when Reduce Motion is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measurements: [Measurement] = []
    @State private var isLoading: Bool = false
    @State private var error: HLError?
    /// Appear-revalidation freshness stamp. Lets a re-entry re-validate
    /// the partial-then-stale case instead of only reloading when empty.
    @State private var lastLoadedAt: Date?
    @State private var searchText: String = ""
    /// Optional per-source filter chip selection. `nil` means
    /// "Alle Quellen" (no filter); a concrete `MeasurementSource` value
    /// restricts the list to rows whose `source` matches. The kind itself
    /// is already pinned by the screen's `kind` parameter, so a kind-filter
    /// would be redundant — the meaningful axis on this drill-down is the
    /// source provenance (Apple Health vs. Withings vs. Manuell vs. Import).
    @State private var selectedSource: MeasurementSource?
    /// v0.14.8 W3 (v1.15.13 adoption) — the SERVER-filtered page for the
    /// active source chip (`GET /api/measurements?sourceEq=…`). The old
    /// client-side slice of the loaded page under-reported: the page is
    /// recency-capped, so rows of the selected source that fell off it never
    /// appeared. `nil` = no filter active, fetch failed, or the server page
    /// came back empty (older deploy / series-synthesized rows) — all of
    /// which fall back to the legacy client-side filter so the list never
    /// regresses to worse than before.
    @State private var sourceFilteredRows: [Measurement]?
    /// v1.18.5 parity — optional numeric value-range filter (min/max). Held
    /// as raw text so partial input ("12", "") never traps the field; parsed
    /// to `Double?` at filter time. Applied client-side on the loaded rows
    /// (the SWR cache the list already paints from), composing with the
    /// source chip + search needle. Empty fields = open-ended bound.
    /// The value-range filter is typed in the unit the rows show
    /// (the account's) and inverted to canonical before it compares.
    @Environment(\.unitPreferences) var unitPreferences
    @State private var valueMinText: String = ""
    @State private var valueMaxText: String = ""
    @State private var showValueRange: Bool = false
    /// Build 3 / item 3.3 — optional date-range filter (from / to), web parity
    /// with `measurement-list.tsx:328-329`. iOS had NO date filter on any
    /// surface. Both bounds are optional; `nil` means open-ended. Applied
    /// client-side on the loaded rows, composing with the source chip, the
    /// value range and the search needle.
    @State private var dateFrom: Date?
    @State private var dateTo: Date?
    @State private var showDateRange: Bool = false
    /// Build 3 / item 3.3 — the LOAD-MORE window. Was a hard, invisible cap:
    /// `recent(kind:)` defaulted to 400 rows and nothing ever asked for more,
    /// so a long-term user's history beyond the cap was simply unreachable
    /// (audit A2 "Paginierung"). The list still starts at 400 — cold-start cost
    /// is unchanged — and only an explicit tap pays for a wider read.
    @State private var pageLimit: Int = MeasurementListScreen.initialPageLimit
    /// True while a load-more read is in flight — keeps the footer from
    /// re-firing and gives the button an honest spinner.
    @State private var isLoadingMore = false
    /// Latched once a wider read comes back no larger than the previous one:
    /// the server has no more rows for this kind, so the footer retires instead
    /// of offering a button that can only disappoint.
    @State private var reachedEnd = false

    /// The first page — deliberately the historical `recent(kind:)` default.
    static let initialPageLimit = 400
    /// Each Load more widens the window by another full page.
    static let pageStep = 400
    /// Hard ceiling. The server clamps its own history window around ~10y;
    /// beyond this a list is the wrong tool anyway (the chart + export are),
    /// and an unbounded loop would let a mis-tap pull tens of thousands of rows
    /// onto the main actor.
    static let maxPageLimit = 4000
    @State private var expandedSummaryIDs: Set<String> = []
    @State private var editing: Measurement?
    /// Native multi-select bulk delete (v1.15.13
    /// `POST /api/measurements/bulk-delete`). `editMode` drives the system
    /// Edit-mode selection circles; `selection` carries the picked row ids
    /// (raw `Measurement` rows only — chips / summary rows are
    /// `selectionDisabled`); the delete button in the bottom bar asks first.
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []

    /// Memoized filter/bucketing/sources outputs. Pre-fix these
    /// were computed properties (`filteredMeasurements`, `availableSources`)
    /// re-run on EVERY body pass — and `MeasurementBucketing.sections(...)`
    /// re-grouped the result inline in the `ForEach`. With 500-1000+ rows
    /// that meant a full-array filter + bucketing + section-diff per render,
    /// including per keystroke during search. These caches are recomputed
    /// only when an actual input changes (see `recomputeFiltered` / the
    /// debounced search pipeline), so typing and scrolling stay cheap.
    @State private var filteredCache: [Measurement] = []
    @State private var bucketedGroups: [MeasurementListGroup] = []
    @State private var availableSourcesCache: [MeasurementSource] = []
    /// Debounced mirror of `searchText`. The text field updates
    /// `searchText` on every keystroke (drives the system search UI), but the
    /// expensive re-filter keys off this debounced value (~250ms settle) so a
    /// fast typist re-filters once, not once per character.
    @State private var debouncedSearchText: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        List(selection: $selection) {
            // Source-filter chip row mounted as the first list
            // section so the chips scroll with the content (Apple Health's
            // filter-strip pattern in the drill-down lists). Hides itself
            // entirely when there are no measurements yet so the empty
            // state stays clean.
            if !measurements.isEmpty {
                Section {
                    SourceFilterChips(
                        available: availableSourcesCache,
                        selection: $selectedSource
                    )
                    .listRowInsets(EdgeInsets(top: HLSpace.xs, leading: 0, bottom: HLSpace.xs, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                }
                // The two optional filters as rows of one card, like the
                // readings below; loose on the page they had their own inset.
                Section {
                    ValueRangeFilterControl(
                        isExpanded: $showValueRange,
                        minText: $valueMinText,
                        maxText: $valueMaxText,
                        unit: unitPreferences.unitLabel(for: kind)
                    )
                    .selectionDisabled()
                    DateRangeFilterControl(
                        isExpanded: $showDateRange,
                        from: $dateFrom,
                        to: $dateTo
                    )
                    .selectionDisabled()
                }
                .hlFormRowSurface()
            }
            if filteredCache.isEmpty, !measurements.isEmpty, !isLoading {
                Section {
                    NoMatchesState()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                }
            }
            // One card per week (readings) or per month and year (summaries),
            // never a card per day: the day stands in each row's title.
            ForEach(bucketedGroups) { group in
                Section {
                    ForEach(group.sections) { section in
                        sectionRows(section)
                    }
                } header: {
                    HLSectionHeader(verbatim: MeasurementBucketing.title(of: group.header), rank: .group)
                }
                .hlFormRowSurface()
            }
            if measurements.isEmpty, !isLoading {
                // The button names the next step; no sentence repeats it.
                HLEmptyState(icon: "tray", title: "No measurements yet") {
                    HLButton("Log a measurement", systemImage: "plus", variant: .secondary) {
                        router.requestMeasure(prefill: kind)
                    }
                    .accessibilityIdentifier("measurements.list.empty.log")
                }
                .accessibilityIdentifier("measurements.list.empty")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            }
            // Build 3 / item 3.3 — LOAD MORE, replacing the invisible 400-row
            // cap. NOT auto-triggered on scroll: an infinite scroll here would
            // silently pull thousands of rows through filtering + bucketing on
            // the main actor. An explicit tap keeps that cost visible.
            if canLoadMore {
                Section {
                    HLLoadMoreRow(hasMore: true, isLoading: isLoadingMore) {
                        Task { await loadMore() }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    .accessibilityIdentifier("measurements.list.loadMore")
                }
            }
            // Canonical sync-status footer (same primitive
            // as Dashboard/Insights). Hosted as an empty section's FOOTER so
            // the self-suppressed state collapses to zero height (no phantom
            // row).
            Section {} footer: {
                HLSyncStatusFooter(screenLoading: isLoading)
            }
        }
        .listStyle(.insetGrouped)
        .hlPageMargins()
        // Soft scroll edge: the rows blur into the navigation bar.
        .hlScrollEdgeSoft()
        .navigationTitle(kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // Expanded prompt reflects the wider search-scope
        // (note + source label + date label). Old "Notiz suchen" prompt
        // misled the user into thinking only notes are searchable.
        .searchable(text: $searchText, prompt: Text("Search measurement"))
        .refreshable { await load() }
        .task { await loadIfStale() }
        // Re-fetch the server-filtered page whenever the source
        // chip changes (and clear it when the filter is lifted).
        .task(id: selectedSource) { await loadSourceFiltered() }
        // Memoization triggers. Recompute the filtered/bucketed
        // slice + source chips only when an actual input changes, not on every
        // body pass. `searchText` is funnelled through a 250ms debounce so a
        // fast typist re-filters once rather than per keystroke.
        .onChange(of: searchText) { _, newValue in scheduleSearchDebounce(newValue) }
        .onChange(of: measurements) { _, _ in
            availableSourcesCache = MeasurementListFilter.availableSources(in: measurements)
            recomputeFiltered()
        }
        .onChange(of: selectedSource) { _, _ in recomputeFiltered() }
        .onChange(of: sourceFilteredRows) { _, _ in recomputeFiltered() }
        .onChange(of: debouncedSearchText) { _, _ in recomputeFiltered() }
        .onChange(of: valueMinText) { _, _ in recomputeFiltered() }
        .onChange(of: valueMaxText) { _, _ in recomputeFiltered() }
        .onChange(of: dateFrom) { _, _ in recomputeFiltered() }
        .onChange(of: dateTo) { _, _ in recomputeFiltered() }
        .overlay {
            if isLoading, measurements.isEmpty {
                // A silhouette of the upcoming rows instead of a spinner.
                MeasurementListSkeletonContent()
            }
        }
        .hlErrorBannerOverlay(error: error) {
            Task { await load() }
        }
        .sheet(item: $editing) { m in
            EditMeasurementSheet(measurement: m) { updated in
                if let i = measurements.firstIndex(where: { $0.id == m.id }) {
                    measurements[i] = updated
                }
                editing = nil
            }
        }
        // Native Edit-mode multi-select. The trailing button
        // toggles edit mode (selection circles on the raw rows); the bottom
        // bar carries the destructive bulk action while editing. Swipe
        // actions are system-suppressed during edit mode.
        .environment(\.editMode, $editMode)
        // Selecting is the page's one bar action: the checklist, filled
        // while choosing; VoiceOver says "Select" and "selected".
        .hlPageActions(HLTabHeaderActions(measurements.isEmpty ? [] : [.select(isOn: isSelecting)]))
        // The delete of a selection rides the page's bottom bar: the list
        // makes room for it, so it never covers the last row's value.
        .hlBottomBar {
            if editMode.isEditing {
                HStack {
                    Spacer()
                    bulkDeleteButton
                }
            }
        }
        // While selecting, the tab bar gives way to the bottom bar that
        // carries the delete; it would otherwise cover it.
        .toolbar(editMode.isEditing ? .hidden : .visible, for: .tabBar)
        // The question of the bar's bulk delete hangs on the screen, around
        // the bar, so the button in the bar reaches its runner.
        .hlDeleteConfirmation()
        // Re-sync the local list whenever the store's measurement
        // set changes. `MeasurementsStore.delete` (and its undo-restore)
        // mutate `store.recent`; reloading from `repo.recent(kind:)` reflects
        // the server truth so a restored row re-appears on this drill-down.
        .onChange(of: container?.measurementsStore.recent.count) { _, _ in
            Task { await load() }
        }
    }

    /// Several readings at once go only after the question.
    static func bulkDeleteAction(count: Int, perform: @escaping @MainActor () async -> Void) -> HLDeleteAction {
        .confirmed(
            title: "Delete \(count) measurements?",
            message: "measurements.bulkDelete.confirm.message",
            perform: perform
        )
    }

    private func performDelete(_ measurement: Measurement) async {
        guard let container else { return }
        // Route through `MeasurementsStore.delete`, which owns the
        // optimistic remove + the `Rückgängig` undo-toast enqueue + the
        // server-restore-on-undo (re-POST the deleted row) + the HK-mirror
        // teardown. We mirror the optimistic remove into this screen's local
        // `measurements` for immediate feedback; the `store.recent`-count
        // observer below re-syncs the list when the store mutates (delete OR
        // undo-restore), so a restored row re-appears here too.
        let snapshot = measurements
        measurements.removeAll { $0.id == measurement.id }
        let ok = await container.measurementsStore.delete(measurement)
        if !ok {
            // Non-retriable failure already rolled the store back + dismissed
            // the toast; restore the local list to match.
            measurements = snapshot
        }
    }

    /// Bulk variant of `performDelete`. Resolves the selected
    /// ids against the loaded rows (server-filtered page first, then the
    /// base page), removes them optimistically from this screen, and routes
    /// the write through `MeasurementsStore.bulkDelete` (chunked POST +
    /// outbox enrollment). The `store.recent`-count observer re-syncs the
    /// list against server truth afterwards either way.
    private func performBulkDelete() async {
        guard let container, !selection.isEmpty else { return }
        let pool = (sourceFilteredRows ?? []) + measurements
        var seen = Set<String>()
        let targets = pool.filter { selection.contains($0.id) && seen.insert($0.id).inserted }
        guard !targets.isEmpty else { return }
        let snapshot = measurements
        let filteredSnapshot = sourceFilteredRows
        let removedIDs = selection
        measurements.removeAll { removedIDs.contains($0.id) }
        sourceFilteredRows = sourceFilteredRows.map { rows in rows.filter { !removedIDs.contains($0.id) } }
        selection = []
        withAnimation(reduceMotion ? nil : .default) { editMode = .inactive }
        let ok = await container.measurementsStore.bulkDelete(targets)
        if !ok {
            // Mirrors `performDelete`: a genuinely-dropped bulk delete rolled
            // the store back — restore the local lists to match. (A queued
            // offline delete returns false too; the store keeps its removal
            // and the count observer re-syncs this screen right after.)
            measurements = snapshot
            sourceFilteredRows = filteredSnapshot
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let container else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await container.measurementsRepo.recent(kind: kind, limit: pageLimit)
            // Series fallback. The chart-detail page synthesizes
            // `recentInRange` from `/series` when `recent(kind:)` is empty/threw
            // (`ChartDetailStore.measurementsFromSeriesPoints`), so the chart
            // shows data + a non-zero "N entries" badge. This list called
            // `recent(kind:)` with NO fallback → it showed "keine Einträge" even
            // though the chart had data (operator: "Vital → alle Messungen
            // anzeigen empty though chart has data"). Give the list the SAME
            // fallback so the two surfaces never disagree.
            if rows.isEmpty {
                measurements = await seriesFallbackRows(container: container)
            } else {
                measurements = rows
            }
            lastLoadedAt = .now
        } catch let err as HLError {
            // `recent(kind:)` threw — try the series synthesis before surfacing
            // the error (the chart papers over exactly this case). Only surface
            // the error when the series path also yields nothing.
            let fallback = await seriesFallbackRows(container: container)
            if fallback.isEmpty {
                error = err
            } else {
                measurements = fallback
                lastLoadedAt = .now
            }
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// Build 3 / item 3.3 — is a wider read still worth offering? Three gates,
    /// all honest:
    ///   1. the previous read came back FULL (`count >= pageLimit`) — a short
    ///      page already proves the server has nothing more;
    ///   2. we haven't hit the ceiling;
    ///   3. an earlier Load more hasn't already proven the end.
    /// While the first page is still loading the button stays hidden.
    ///
    /// Lives in the screen file (not the `+Fallbacks` sibling) because it reads
    /// file-private `@State`.
    private var canLoadMore: Bool {
        !reachedEnd
            && !isLoading
            && !measurements.isEmpty
            && measurements.count >= pageLimit
            && pageLimit < Self.maxPageLimit
    }

    /// Widen the window by one page and re-read. The repository is SWR-cached
    /// per `(kind, limit)`, so the wider key is a genuine new fetch rather than
    /// a cache hit returning the same rows.
    ///
    /// If the wider read does NOT return more rows than we already had, the
    /// server has no further history for this kind — latch `reachedEnd` so the
    /// footer retires instead of offering a button that can only disappoint.
    /// Edit mode as the bar's select switch; leaving it clears the choice.
    private var isSelecting: Binding<Bool> {
        Binding(
            get: { editMode.isEditing },
            set: { on in
                withAnimation(reduceMotion ? nil : .default) {
                    editMode = on ? .active : .inactive
                    if !on { selection = [] }
                }
            }
        )
    }

    private func loadMore() async {
        guard !isLoadingMore, canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let before = measurements.count
        pageLimit = min(pageLimit + Self.pageStep, Self.maxPageLimit)
        await load()
        if measurements.count <= before {
            reachedEnd = true
        }
    }

    /// Appear-revalidation entry point: load when empty (cold) OR when
    /// the 60s freshness window elapsed (partial-then-stale). The underlying
    /// `measurementsRepo` is SWR-cached so a re-validate inside its own TTL is
    /// served from cache.
    private func loadIfStale() async {
        let stale = lastLoadedAt.map { Date.now.timeIntervalSince($0) >= 60 } ?? true
        if measurements.isEmpty || stale {
            await load()
        }
    }

    // MARK: - Filtering

    //
    // Pure filter pipeline lives in `MeasurementListFilters.swift`
    // (`MeasurementListFilter.apply(...)`) so tests can lock the contract
    // without a SwiftUI render context and the screen stays under the
    // 600-line file-length baseline.

    /// Loads the `sourceEq`-scoped page for the active chip.
    /// An empty or failed server read clears `sourceFilteredRows`, falling
    /// back to the legacy client-side slice (series-synthesized rows have no
    /// deeper server page to offer).
    private func loadSourceFiltered() async {
        guard let container, let source = selectedSource else {
            sourceFilteredRows = nil
            return
        }
        do {
            let rows = try await container.measurementsRepo.recent(kind: kind, source: source)
            sourceFilteredRows = rows.isEmpty ? nil : rows
        } catch {
            HLLog.api.warning(
                "MeasurementList: sourceEq fetch failed for \(kind.rawValue, privacy: .public): \(LogSanitizer.redact(String(describing: error)))"
            )
            sourceFilteredRows = nil
        }
    }

    private func toggle(_ id: String) {
        if expandedSummaryIDs.contains(id) {
            expandedSummaryIDs.remove(id)
        } else {
            expandedSummaryIDs.insert(id)
        }
    }
}

// MARK: - Memoized filter / bucketing / search-debounce

/// Hosted in an extension so the C3 memoization helpers don't inflate the
/// main `MeasurementListScreen` body past the `type_body_length` budget
/// (the screen already splits rows + the pure filter pipeline out for the
/// same reason).
extension MeasurementListScreen {
    /// Pure filter pipeline, identical logic to the old `filteredMeasurements`
    /// computed property. Now called only from `recomputeFiltered()`
    /// (input-driven) instead of on every body pass. The debounced
    /// `debouncedSearchText` drives the query so typing doesn't re-filter
    /// per keystroke.
    func computeFiltered() -> [Measurement] {
        // Prefer the server-filtered page (`sourceEq`, as deep
        // as the unfiltered page) when the chip is active and the fetch
        // landed; the client filter stays as the instant paint while the
        // fetch is in flight AND as the offline/old-deploy fallback. The
        // `source:` re-apply on the server rows is a cheap no-op guard
        // (BP-merge keeps one source per merged row) + drives the search.
        // Locale-aware parse (de "5,5" + grouped "1.234,5" both
        // resolve); a non-empty-but-unparseable bound surfaces visibly via
        // `ValueRangeFilterControl` rather than silently dropping the filter.
        // The bounds are typed in the account's unit; the rows are
        // canonical SI. Invert once here so "150" on a lb account filters at
        // 68.04 kg, not at 150 kg.
        let lo = LocaleDecimalParser.parse(valueMinText).map { unitPreferences.canonicalValue(fromDisplayed: $0, kind: kind) }
        let hi = LocaleDecimalParser.parse(valueMaxText).map { unitPreferences.canonicalValue(fromDisplayed: $0, kind: kind) }
        if selectedSource != nil, let serverRows = sourceFilteredRows {
            return MeasurementListFilter.apply(
                serverRows,
                source: selectedSource,
                query: debouncedSearchText,
                valueMin: lo,
                valueMax: hi,
                dateFrom: dateFrom,
                dateTo: dateTo
            )
        }
        return MeasurementListFilter.apply(
            measurements,
            source: selectedSource,
            query: debouncedSearchText,
            valueMin: lo,
            valueMax: hi,
            dateFrom: dateFrom,
            dateTo: dateTo
        )
    }

    /// Recompute the filtered rows AND re-bucket them, storing both into
    /// `@State`. Bucketing was previously re-run inline in the `ForEach` on
    /// every render; it now runs once per input change alongside the filter.
    func recomputeFiltered() {
        let rows = computeFiltered()
        filteredCache = rows
        bucketedGroups = MeasurementBucketing.groups(MeasurementBucketing.sections(for: rows))
    }

    /// Debounce the search field. Each keystroke updates `searchText` (system
    /// search UI stays live) but the expensive re-filter only fires after the
    /// text settles for ~250ms via `debouncedSearchText`. An empty query
    /// settles immediately so clearing the field feels instant.
    func scheduleSearchDebounce(_ newValue: String) {
        searchDebounceTask?.cancel()
        if newValue.isEmpty {
            debouncedSearchText = ""
            return
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            debouncedSearchText = newValue
        }
    }
}

extension MeasurementListScreen {
    /// The rows of one bucket: the readings of a day, or a summary row with
    /// its readings under it while open. Server-derived rows stay read-only
    /// (no swipe, no selection).
    @ViewBuilder
    private func sectionRows(_ section: MeasurementSection) -> some View {
        switch section {
        case let .day(_, items):
            ForEach(items) { m in
                MeasurementSwipeRow(
                    measurement: m,
                    title: MeasurementBucketing.rowTitle(m.recordedAt),
                    onEdit: { editing = $0 },
                    onDelete: { await performDelete($0) }
                )
                .selectionDisabled(m.isServerDerivedReadOnly)
            }
        case let .weeklySummary(_, items), let .monthlySummary(_, items):
            MeasurementSummaryRow(
                period: MeasurementBucketing.summaryTitle(of: section) ?? "",
                kind: kind,
                items: items,
                isExpanded: expandedSummaryIDs.contains(section.id),
                toggle: { toggle(section.id) }
            )
            .selectionDisabled()
            if expandedSummaryIDs.contains(section.id) {
                ForEach(items) { m in
                    MeasurementRow(measurement: m)
                        .selectionDisabled(m.isServerDerivedReadOnly)
                }
            }
        }
    }

    /// The bottom bar's delete for the selected readings: trash and count.
    /// It asks through the `hlDeleteConfirmation()` around the screen.
    private var bulkDeleteButton: some View {
        HLDeleteButton(
            "Delete \(selection.count) entries",
            form: .bar,
            action: Self.bulkDeleteAction(count: selection.count) {
                await performBulkDelete()
            }
        )
        // The count is part of what the button says.
        .labelStyle(.titleAndIcon)
        .disabled(selection.isEmpty)
        .accessibilityIdentifier("measurements.list.bulkDelete")
    }
}

// `MeasurementRow`, `MeasurementSwipeRow`, `MeasurementSummaryRow` and the
// skeleton live in `MeasurementListRows.swift` so this file stays under the
// 600-line SwiftLint `file_length` limit.
