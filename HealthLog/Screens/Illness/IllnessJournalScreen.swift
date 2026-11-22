import SwiftUI

/// Native illness / condition-journal surface (v1.18.1 `W-B`; default-on since
/// v1.18.3). The default destination: it lists episodes (newest-first by onset),
/// filterable active / resolved, each as a two-line row with its course as
/// status text. When a
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
    /// Re-evaluated each appear so an opt-in flip flips us from the opt-in
    /// screen to the list without a manual reload.
    @State private var isEnabled = true

    var body: some View {
        Group {
            // **Audit A-7 —** when the server said WHY the module is off and the
            // reason is not the person's own switch, the enable surface is
            // replaced by that sentence: a CTA there invites a PATCH the server
            // refuses. `disabled` (and no verdict at all) keeps today's opt-in.
            if let reason = moduleOffReason {
                FeatureDisabledCard(variant: .hero, reason: reason)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if !isEnabled {
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
                    loading: {
                        SectionRootHeader("illness.journal.title", inList: true)
                        HLAsyncListSkeletonRows()
                    },
                    empty: {
                        SectionRootHeader("illness.journal.title", inList: true)
                        emptyRows
                    },
                    content: {
                        SectionRootHeader("illness.journal.title", inList: true)
                        if let store { loadedRows(store: store) }
                    }
                )
                .hlPageMargins()
            }
        }
        // Inline when pushed; as a sidebar tab the journal heads itself. The
        // short name keeps the inline title centred beside the two actions.
        .hlSectionRootTitle(Text("illness.journal.navTitle"), headsItself: headsItself)
        .hlPageActions(isEnabled ? pageActions : .none)
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
    }

    /// Whether the list with its own header stands: not the opt-in, not the
    /// server's reason, not a failed load.
    private var headsItself: Bool {
        moduleOffReason == nil && isEnabled && store?.isDisabled != true && !phase.isError
    }

    /// One group: the insights wait in the more menu, adding stands
    /// outermost.
    private var pageActions: HLTabHeaderActions {
        [
            .more(identifier: "illness.toolbar.more") {
                Button("illness.insights.title", systemImage: "chart.bar.xaxis") {
                    showInsights = true
                }
                .accessibilityIdentifier("illness.toolbar.insights")
            },
            .add(label: "illness.add.title", identifier: "illness.toolbar.add") { showAddSheet = true }
        ]
    }

    /// Maps store state to the stable-root render phase. `nil` store and the first
    /// in-flight load render the skeleton; no episodes (settled) → empty; otherwise
    /// the real list. `isDisabled` is handled in the outer `body` (opt-in surface).
    private var phase: HLAsyncListPhase {
        guard let store else { return .loading }
        if store.episodes.isEmpty {
            if store.isLoading { return .loading }
            // A failed fetch with no cached episodes is an ERROR, not
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
            Toggle(isOn: $includeResolved) {
                HLRowTitle("illness.journal.showResolved")
            }
            .accessibilityIdentifier("illness.journal.showResolvedToggle")
        }
        .hlFormRowSurface()
        Section {
            ForEach(activeGroups) { group in
                episodeGroup(group, store: store)
            }
        } header: {
            if !activeGroups.isEmpty {
                HLSectionHeader("illness.journal.section.active")
            }
        }
        .hlFormRowSurface()
        Section {
            if includeResolved {
                ForEach(resolvedGroups) { group in
                    episodeGroup(group, store: store)
                }
            }
        } header: {
            if includeResolved, !resolvedGroups.isEmpty {
                HLSectionHeader("illness.journal.section.resolved")
            }
        }
        .hlFormRowSurface()
        Section {} footer: {
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
    }

    @ViewBuilder
    private func episodeGroup(_ group: IllnessEpisodeGroup, store: IllnessStore) -> some View {
        episodeRow(group.parent, childCount: group.children.count, store: store)
        ForEach(group.children) { child in
            // A child episode steps in by one card inset so it reads as part
            // of the parent above it.
            episodeRow(child, store: store)
                .padding(.leading, HLLayout.cardInset)
        }
    }

    private func episodeRow(
        _ episode: IllnessEpisodeDTO,
        childCount: Int = 0,
        store: IllnessStore
    ) -> some View {
        IllnessEpisodeRow(episode: episode, childCount: childCount)
            .hlRowLink(inList: true) {
                IllnessEpisodeDetailScreen(store: store, episode: episode)
            }
            .hlSwipeDelete(.confirmed(title: "illness.delete.confirm.title") {
                await deleteRow(episode, store: store)
            }) {
                Button("illness.edit.action", systemImage: "pencil") {
                    editingEpisode = episode
                }
                .tint(HLAccent.userBrandTint)
            }
    }

    /// Empty-phase rows, rendered INSIDE the stable `List` root (not a sibling
    /// `ScrollView`).
    private var emptyRows: some View {
        Section {
            // The title names what goes in the journal; the one action
            // starts the first episode where the eye already is (the plus in
            // the bar stays).
            HLEmptyState(icon: "heart.text.square", title: "illness.empty.title", message: "illness.empty.message") {
                HLButton("illness.add.title", systemImage: "plus", variant: .secondary) { showAddSheet = true }
                    .accessibilityIdentifier("illness.empty.add")
            }
            .hlFreeAreaListRow()
        }
    }

    /// **The server's sentence when the module is off for a reason
    /// that is not the viewer's own switch**, `nil` when the opt-in CTA still
    /// applies (module on, `disabled`, or no verdict from the server at all).
    ///
    /// Only consulted while the surface is in an off state; an enabled module
    /// resolves `.offerOptIn` anyway, so the guard is about the render, not
    /// about correctness.
    private var moduleOffReason: String? {
        guard !isEnabled || store?.isDisabled == true else { return nil }
        guard case let .explain(reason) = container?.moduleGate.optInPresentation(.illness) else { return nil }
        return reason
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

/// One episode in the journal: name, one line of side facts, the course as
/// status text, the type as the leading symbol. The whole row opens the
/// episode, so it carries no chevron.
struct IllnessEpisodeRow: View {
    let episode: IllnessEpisodeDTO
    var childCount = 0

    var body: some View {
        let content = IllnessEpisodeRowContent(episode: episode, childCount: childCount)
        HLRow(
            title: Text(verbatim: content.title),
            detail: content.detail.map { Text(verbatim: $0) },
            status: HLRowStatus(content.status)
        ) {
            HLRowGlyph(symbol: content.symbol)
        }
        .accessibilityLabel(content.spoken)
    }
}
