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
/// Typography: per-row value bumped from `hlMetric(.headline)` to
/// `hlMetric(.title3)` — the v0.4.0 review surfaced "die Daten sind viel
/// zu klein, man kann das nicht richtig sehen". Title3 metric numerals
/// match the dashboard tile vocabulary.
struct MeasurementListScreen: View {
    let kind: MetricKind

    @Environment(\.appContainer) private var container
    /// QoL-4 (A360-4) — routes the empty-state CTA to the capture sheet prefilled
    /// to this metric kind, so the empty list has a next step.
    @Environment(AppRouter.self) private var router
    /// A11Y (audit-v0162 §5) — gates the edit-mode toggle animations below so
    /// selection mode snaps instead of sliding when Reduce Motion is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var measurements: [Measurement] = []
    @State private var isLoading: Bool = false
    @State private var error: HLError?
    /// A2-M4 — appear-revalidation freshness stamp. Lets a re-entry re-validate
    /// the partial-then-stale case instead of only reloading when empty.
    @State private var lastLoadedAt: Date?
    @State private var searchText: String = ""
    /// v0.5.5.1 — optional per-source filter chip selection. `nil` means
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
    @State private var deleteConfirmTarget: Measurement?
    /// v0.14.8 W3 — native multi-select bulk delete (v1.15.13
    /// `POST /api/measurements/bulk-delete`). `editMode` drives the system
    /// Edit-mode selection circles; `selection` carries the picked row ids
    /// (raw `Measurement` rows only — chips / summary rows are
    /// `selectionDisabled`); `bulkDeleteRequested` raises the bottom-anchored
    /// destructive confirmation (b175 med-dialog pattern).
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []
    @State private var bulkDeleteRequested = false

    /// AUD-2 C3 — memoized filter/bucketing/sources outputs. Pre-fix these
    /// were computed properties (`filteredMeasurements`, `availableSources`)
    /// re-run on EVERY body pass — and `MeasurementBucketing.sections(...)`
    /// re-grouped the result inline in the `ForEach`. With 500-1000+ rows
    /// that meant a full-array filter + bucketing + section-diff per render,
    /// including per keystroke during search. These caches are recomputed
    /// only when an actual input changes (see `recomputeFiltered` / the
    /// debounced search pipeline), so typing and scrolling stay cheap.
    @State private var filteredCache: [Measurement] = []
    @State private var bucketedSections: [MeasurementSection] = []
    @State private var availableSourcesCache: [MeasurementSource] = []
    /// AUD-2 C3 — debounced mirror of `searchText`. The text field updates
    /// `searchText` on every keystroke (drives the system search UI), but the
    /// expensive re-filter keys off this debounced value (~250ms settle) so a
    /// fast typist re-filters once, not once per character.
    @State private var debouncedSearchText: String = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        List(selection: $selection) {
            // v0.5.5.1 — source-filter chip row mounted as the first list
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
                    .listRowInsets(EdgeInsets(top: HLSpace.xs, leading: HLSpace.lg, bottom: HLSpace.xs, trailing: HLSpace.lg))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    ValueRangeFilterControl(
                        isExpanded: $showValueRange,
                        minText: $valueMinText,
                        maxText: $valueMaxText,
                        unit: kind.unit
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: HLSpace.lg, bottom: HLSpace.xs, trailing: HLSpace.lg))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    // Build 3 / item 3.3 — date-range filter, mounted directly
                    // under the value range so the two optional filters read as
                    // one group.
                    DateRangeFilterControl(
                        isExpanded: $showDateRange,
                        from: $dateFrom,
                        to: $dateTo
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: HLSpace.lg, bottom: HLSpace.xs, trailing: HLSpace.lg))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                }
            }
            if filteredCache.isEmpty, !measurements.isEmpty, !isLoading {
                Section {
                    NoMatchesState()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                }
            }
            ForEach(bucketedSections, id: \.id) { section in
                switch section {
                case let .day(date, items):
                    Section {
                        ForEach(items) { m in
                            // #42 — COMPUTED (server-derived) rows are read-only:
                            // `MeasurementSwipeRow` drops the Edit/Delete swipe and
                            // multi-select is gated off here too.
                            MeasurementSwipeRow(
                                measurement: m,
                                onEdit: { editing = $0 },
                                onDelete: { deleteConfirmTarget = $0 }
                            )
                            .selectionDisabled(m.isServerDerivedReadOnly)
                        }
                    } header: {
                        MeasurementListSectionHeader(text: MeasurementBucketing.dayLabel(date: date))
                    }
                case let .weeklySummary(weekStart, items):
                    let id = section.id
                    Section {
                        MeasurementSummaryRow(
                            period: MeasurementBucketing.weekLabel(start: weekStart),
                            kind: kind,
                            items: items,
                            isExpanded: expandedSummaryIDs.contains(id),
                            toggle: { toggle(id) }
                        )
                        .selectionDisabled()
                        if expandedSummaryIDs.contains(id) {
                            ForEach(items) { m in
                                MeasurementRow(measurement: m)
                                    // #42 — COMPUTED rows stay read-only here too.
                                    .selectionDisabled(m.isServerDerivedReadOnly)
                            }
                        }
                    } header: {
                        MeasurementListSectionHeader(text: MeasurementBucketing.weekHeader(start: weekStart))
                    }
                case let .monthlySummary(monthStart, items):
                    let id = section.id
                    Section {
                        MeasurementSummaryRow(
                            period: MeasurementBucketing.monthLabel(start: monthStart),
                            kind: kind,
                            items: items,
                            isExpanded: expandedSummaryIDs.contains(id),
                            toggle: { toggle(id) }
                        )
                        .selectionDisabled()
                        if expandedSummaryIDs.contains(id) {
                            ForEach(items) { m in
                                MeasurementRow(measurement: m)
                                    // #42 — COMPUTED rows stay read-only here too.
                                    .selectionDisabled(m.isServerDerivedReadOnly)
                            }
                        }
                    } header: {
                        MeasurementListSectionHeader(text: MeasurementBucketing.monthHeader(start: monthStart))
                    }
                }
            }
            if measurements.isEmpty, !isLoading {
                MeasurementListEmptyState(onLog: { router.requestMeasure(prefill: kind) })
                    .selectionDisabled()
            }
            // Build 3 / item 3.3 — LOAD MORE, replacing the invisible 400-row
            // cap. NOT auto-triggered on scroll: an infinite scroll here would
            // silently pull thousands of rows through filtering + bucketing on
            // the main actor. An explicit tap keeps that cost visible.
            if canLoadMore {
                Section {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoadingMore {
                                ProgressView()
                            } else {
                                Text("measurements.list.loadMore")
                                    .font(.hlCaption.weight(.semibold))
                            }
                            Spacer()
                        }
                    }
                    .disabled(isLoadingMore)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    .accessibilityIdentifier("measurements.list.loadMore")
                }
            }
            // v0.14.8 W2-SYNCUX — canonical sync-status footer (same primitive
            // as Dashboard/Insights). Hosted as an empty section's FOOTER so
            // the self-suppressed state collapses to zero height (no phantom
            // row).
            Section {} footer: {
                HLSyncStatusFooter(screenLoading: isLoading)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // Canonical screen canvas (matches Mehr/Insights/Medis/Start) —
        // `HLColor.background` drifted bluish in dark mode.
        .background(HLSurface.primary)
        // v0.5.x C-9 — iOS 26+ soft scroll-edge so List content blurs into
        // the navigation Liquid Glass instead of clipping cleanly.
        // iOS 18-25: no-op (system stays flat-translucent).
        .hlScrollEdgeSoft()
        .navigationTitle(kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // v0.5.5.1 — expanded prompt reflects the wider search-scope
        // (note + source label + date label). Old "Notiz suchen" prompt
        // misled the user into thinking only notes are searchable.
        .searchable(text: $searchText, prompt: Text("Search measurement"))
        .refreshable { await load() }
        .task { await loadIfStale() }
        // v0.14.8 W3 — re-fetch the server-filtered page whenever the source
        // chip changes (and clear it when the filter is lifted).
        .task(id: selectedSource) { await loadSourceFiltered() }
        // AUD-2 C3 — memoization triggers. Recompute the filtered/bucketed
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
                // v0.5.5.1 (W-IMPL-SKELETON) — replaces the centered
                // spinner with a shape-aware silhouette of the upcoming
                // list. Eight rows cover the typical fold on iPhone 16/17
                // Pro at default Dynamic Type; the value + timestamp +
                // source-chip rhythm matches `MeasurementRow.body` so the
                // jump-cut to live content stays small.
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
            } onDismiss: {
                editing = nil
            }
            .hlSheetPresentation(.form)
        }
        .hlConfirmDestructive(
            Text("Messung löschen?"),
            isPresented: Binding(get: { deleteConfirmTarget != nil }, set: { if !$0 { deleteConfirmTarget = nil } }),
            // v0.11 W26 — the delete is now reversible via the Rückgängig
            // toast, so the old "cannot be undone" warning is dropped.
            message: Text("measurement.delete.confirm.message"),
            confirm: Text("Delete"),
            cancel: Text("Cancel"),
            onCancel: { deleteConfirmTarget = nil },
            action: {
                if let target = deleteConfirmTarget {
                    Task { await performDelete(target) }
                }
                deleteConfirmTarget = nil
            }
        )
        // v0.14.8 W3 — native Edit-mode multi-select. The trailing button
        // toggles edit mode (selection circles on the raw rows); the bottom
        // bar carries the destructive bulk action while editing. Swipe
        // actions are system-suppressed during edit mode.
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !measurements.isEmpty {
                    Button(editMode.isEditing ? String(localized: "Done") : String(localized: "Select")) {
                        withAnimation(reduceMotion ? nil : .default) {
                            if editMode.isEditing {
                                editMode = .inactive
                                selection = []
                            } else {
                                editMode = .active
                            }
                        }
                    }
                }
            }
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button(role: .destructive) {
                        bulkDeleteRequested = true
                    } label: {
                        Label {
                            Text("Delete \(selection.count) entries")
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        // b175 operator fix (cf9 / MedicationDetailScreen) — on iOS 26,
        // `confirmationDialog` anchors its Liquid-Glass bubble to the
        // interaction source, which floats the confirmation mid-screen.
        // Attaching the dialog to a bottom-pinned, hit-test-disabled anchor
        // pins the presentation to the screen's bottom edge; on iOS 18–25
        // the attachment point is ignored on iPhone (classic bottom action
        // sheet), so the anchor is a no-op there.
        .overlay(alignment: .bottom) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .hlConfirmDestructive(
                    Text("Delete \(selection.count) measurements?"),
                    isPresented: $bulkDeleteRequested,
                    message: Text("measurements.bulkDelete.confirm.message"),
                    confirm: Text(String(localized: "Delete")),
                    cancel: Text(String(localized: "Cancel")),
                    action: {
                        Task { await performBulkDelete() }
                    }
                )
        }
        // v0.11 W26 — re-sync the local list whenever the store's measurement
        // set changes. `MeasurementsStore.delete` (and its undo-restore)
        // mutate `store.recent`; reloading from `repo.recent(kind:)` reflects
        // the server truth so a restored row re-appears on this drill-down.
        .onChange(of: container?.measurementsStore.recent.count) { _, _ in
            Task { await load() }
        }
    }

    private func performDelete(_ measurement: Measurement) async {
        guard let container else { return }
        // v0.11 W26 — route through `MeasurementsStore.delete`, which owns the
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

    /// v0.14.8 W3 — bulk variant of `performDelete`. Resolves the selected
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
            // v0.14.3 E5 — series fallback. The chart-detail page synthesizes
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

    /// A2-M4 — appear-revalidation entry point: load when empty (cold) OR when
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
    // v0.5.5.1 — pure filter pipeline lives in `MeasurementListFilters.swift`
    // (`MeasurementListFilter.apply(...)`) so tests can lock the contract
    // without a SwiftUI render context and the screen stays under the
    // 600-line file-length baseline.

    /// v0.14.8 W3 — loads the `sourceEq`-scoped page for the active chip.
    /// An empty or failed server read clears `sourceFilteredRows`, falling
    /// back to the legacy client-side slice (series-synthesized rows and
    /// standalone snapshots have no deeper server page to offer).
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

// MARK: - AUD-2 C3 — memoized filter / bucketing / search-debounce

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
        // v0.14.8 W3 — prefer the server-filtered page (`sourceEq`, as deep
        // as the unfiltered page) when the chip is active and the fetch
        // landed; the client filter stays as the instant paint while the
        // fetch is in flight AND as the offline/old-deploy fallback. The
        // `source:` re-apply on the server rows is a cheap no-op guard
        // (BP-merge keeps one source per merged row) + drives the search.
        // A360-5 H-4 — locale-aware parse (de "5,5" + grouped "1.234,5" both
        // resolve); a non-empty-but-unparseable bound surfaces visibly via
        // `ValueRangeFilterControl` rather than silently dropping the filter.
        let lo = LocaleDecimalParser.parse(valueMinText)
        let hi = LocaleDecimalParser.parse(valueMaxText)
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
        bucketedSections = MeasurementBucketing.sections(for: rows)
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

// v0.14.8 W3 — `MeasurementListSectionHeader`, `MeasurementRow`,
// `MeasurementSummaryRow`, `MeasurementListEmptyState` and the skeleton live
// in `MeasurementListRows.swift` so this file stays under the 600-line
// SwiftLint `file_length` baseline after the multi-select bulk-delete
// affordances landed (same split `MeasurementBucketing.swift` and
// `MeasurementListFilters.swift` went through in v0.5.5.1).
