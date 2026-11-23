import SwiftUI

/// Native "Dokumente" document-vault browse surface — the opt-in `inboundDocuments`
/// module's home. Lists the caller's stored documents (server-pinned
/// `documentDate desc`), filterable by search / kind / condition / year, with a
/// usage-quota bar, upload + scan entry, multi-select bulk actions, and a
/// tap-through to the detail sheet.
///
/// Reached from the (opt-in) "Health & care" `MoreScreen` row. Self-gates to an
/// enable-CTA when the module is off (or a route 403's mid-flight).
///
/// **Store wiring** mirrors `IllnessJournalScreen`: prefers the container-owned
/// `documentsStore` (joins the logout cascade), falling back to the factory.
struct DocumentsScreen: View {
    @Environment(\.appContainer) private var container

    @State private var store: DocumentsStore?
    /// The document whose preview stands beside the list. Screen state, not a
    /// second navigation stack: it survives a change of width and resolves to
    /// nothing once the document is gone from the list.
    @State private var paneSelection = HLPaneSelection<String>()
    @State private var searchText = ""
    @State private var selectionMode = false
    @State private var showUpload = false
    @State private var isEnabled = true
    @State private var searchDebounce: Task<Void, Never>?
    /// The bounded post-upload poll (see ``pollWhileProcessing()``).
    @State private var processingPoll: Task<Void, Never>?
    /// Pre-linked episode when the vault is opened from an illness episode card.
    let preselectedEpisodeId: String?

    init(preselectedEpisodeId: String? = nil) {
        self.preselectedEpisodeId = preselectedEpisodeId
    }

    var body: some View {
        Group {
            if isModuleAvailable {
                enabledBody
                    .sheet(isPresented: $showUpload, onDismiss: startProcessingPollIfNeeded) {
                        if let store {
                            DocumentUploadSheet(store: store, preselectedEpisodeId: preselectedEpisodeId)
                        }
                    }
                    // Asks for the bulk bar's delete; it hangs around the
                    // toolbar so the button in the bottom bar reaches it.
                    .hlDeleteConfirmation()
            } else if let reason = moduleOffReason {
                // **Audit A-7 —** the module is off for a reason that is not the
                // viewer's own switch (`not_granted` / `unavailable` / a state
                // this build cannot name). The opt-in CTA there invites a PATCH
                // the server refuses, so the server's own sentence takes its
                // place and nothing offers a flip.
                FeatureDisabledCard(variant: .hero, reason: reason)
                    .padding()
                    .hlCenteredOnReadableWidth()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                DocumentsOptInView { await enableAndReload() }
            }
        }
        // Inline when pushed; as a sidebar tab the list heads itself.
        .hlSectionRootTitle(Text("documents.list.title"), headsItself: isModuleAvailable && !phase.isError)
        .task { await onAppear() }
        .onDisappear {
            processingPoll?.cancel()
            processingPoll = nil
        }
    }

    /// Whether the module is available *right now* — the gate the screen read
    /// on appear AND the answer the last route gave it.
    ///
    /// These were two flags before, and the toolbar was gated on the first
    /// while the content switched on the second, so a `403` landing mid-flight
    /// swapped the list for the enable-CTA and left search, multi-select and
    /// upload live over it — every one of them pointing at a module that is off.
    /// The guardian of a managed profile gets the profile's own reading
    /// switch above the list (server v1.48.0).
    private var isGuardianOfManagedProfile: Bool {
        guard let authStore = container?.authStore, case let .authenticated(user) = authStore.phase else { return false }
        return ManagedProfileContext.isGuardian(user.accountAccess)
    }

    private var isModuleAvailable: Bool {
        isEnabled && store?.isDisabled != true
    }

    /// **The server's sentence when the module is off for a reason
    /// that is not the viewer's own switch**, `nil` when the opt-in CTA still
    /// applies (`disabled`, or no verdict from the server at all).
    private var moduleOffReason: String? {
        guard case let .explain(reason) = container?.moduleGate.optInPresentation(.inboundDocuments) else {
            return nil
        }
        return reason
    }

    /// Everything that only makes sense against a live module. Search, filter,
    /// upload and selection are attached HERE — and the upload sheet and the
    /// bulk bar inside the `if` arm above — rather than to the screen, so the
    /// disabled branch cannot inherit a single one of them: a modifier applied
    /// outside the `if` is applied in both arms, which is exactly how search,
    /// multi-select and upload ended up live over the enable-CTA.
    private var enabledBody: some View {
        listBody
            .navigationDestination(for: DocumentRoute.self) { route in
                if let store {
                    DocumentDetailScreen(store: store, documentId: route.document.id, initialDocument: route.document)
                }
            }
            .hlPageActions(pageActions)
            .toolbar { bulkBar }
            // While selecting, the tab bar gives way to the bottom bar that
            // carries the bulk actions; it would otherwise cover it.
            .toolbar(selectionMode ? .hidden : .visible, for: .tabBar)
            .searchable(text: $searchText, prompt: Text("documents.filter.searchPrompt"))
            .onChange(of: searchText) { _, newValue in debounceSearch(newValue) }
    }

    // MARK: - List body

    private var listBody: some View {
        // The pane stays while a new filter or search replaces the rows (the
        // phase then reads loading); it leaves only with the last row.
        HLListDetail(detailAvailable: store.map { !$0.documents.isEmpty } ?? false) { layout in
            HLAsyncListScreen(
                phase: phase,
                refresh: { await store?.load() },
                loading: {
                    SectionRootHeader("documents.list.title", inList: true)
                    loadingRows
                },
                empty: {
                    SectionRootHeader("documents.list.title", inList: true)
                    emptyRows
                },
                content: {
                    SectionRootHeader("documents.list.title", inList: true)
                    if let store { loadedRows(store: store, layout: layout) }
                }
            )
            .hlPageMargins()
        } detail: {
            detailPane
        }
    }

    /// The selected document's preview beside the list, a quiet note while
    /// none is selected or the selected one was deleted.
    @ViewBuilder
    private var detailPane: some View {
        if let store, let id = paneSelection.resolved(in: store.documents.map(\.id)),
           let document = store.documents.first(where: { $0.id == id })
        {
            DocumentPane(store: store, document: document)
                // One preview per document: its bytes load once for it.
                .id(document.id)
        } else {
            DocumentPanePlaceholder()
        }
    }

    /// `.loaded` used to be returned whenever the snapshot was non-empty, with
    /// no reference to `isLoading` at all — so while a new filter was in flight
    /// the previous filter's rows stayed fully rendered and the user read a list
    /// answering a question they had already replaced. The store now records
    /// which question its snapshot answers, so this can distinguish a genuine
    /// replacement (blank it) from a plain refresh of the same facets (keep it,
    /// or the four-second processing poll would flash a skeleton every time).
    private var phase: HLAsyncListPhase {
        guard let store else { return .loading }
        if store.isReplacingContent { return .loading }
        if store.documents.isEmpty {
            if store.isLoading { return .loading }
            if store.lastError != nil { return .error(retry: { await store.load() }) }
            return .empty
        }
        return .loaded
    }

    /// The in-flight state. The skeleton is a *silhouette* — it says "rows will
    /// appear here", which is not the same statement as "your newest question
    /// is still being answered", and nothing in it is legible to an assistive
    /// technology or an automated check as a loading state. The spinner says it.
    @ViewBuilder
    private var loadingRows: some View {
        Section {
            ProgressView("documents.list.loading")
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("documents.list.loading")
        }
        HLAsyncListSkeletonRows()
    }

    @ViewBuilder
    private func loadedRows(store: DocumentsStore, layout: HLListDetailLayout.Resolution) -> some View {
        let paneID = paneSelection.highlighted(isSideBySide: layout.isSideBySide, in: store.documents.map(\.id))
        if let message = store.lastError {
            Section { outcomeBanner(message, store: store) }
                .hlFormRowSurface()
        }
        if let usage = store.usage {
            Section { DocumentUsageBar(usage: usage) }
                .hlFormRowSurface()
        }
        if let container, isGuardianOfManagedProfile {
            ManagedProfileDocumentSettingsSection(repository: RecordSettingsRepository(api: container.api))
        }
        if store.filter.isActive {
            Section {
                activeFilterRow(store: store)
            }
            .hlFormRowSurface()
        }
        Section {
            ForEach(store.documents) { document in
                documentRow(document, store: store, layout: layout, paneID: paneID)
            }
            // The last row loads the next page by itself.
            HLLoadMoreRow(hasMore: store.nextCursor != nil, isLoading: store.isLoadingMore, trigger: .onAppear) {
                Task { await store.loadMore() }
            }
            .listRowSeparator(.hidden)
        }
        .hlFormRowSurface()
        recentlyDeletedSection(store: store)
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    @ViewBuilder
    private func documentRow(
        _ document: InboundDocument,
        store: DocumentsStore,
        layout: HLListDetailLayout.Resolution,
        paneID: String?
    ) -> some View {
        let row = DocumentCardRow(
            document: document,
            selectionMode: selectionMode,
            isSelected: store.isSelected(document.id),
            isHighlighted: store.highlightedDocumentId == document.id,
            isPaneSelected: !selectionMode && paneID == document.id
        )
        if selectionMode {
            HLRowButton { store.toggleSelection(document.id) } label: { row }
        } else if layout.isSideBySide {
            // Beside the preview a tap selects; the page opens from the pane.
            HLRowButton { paneSelection.select(document.id) } label: { row }
                .accessibilityAddTraits(paneID == document.id ? .isSelected : [])
                .hlSwipeDelete(.confirmed(title: "documents.detail.deleteConfirm.title") {
                    await deleteRow(document, store: store)
                })
        } else {
            // A data row: the whole row opens the document, without a chevron.
            row
                .hlRowLink(inList: true, value: DocumentRoute(document: document))
                // A document takes its links and summary along: asked first.
                .hlSwipeDelete(.confirmed(title: "documents.detail.deleteConfirm.title") {
                    await deleteRow(document, store: store)
                })
        }
    }

    /// The current operation's outcome, on the loaded surface.
    ///
    /// `HLAsyncListScreen`'s error phase only exists when there is nothing to
    /// show, so before this every failure that arrived over a populated list —
    /// a half-refused bulk action, a delete the server rejected — was written
    /// into `lastError` and rendered nowhere. The ids the operation could not
    /// apply are still selected, so the bulk bar underneath is the retry; this
    /// is the sentence that says why it is still open.
    private func outcomeBanner(_ message: String, store: DocumentsStore) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HLColor.statusBad)
            Text(verbatim: message)
                .font(.hlCaption)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.sm)
            HLLinkButton("documents.outcome.dismiss", alignment: .leading) { store.acknowledgeOutcome() }
                .fixedSize()
        }
        .listRowInsets(EdgeInsets(top: HLSpace.xs, leading: HLSpace.lg, bottom: HLSpace.xs, trailing: HLSpace.lg))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("documents.outcome.banner")
    }

    /// A single subtle row shown while any facet is active — a calm, native
    /// "Gefiltert" status line (Files/Mail style) with an inline clear button, so
    /// the active-filter state stays visible and clearable without a heavy chip
    /// rail. The facets themselves live in the toolbar ``DocumentFilterMenu``.
    private func activeFilterRow(store: DocumentsStore) -> some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
            Text("documents.filter.activeLabel")
            Spacer()
            HLLinkButton("documents.filter.clear", alignment: .leading) {
                Task { await store.clearFilter() }
            }
            .fixedSize()
        }
        .hlText(.rowSubtitle)
        // 16pt gutter (`HLSpace.lg`) like every sibling tab; the
        // former `.md` (12pt) left the whole Documents content 4pt off-grid.
        .listRowInsets(EdgeInsets(top: HLSpace.xs, leading: HLSpace.lg, bottom: HLSpace.xs, trailing: HLSpace.lg))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var emptyRows: some View {
        Section {
            let filtered = store?.filter.isActive == true
            HLEmptyState(
                icon: filtered ? "line.3.horizontal.decrease.circle" : "folder",
                title: LocalizedStringKey(filtered ? "documents.empty.noMatchesTitle" : "documents.empty.title"),
                // A filtered empty list says its title and offers
                // the reset; the sentence that repeated the title is gone.
                // Without a filter the one action uploads the first document
                // where the eye already is; the plus in the bar stays.
                message: filtered ? nil : LocalizedStringKey("documents.empty.description")
            ) {
                if filtered {
                    HLButton("documents.filter.clear", systemImage: "xmark", variant: .secondary) {
                        Task { await store?.clearFilter() }
                    }
                } else {
                    HLButton("documents.empty.add", systemImage: "plus", variant: .secondary) { showUpload = true }
                        .accessibilityIdentifier("documents.empty.add")
                }
            }
            .hlFreeAreaListRow()
        }
        if let store { recentlyDeletedSection(store: store) }
    }

    /// The centred link to Recently deleted, only while the server
    /// counts a deleted document (never before v1.46.0, never in a shared record).
    /// It sits in a section footer, like the "Advanced" text
    /// links: as a list row the `NavigationLink` drew the system chevron at the
    /// trailing edge beside the centred text.
    @ViewBuilder
    private func recentlyDeletedSection(store: DocumentsStore) -> some View {
        if RecentlyDeletedDocumentsLink.isOffered(store.usage), let count = store.usage?.deletedCount {
            Section {} footer: { RecentlyDeletedDocumentsLink(vault: store, count: count) }
        }
    }

    // MARK: - Toolbar

    private func toggleSelectionMode() {
        withAnimation {
            selectionMode.toggle()
            if !selectionMode { store?.clearSelection() }
        }
    }

    /// Two symbols in the bar, so the inline title stays centred like on
    /// every other pushed page: the list menu (selecting, then the filter)
    /// and adding outermost. While selecting, a single check mark ends it.
    private var pageActions: HLTabHeaderActions {
        if selectionMode {
            return [
                HLTabHeaderAction(
                    role: .select,
                    systemImage: "checkmark",
                    label: "documents.selection.done",
                    identifier: "documents.toolbar.select",
                    isSelected: false,
                    kind: .button(toggleSelectionMode)
                )
            ]
        }
        var items: [HLTabHeaderAction] = []
        if let store {
            items.append(.filter(
                label: "documents.filter.groupLabel",
                identifier: "documents.toolbar.filter",
                isSelected: store.filter.isActive
            ) {
                Section {
                    Button("documents.selection.select", systemImage: "checklist", action: toggleSelectionMode)
                        .accessibilityIdentifier("documents.toolbar.select")
                }
                DocumentFilterMenu(
                    filter: store.filter,
                    conditionChips: store.conditionChips,
                    years: store.years,
                    apply: { next in Task { await store.applyFilter(next) } },
                    clear: { Task { await store.clearFilter() } }
                )
            })
        }
        items.append(.add(label: "documents.pageUpload", identifier: "documents.toolbar.upload") { showUpload = true })
        return HLTabHeaderActions(items)
    }

    /// The bulk actions while documents are selected, in the system bottom
    /// bar.
    @ToolbarContentBuilder
    private var bulkBar: some ToolbarContent {
        if let store, selectionMode, !store.selection.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
                DocumentBulkBar(store: store, conditionChips: store.conditionChips)
            }
        }
    }

    // MARK: - Lifecycle

    private func onAppear() async {
        isEnabled = container?.moduleGate.isEnabled(.inboundDocuments) != false
        if store == nil {
            store = container?.documentsStore ?? container.map(DocumentsScreenFactory.makeStore(container:))
        }
        // Pre-apply the episode filter when opened from an illness card.
        if let preselectedEpisodeId, store?.filter.episodeId == nil {
            var next = store?.filter ?? DocumentListFilter()
            next.episodeId = preselectedEpisodeId
            await store?.applyFilter(next)
        } else {
            await store?.load()
        }
        startProcessingPollIfNeeded()
    }

    // MARK: - Bounded processing poll

    /// Hard cap on the post-upload poll — 15 attempts × 4 s ≈ 1 min of watching,
    /// well inside the 3-minute processing window. Bounded on BOTH ends: the
    /// window closes the chip, this cap closes the poll. Nothing here loops
    /// forever, and the task is cancelled when the screen disappears.
    private static let maxProcessingPollAttempts = 15
    /// The web's `refetchInterval` while any document is still processing.
    private static let processingPollInterval: UInt64 = 4_000_000_000

    /// Start watching only when a document is actually inside its processing
    /// window and no poll is already running.
    private func startProcessingPollIfNeeded() {
        guard processingPoll == nil, let store,
              DocumentFormat.hasProcessingDocument(store.documents) else { return }
        processingPoll = Task { await pollWhileProcessing() }
    }

    /// The auto-index (+ background AI summary) job that runs right after upload
    /// is fire-and-forget server-side — nothing pushes its completion to the
    /// client, so without this the "Wird verarbeitet…" chip and the freshly
    /// generated summary only appear on a manual reload. Re-list every 4 s while
    /// something is still processing, and stop at the first quiet round or the
    /// attempt cap.
    private func pollWhileProcessing() async {
        defer { processingPoll = nil }
        for _ in 0 ..< Self.maxProcessingPollAttempts {
            try? await Task.sleep(nanoseconds: Self.processingPollInterval)
            guard !Task.isCancelled, let store else { return }
            guard DocumentFormat.hasProcessingDocument(store.documents) else { return }
            await store.load()
        }
    }

    private func enableAndReload() async {
        _ = await container?.moduleGate.setEnabled(.inboundDocuments, enabled: true)
        isEnabled = container?.moduleGate.isEnabled(.inboundDocuments) != false
        await store?.load()
    }

    private func debounceSearch(_ text: String) {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let store else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var next = store.filter
            next.q = trimmed.isEmpty ? nil : String(trimmed.prefix(100))
            await store.applyFilter(next)
        }
    }

    private func deleteRow(_ document: InboundDocument, store: DocumentsStore) async {
        await store.delete(document, undoMessage: String(localized: "documents.toast.deleted"))
    }
}

// MARK: - DocumentsOptInView

/// The enable-CTA shown when the `inboundDocuments` module is off. Enabling flips
/// the module on via `ModuleGate` and reloads.
struct DocumentsOptInView: View {
    let onEnable: () async -> Void
    @State private var isEnabling = false

    var body: some View {
        HLEmptyState(
            icon: "folder.badge.plus",
            title: "documents.optIn.title",
            message: "documents.optIn.description"
        ) {
            HLButton("documents.optIn.action", systemImage: "checkmark.circle", variant: .secondary, isLoading: isEnabling) {
                Task {
                    isEnabling = true
                    await onEnable()
                    isEnabling = false
                }
            }
            .accessibilityIdentifier("documents.optIn.enable")
        }
        .hlCenteredOnReadableWidth()
    }
}
