import SwiftUI

/// Native illness / condition-journal surface (v1.18.1 `W-B`; default-on since
/// v1.18.3). The default destination: it lists episodes (newest-first by onset),
/// filterable active / resolved, with neutral type + lifecycle badges. When a
/// user has DISABLED the module (`ModuleGate.isEnabled(.illness) == false`) it
/// self-gates to ``IllnessOptInScreen`` as a graceful re-enable path.
///
/// Reached from the (default-on) "Health records" `MoreScreen` row and from the
/// `SettingsModulesScreen` illness toggle. The insights screen is reached from
/// this screen's toolbar.
///
/// **Store wiring.** Builds its ``IllnessStore`` lazily from `appContainer`
/// (mirrors `LabsScreen`); the reconcile pass SHOULD promote it to a
/// container-owned singleton.
struct IllnessJournalScreen: View {
    @Environment(\.appContainer) private var container

    @State private var store: IllnessStore?
    @State private var showAddSheet = false
    @State private var showInsights = false
    @State private var editingEpisode: IllnessEpisodeDTO?
    @State private var includeResolved = true
    @State private var deleteConfirmation = IllnessDeleteConfirmation()
    @State private var showDeleteConfirmation = false
    /// Re-evaluated each appear so an opt-in flip flips us from the opt-in
    /// screen to the list without a manual reload.
    @State private var isEnabled = true

    var body: some View {
        Group {
            if !isEnabled {
                IllnessOptInScreen(onEnabled: {
                    isEnabled = true
                    Task { await reload() }
                })
            } else if store?.isDisabled == true {
                // The module 403'd mid-flight — fall back to the re-enable surface.
                IllnessOptInScreen(onEnabled: {
                    Task { await reload() }
                })
            } else {
                // v0151 nav-scroll RCA-2: STABLE SCROLL ROOT. The body used to swap
                // its root from a bare `ProgressView` to a `List` after the async
                // load resolved — re-binding the `.large` title bar to a
                // late-appearing scroll view (the residual the v0150 inner-spine fix
                // did not cover). `HLAsyncListScreen` renders the `List` root from
                // frame 1 (skeleton / empty / loaded are rows INSIDE it); the v0150
                // stable section spine lives in `loadedRows` below.
                HLAsyncListScreen(
                    phase: phase,
                    refresh: { await reload() },
                    loading: { HLAsyncListSkeletonRows() },
                    empty: { emptyRows },
                    content: { if let store { loadedRows(store: store) } }
                )
            }
        }
        .navigationTitle(Text("illness.journal.title"))
        // V1 — `.inline` (not `.large`). See LabsScreen: a `.large` title +
        // trailing toolbar on the titleless More root re-resolves a nav-bar
        // inset on pop and shifts the More list down. `.inline` removes it.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if isEnabled { toolbar } }
        .task { await onAppear() }
        .sheet(isPresented: $showAddSheet) {
            if let store {
                AddEpisodeSheet(store: store)
            }
        }
        .sheet(item: $editingEpisode) { episode in
            if let store {
                EditEpisodeSheet(store: store, episode: episode)
            }
        }
        .navigationDestination(isPresented: $showInsights) {
            if let store {
                IllnessInsightsScreen(store: store)
            }
        }
        .hlConfirmDestructive(
            Text("illness.delete.confirm.title"),
            isPresented: $showDeleteConfirmation,
            confirm: Text("illness.delete.action"),
            cancel: Text("illness.action.cancel"),
            onCancel: { deleteConfirmation.cancel() },
            action: {
                guard let candidate = deleteConfirmation.confirm(), let store else { return }
                Task { await deleteRow(candidate, store: store) }
            }
        )
        .onChange(of: showDeleteConfirmation) { _, isPresented in
            if !isPresented {
                deleteConfirmation.cancel()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showInsights = true
            } label: {
                Label("illness.insights.title", systemImage: "chart.bar.xaxis")
            }
            .accessibilityIdentifier("illness.toolbar.insights")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showAddSheet = true
            } label: {
                Label("illness.add.title", systemImage: "plus")
            }
            .accessibilityIdentifier("illness.toolbar.add")
        }
    }

    /// Maps store state to the stable-root render phase. `nil` store and the first
    /// in-flight load render the skeleton; no episodes (settled) → empty; otherwise
    /// the real list. `isDisabled` is handled in the outer `body` (opt-in surface).
    private var phase: HLAsyncListPhase {
        guard let store else { return .loading }
        if store.episodes.isEmpty {
            if store.isLoading { return .loading }
            // AUD-5 H1 — a failed fetch with no cached episodes is an ERROR, not
            // an empty journal. Offer Retry instead of "Add your first…".
            if store.lastError != nil {
                return .error(retry: { await reload() })
            }
            return .empty
        }
        return .loaded
    }

    // Loaded-phase rows.
    //
    // v0150 nav-scroll RCA (Bug 2): STABLE SECTION SPINE. The active / resolved
    // sections used to be wrapped in `if !…isEmpty { Section }`, so a reload that
    // flipped a bucket empty/non-empty (delete / restore / list refresh updates
    // `episodes`) INSERTED or REMOVED a whole `.insetGrouped` section
    // node above the user's scroll position. The sections are now ALWAYS present
    // (stable node count + order); only their leaf rows change. `ForEach` over an
    // empty bucket renders no rows, and an empty `Section` collapses, so the visual
    // result is unchanged while the scroll offset survives the reload.

    @ViewBuilder
    private func loadedRows(store: IllnessStore) -> some View {
        let groups = IllnessPresentation.groupEpisodes(store.episodes)
        let activeGroups = groups.filter(\.parent.isActive)
        let resolvedGroups = groups.filter { !$0.parent.isActive }
        Section {
            Toggle("illness.journal.showResolved", isOn: $includeResolved)
                .accessibilityIdentifier("illness.journal.showResolvedToggle")
        }
        Section {
            ForEach(activeGroups) { group in
                episodeGroup(group, store: store)
            }
        } header: {
            if !activeGroups.isEmpty {
                Text("illness.journal.section.active")
            }
        }
        Section {
            if includeResolved {
                ForEach(resolvedGroups) { group in
                    episodeGroup(group, store: store)
                }
            }
        } header: {
            if includeResolved, !resolvedGroups.isEmpty {
                Text("illness.journal.section.resolved")
            }
        }
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    @ViewBuilder
    private func episodeGroup(_ group: IllnessEpisodeGroup, store: IllnessStore) -> some View {
        episodeRow(group.parent, childCount: group.children.count, store: store)
        ForEach(group.children) { child in
            episodeRow(child, store: store)
                .padding(.leading, HLSpace.lg)
        }
    }

    private func episodeRow(
        _ episode: IllnessEpisodeDTO,
        childCount: Int = 0,
        store: IllnessStore
    ) -> some View {
        NavigationLink {
            IllnessEpisodeDetailScreen(store: store, episode: episode)
        } label: {
            IllnessEpisodeRow(episode: episode, childCount: childCount)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteConfirmation.request(episode)
                showDeleteConfirmation = true
            } label: {
                Label("illness.delete.action", systemImage: "trash")
            }
            Button {
                editingEpisode = episode
            } label: {
                Label("illness.edit.action", systemImage: "pencil")
            }
            .tint(HLAccent.userBrandTint)
        }
    }

    /// Empty-phase rows, rendered INSIDE the stable `List` root (not a sibling
    /// `ScrollView`).
    private var emptyRows: some View {
        Section {
            HLEmptyState(
                icon: "heart.text.square",
                title: "illness.empty.title",
                message: "illness.empty.subtitle"
            ) {
                HLButton("illness.add.title", icon: "plus", variant: .primary) {
                    showAddSheet = true
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    private func onAppear() async {
        isEnabled = container?.moduleGate.isEnabled(.illness) != false
        guard isEnabled else { return }
        // v1.18.6 PHI — prefer the container-owned singleton (joins the logout
        // cascade); the factory is the fallback only when the container is absent.
        if store == nil {
            store = container?.illnessStore ?? container.map(IllnessScreenFactory.makeStore(container:))
        }
        await reload()
    }

    private func reload() async {
        // Keep the complete episode graph loaded for parent selection and
        // cross-status orphan fallback. The toggle is display-only.
        await store?.load(includeResolved: true)
    }

    private func deleteRow(_ episode: IllnessEpisodeDTO, store: IllnessStore) async {
        await store.deleteEpisode(episode, undoMessage: String(localized: "illness.delete.undo"))
    }
}

/// Single episode list row: label + type/lifecycle badges + onset (and resolved
/// caption when resolved). Neutral badges only.
struct IllnessEpisodeRow: View {
    let episode: IllnessEpisodeDTO
    var childCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(spacing: HLSpace.xs) {
                Text(episode.label)
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                if episode.note?.isEmpty == false {
                    Image(systemName: "note.text")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: HLSpace.xs) {
                IllnessNeutralBadge(title: episode.type.localizedLabel, icon: episode.type.icon)
                IllnessNeutralBadge(title: episode.lifecycle.localizedLabel, tone: .info)
            }
            if childCount > 0 {
                let template = String(localized: "illness.journal.children.count")
                Label(String(format: template, childCount), systemImage: "arrow.turn.down.right")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
            Text(onsetCaption)
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
        }
        .padding(.vertical, HLSpace.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var onsetCaption: String {
        if let resolvedAt = episode.resolvedAt, !resolvedAt.isEmpty {
            let template = String(localized: "illness.journal.onsetResolved")
            return String(format: template, IllnessDateFormat.mediumDate(episode.onsetAt), IllnessDateFormat.mediumDate(resolvedAt))
        }
        let template = String(localized: "illness.journal.onsetActive")
        return String(format: template, IllnessDateFormat.mediumDate(episode.onsetAt))
    }

    private var accessibilityText: String {
        let template = String(localized: "illness.row.a11y")
        return String(format: template, episode.label, episode.type.localizedLabel, onsetCaption)
    }
}
