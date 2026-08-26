import SwiftUI

/// "Dokumente verknüpfen" — pick documents from the caller's vault to link to an
/// illness episode. A search recalls up to one page (50) of documents; toggling a
/// row fires a single-id bulk `linkEpisode` / `unlinkEpisode` (idempotent). Opened
/// from the episode's ``EpisodeDocumentsCard``.
struct DocumentLinkPickerSheet: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    let episodeId: String
    let onChange: () -> Void

    @State private var query = ""
    @State private var documents: [InboundDocument] = []
    @State private var isLoading = true
    @State private var busyIds: Set<String> = []
    @State private var searchDebounce: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    HStack { Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if documents.isEmpty {
                    HLEmptyState(
                        icon: "doc.text.magnifyingglass",
                        title: "documents.linkPicker.empty"
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(documents) { document in
                        row(document)
                    }
                }
            }
            .navigationTitle(Text("documents.linkPicker.title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text("documents.linkPicker.searchPlaceholder"))
            .onChange(of: query) { _, newValue in debounce(newValue) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("documents.action.done") { dismiss() }
                }
            }
            .task { await reload() }
        }
    }

    private func row(_ document: InboundDocument) -> some View {
        let isLinked = document.conditionLinks.contains { $0.episodeId == episodeId }
        return Button {
            Task { await toggle(document, isLinked: isLinked) }
        } label: {
            HStack(spacing: HLSpace.sm) {
                Image(systemName: DocumentKindMeta.icon(document.kind))
                    .foregroundStyle(HLText.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(document.resolvedTitle ?? String(localized: "documents.card.untitled"))
                        .foregroundStyle(HLText.primary)
                        .lineLimit(1)
                    Text(DocumentFormat.mediumDate(document.displayDate))
                        .font(.hlCaption2)
                        .foregroundStyle(HLText.tertiary)
                }
                Spacer()
                if busyIds.contains(document.id) {
                    ProgressView().controlSize(.small)
                } else if isLinked {
                    Image(systemName: "checkmark").foregroundStyle(HLAccent.userBrandTint)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isLinked ? [.isSelected] : [])
    }

    private func debounce(_ text: String) {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    private func reload() async {
        guard let repo = container?.documentsRepo else { return }
        isLoading = true
        defer { isLoading = false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = DocumentListFilter(q: trimmed.isEmpty ? nil : trimmed)
        do {
            documents = try await repo.list(filter: filter, limit: 50).documents
        } catch {
            documents = []
        }
    }

    private func toggle(_ document: InboundDocument, isLinked: Bool) async {
        guard let repo = container?.documentsRepo, !busyIds.contains(document.id) else { return }
        busyIds.insert(document.id)
        defer { busyIds.remove(document.id) }
        do {
            _ = try await repo.bulk(
                ids: [document.id],
                action: isLinked ? .unlinkEpisode : .linkEpisode,
                episodeId: episodeId
            )
            await reload()
            onChange()
        } catch {
            // Best-effort — a failed toggle leaves the row unchanged.
        }
    }
}
