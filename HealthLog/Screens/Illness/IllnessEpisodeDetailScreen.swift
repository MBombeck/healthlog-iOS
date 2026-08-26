import SwiftUI

/// Detail for a single illness episode (v1.18.1 §B): a header (label / type /
/// lifecycle / onset / resolve action), a symptom + day-log timeline, and the
/// retrospective server-computed correlation section. Loads the day-log context
/// + the `Derived<T>` correlation on appear (both tolerated defensively).
struct IllnessEpisodeDetailScreen: View {
    @Environment(\.dismiss) private var dismiss

    let store: IllnessStore
    let episode: IllnessEpisodeDTO

    @State private var current: IllnessEpisodeDTO
    @State private var showEdit = false
    @State private var showLogDay = false
    @State private var showResolveConfirm = false
    @State private var showDeleteConfirm = false
    @State private var actionError: String?

    init(store: IllnessStore, episode: IllnessEpisodeDTO) {
        self.store = store
        self.episode = episode
        _current = State(initialValue: episode)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                headerCard
                if let note = current.note, !note.isEmpty {
                    noteCard(note)
                }
                logDayButton
                timelineCard
                IllnessCorrelationSection(
                    correlation: store.correlation,
                    isLoading: store.isLoadingCorrelation
                )
                // Document-vault integration — the documents linked to this
                // episode (module-gated; renders nothing when `inboundDocuments`
                // is off). Mirrors the web `episode-documents-card`.
                EpisodeDocumentsCard(episodeId: current.id)
                if let actionError {
                    HLFormErrorText(actionError)
                }
                HLSyncStatusFooter(screenLoading: store.isLoading)
            }
            .padding(HLSpace.lg)
        }
        .hlScreenBackground()
        .navigationTitle(Text(verbatim: current.label))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await onAppear() }
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
        .hlConfirmDestructive(
            Text("illness.delete.confirm.title"),
            isPresented: $showDeleteConfirm,
            confirm: Text("illness.delete.action"),
            action: {
                Task {
                    await store.deleteEpisode(current, undoMessage: String(localized: "illness.delete.undo"))
                    dismiss()
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showEdit = true
                } label: {
                    Label("illness.edit.action", systemImage: "pencil")
                }
                if current.isActive, current.lifecycle.isResolvable {
                    Button {
                        showResolveConfirm = true
                    } label: {
                        Label("illness.resolve.action", systemImage: "checkmark.circle")
                    }
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("illness.delete.action", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("illness.detail.menu")
        }
    }

    private var headerCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.xs) {
                    IllnessNeutralBadge(title: current.type.localizedLabel, icon: current.type.icon)
                    IllnessNeutralBadge(title: current.lifecycle.localizedLabel, tone: .info)
                    if !current.isActive {
                        IllnessNeutralBadge(title: String(localized: "illness.status.resolved"), icon: "checkmark")
                    }
                }
                Label(onsetCaption, systemImage: "calendar")
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                if let resolvedAt = current.resolvedAt, !resolvedAt.isEmpty {
                    let template = String(localized: "illness.detail.resolvedAt")
                    Label(String(format: template, IllnessDateFormat.mediumDate(resolvedAt)), systemImage: "checkmark.seal")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
    }

    private func noteCard(_ note: String) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text("illness.detail.note")
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
                Text(note)
                    .font(.hlBody)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var logDayButton: some View {
        HLButton("illness.daylog.add", icon: "square.and.pencil", variant: .secondary) {
            showLogDay = true
        }
        .accessibilityIdentifier("illness.detail.logDay")
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text("illness.daylog.timeline.title")
                .font(.hlFootnote.weight(.semibold))
                .foregroundStyle(HLText.secondary)
            IllnessDayLogTimeline(state: store.dayLogTimelineState) {
                Task { await store.loadDayLogs(episodeId: current.id) }
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
