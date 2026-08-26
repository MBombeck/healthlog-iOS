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
    @State private var searchText = ""
    @State private var selectionMode = false
    @State private var showUpload = false
    @State private var isEnabled = true
    @State private var searchDebounce: Task<Void, Never>?
    /// Wave 4.6 — the bounded post-upload poll (see ``pollWhileProcessing()``).
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
                    .overlay(alignment: .bottom) { bulkBar }
            } else {
                DocumentsOptInView { await enableAndReload() }
            }
        }
        .navigationTitle(Text("documents.list.title"))
        .navigationBarTitleDisplayMode(.inline)
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
    private var isModuleAvailable: Bool {
        isEnabled && store?.isDisabled != true
    }

    /// Everything that only makes sense against a live module. Search, filter,
    /// upload and selection are attached HERE — and the upload sheet and the
    /// bulk bar inside the `if` arm above — rather than to the screen, so the
    /// disabled branch cannot inherit a single one of them: a modifier applied
    /// outside the `if` is applied in both arms, which is exactly how search,
    /// multi-select and upload ended up live over the enable-CTA.
    private var enabledBody: some View {
        listBody
            .toolbar { toolbar }
            .searchable(text: $searchText, prompt: Text("documents.filter.searchPlaceholder"))
            .onChange(of: searchText) { _, newValue in debounceSearch(newValue) }
    }

    // MARK: - List body

    private var listBody: some View {
        HLAsyncListScreen(
            phase: phase,
            refresh: { await store?.load() },
            loading: { loadingRows },
            empty: { emptyRows },
            content: { if let store { loadedRows(store: store) } }
        )
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
    private func loadedRows(store: DocumentsStore) -> some View {
        if let message = store.lastError {
            Section { outcomeBanner(message, store: store) }
        }
        if let usage = store.usage {
            Section { DocumentUsageBar(usage: usage) }
        }
        if store.filter.isActive {
            Section {
                activeFilterRow(store: store)
            }
        }
        Section {
            ForEach(store.documents) { document in
                documentRow(document, store: store)
            }
            if store.nextCursor != nil {
                loadMoreRow(store: store)
            }
        }
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    @ViewBuilder
    private func documentRow(_ document: InboundDocument, store: DocumentsStore) -> some View {
        let row = DocumentCardRow(
            document: document,
            selectionMode: selectionMode,
            isSelected: store.isSelected(document.id),
            isHighlighted: store.highlightedDocumentId == document.id
        )
        if selectionMode {
            Button { store.toggleSelection(document.id) } label: { row }
                .buttonStyle(.plain)
        } else {
            NavigationLink {
                DocumentDetailScreen(store: store, documentId: document.id, initialDocument: document)
            } label: { row }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await deleteRow(document, store: store) }
                    } label: {
                        Label("documents.bulk.delete", systemImage: "trash")
                    }
                }
        }
    }

    private func loadMoreRow(store: DocumentsStore) -> some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Text("documents.timeline.loadingMore")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            Spacer()
        }
        .listRowSeparator(.hidden)
        .task { await store.loadMore() }
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
            Button("documents.outcome.dismiss") { store.acknowledgeOutcome() }
                .font(.hlCaption)
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
            Button("documents.filter.clear") {
                Task { await store.clearFilter() }
            }
        }
        .font(.hlCaption)
        .foregroundStyle(HLText.secondary)
        // Audit-01 C2 — 16pt gutter (`HLSpace.lg`) like every sibling tab; the
        // former `.md` (12pt) left the whole Documents content 4pt off-grid.
        .listRowInsets(EdgeInsets(top: HLSpace.xs, leading: HLSpace.lg, bottom: HLSpace.xs, trailing: HLSpace.lg))
        .accessibilityElement(children: .combine)
    }

    private var emptyRows: some View {
        Section {
            let filtered = store?.filter.isActive == true
            HLEmptyState(
                icon: filtered ? "line.3.horizontal.decrease.circle" : "folder",
                title: LocalizedStringKey(filtered ? "documents.empty.noMatchesTitle" : "documents.empty.title"),
                message: LocalizedStringKey(filtered ? "documents.empty.noMatchesDescription" : "documents.empty.description")
            ) {
                if filtered {
                    HLButton("documents.filter.clear", icon: "xmark", variant: .secondary) {
                        Task { await store?.clearFilter() }
                    }
                } else {
                    HLButton("documents.empty.action", icon: "arrow.up.doc", variant: .primary) {
                        showUpload = true
                    }
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Bulk bar

    @ViewBuilder
    private var bulkBar: some View {
        if let store, selectionMode, !store.selection.isEmpty {
            DocumentBulkBar(store: store, conditionChips: store.conditionChips)
                // Audit-01 C2 — 16pt gutter, matching the sibling tabs.
                .padding(.horizontal, HLSpace.lg)
                .padding(.bottom, HLSpace.sm)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let store, !selectionMode {
            ToolbarItem(placement: .topBarTrailing) {
                DocumentFilterMenu(
                    filter: store.filter,
                    conditionChips: store.conditionChips,
                    years: store.years,
                    apply: { next in Task { await store.applyFilter(next) } },
                    clear: { Task { await store.clearFilter() } }
                )
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                withAnimation {
                    selectionMode.toggle()
                    if !selectionMode { store?.clearSelection() }
                }
            } label: {
                if selectionMode {
                    Text("documents.selection.done")
                } else {
                    Label("documents.selection.select", systemImage: "checklist")
                }
            }
            .accessibilityIdentifier("documents.toolbar.select")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showUpload = true
            } label: {
                Label("documents.pageUpload", systemImage: "arrow.up.doc")
            }
            .accessibilityIdentifier("documents.toolbar.upload")
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

    // MARK: - Bounded processing poll (Wave 4.6)

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
            HLButton("documents.optIn.action", icon: "checkmark.circle", variant: .primary, isLoading: isEnabling) {
                Task {
                    isEnabling = true
                    await onEnable()
                    isEnabling = false
                }
            }
            .accessibilityIdentifier("documents.optIn.enable")
        }
    }
}
