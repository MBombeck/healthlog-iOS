import SwiftUI

/// Detail for a single illness episode (v1.18.1 §B): a header (label / type /
/// lifecycle / onset / resolve action), a symptom + day-log timeline, and the
/// retrospective server-computed correlation section. Loads the day-log context
/// + the `Derived<T>` correlation on appear (both tolerated defensively).
struct IllnessEpisodeDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainer) private var container
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let store: IllnessStore
    let episode: IllnessEpisodeDTO

    @State private var current: IllnessEpisodeDTO
    @State private var showEdit = false
    @State private var showLogDay = false
    @State private var showResolveConfirm = false
    @State private var actionError: String?
    /// The list row carries no `related`; the single read does.
    @State private var related = RelatedRecordsModel()

    init(store: IllnessStore, episode: IllnessEpisodeDTO) {
        self.store = store
        self.episode = episode
        _current = State(initialValue: episode)
    }

    var body: some View {
        HLPage {
            headerCard
            if let note = current.note, !note.isEmpty {
                noteCard(note)
            }
            logDayButton
            timelineCard
            EpisodeSymptomsSection(store: store, episode: current)
            IllnessCorrelationSection(
                correlation: store.correlation,
                isLoading: store.isLoadingCorrelation
            )
            // Document-vault integration — the documents linked to this
            // episode (module-gated; renders nothing when `inboundDocuments`
            // is off). Mirrors the web `episode-documents-card`.
            EpisodeDocumentsCard(episodeId: current.id)
            RelatedRecordsLoadedSection(model: related)
            if let actionError {
                HLFormErrorText(actionError)
            }
            HLSyncStatusFooter(screenLoading: store.isLoading)
        }
        .navigationTitle(Text(verbatim: current.label))
        .navigationBarTitleDisplayMode(.inline)
        .hlPageActions(pageActions)
        // Asks for the menu's delete entry in the bar above.
        .hlDeleteConfirmation()
        .task { await onAppear() }
        .task(id: current.id) {
            guard let repo = container?.illnessRepo else { return }
            let id = current.id
            await related.load { try await repo.episode(id: id).related?.items }
        }
        .sheet(isPresented: $showEdit) {
            EditEpisodeSheet(store: store, episode: current) { updated in
                current = updated
            }
        }
        .sheet(isPresented: $showLogDay) {
            LogDaySheet(store: store, episodeId: current.id)
        }
        .confirmationDialog(
            Text("illness.resolve.confirm.title"),
            isPresented: $showResolveConfirm,
            titleVisibility: .visible
        ) {
            Button("illness.resolve.action") {
                Task { await resolve() }
            }
        }
    }

    private var pageActions: HLTabHeaderActions {
        [
            .more(identifier: "illness.detail.menu") {
                Button("illness.edit.action", systemImage: "pencil") {
                    showEdit = true
                }
                if current.isActive, current.lifecycle.isResolvable {
                    Button("illness.resolve.action", systemImage: "checkmark.circle") {
                        showResolveConfirm = true
                    }
                }
                HLDeleteMenuItem(.confirmed(title: "illness.delete.confirm.title") {
                    await store.deleteEpisode(current, undoMessage: String(localized: "illness.delete.undo"))
                    dismiss()
                })
            }
        ]
    }

    private var badgeLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.xs))
            : AnyLayout(HStackLayout(spacing: HLSpace.xs))
    }

    private var headerCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // At an accessibility text size the
                // badges stand under each other instead of being squeezed
                // into one letter per line.
                badgeLayout {
                    IllnessNeutralBadge(title: current.type.localizedLabel, icon: current.type.icon)
                    IllnessNeutralBadge(title: current.lifecycle.localizedLabel, tone: .info)
                    if !current.isActive {
                        IllnessNeutralBadge(title: String(localized: "illness.status.resolved"), icon: "checkmark")
                    }
                }
                Label(onsetCaption, systemImage: "calendar")
                    .hlText(.factLabel)
                if let resolvedAt = current.resolvedAt, !resolvedAt.isEmpty {
                    let template = String(localized: "illness.detail.resolvedAt")
                    Label(String(format: template, IllnessDateFormat.mediumDate(resolvedAt)), systemImage: "checkmark.seal")
                        .hlText(.factLabel)
                }
            }
        }
    }

    private func noteCard(_ note: String) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HLCardLabel("illness.detail.note")
                Text(note)
                    .hlText(.prose)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var logDayButton: some View {
        HLButton("illness.daylog.add", systemImage: "square.and.pencil", variant: .secondary) {
            showLogDay = true
        }
        .accessibilityIdentifier("illness.detail.logDay")
    }

    /// No logged day yet: no "Verlauf" heading over an empty line.
    @ViewBuilder
    private var timelineCard: some View {
        if case .empty = store.dayLogTimelineState {
            EmptyView()
        } else {
            Group {
                HLSectionHeader("illness.daylog.timeline.title", rank: .area)
                IllnessDayLogTimeline(state: store.dayLogTimelineState) {
                    Task { await store.loadDayLogs(episodeId: current.id) }
                }
            }
        }
    }

    private var onsetCaption: String {
        let template = String(localized: "illness.detail.onsetAt")
        return String(format: template, IllnessDateFormat.mediumDate(current.onsetAt))
    }

    private func onAppear() async {
        await store.select(current)
    }

    private func resolve() async {
        actionError = nil
        let ok = await store.resolveEpisode(id: current.id)
        if ok, let updated = store.selectedEpisode {
            current = updated
        } else if store.lastErrorWasChronicNoResolve {
            actionError = String(localized: "illness.resolve.chronicError")
        } else {
            actionError = store.lastError ?? String(localized: "illness.resolve.failed")
        }
    }
}
