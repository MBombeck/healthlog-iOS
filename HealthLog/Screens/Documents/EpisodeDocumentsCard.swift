import SwiftUI

/// The "Dokumente" card surfaced on an illness episode detail — the documents
/// linked to this episode (a short preview), with actions to link existing
/// documents, upload/scan a new one (pre-linked), and open the full filtered
/// vault. Renders nothing when the `inboundDocuments` module is off (web parity).
struct EpisodeDocumentsCard: View {
    @Environment(\.appContainer) private var container

    let episodeId: String

    @State private var documents: [InboundDocument] = []
    @State private var totalHint = 0
    @State private var isLoading = true
    @State private var showLinkPicker = false
    @State private var showUpload = false

    private static let previewLimit = 5

    var body: some View {
        if container?.moduleGate.isEnabled(.inboundDocuments) != false {
            card
                .task(id: episodeId) { await load() }
                .sheet(isPresented: $showLinkPicker) {
                    DocumentLinkPickerSheet(episodeId: episodeId) {
                        Task { await load() }
                    }
                }
                .sheet(isPresented: $showUpload) {
                    if let store = container?.documentsStore {
                        DocumentUploadSheet(store: store, preselectedEpisodeId: episodeId)
                            .onDisappear { Task { await load() } }
                    }
                }
        }
    }

    private var card: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if documents.isEmpty {
                    Text("documents.episodeCard.emptyLine")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.tertiary)
                } else {
                    ForEach(documents.prefix(Self.previewLimit)) { document in
                        documentRow(document)
                    }
                }
                actions
            }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "folder")
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
                HLSectionLabel("documents.episodeCard.title")
            }
            Spacer()
            if !documents.isEmpty {
                Text(verbatim: "\(documents.count)")
                    .font(.hlCaption.monospacedDigit())
                    .foregroundStyle(HLText.tertiary)
            }
        }
    }

    @ViewBuilder
    private func documentRow(_ document: InboundDocument) -> some View {
        if let store = container?.documentsStore {
            NavigationLink {
                DocumentDetailScreen(store: store, documentId: document.id, initialDocument: document)
            } label: {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: DocumentKindMeta.icon(document.kind))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .frame(width: 20)
                    Text(document.resolvedTitle ?? String(localized: "documents.card.untitled"))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(DocumentFormat.mediumDate(document.displayDate))
                        .font(.hlCaption2)
                        .foregroundStyle(HLText.tertiary)
                }
                .padding(.vertical, HLSpace.xxs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var actions: some View {
        HStack(spacing: HLSpace.sm) {
            HLButton("documents.episodeCard.link", icon: "link", variant: .secondary, size: .compact) {
                showLinkPicker = true
            }
            HLButton("documents.episodeCard.upload", icon: "arrow.up.doc", variant: .secondary, size: .compact) {
                showUpload = true
            }
            Spacer()
            if documents.count > Self.previewLimit {
                NavigationLink {
                    DocumentsScreen(preselectedEpisodeId: episodeId)
                } label: {
                    Text("documents.episodeCard.viewAll")
                        .font(.hlSubhead)
                }
            }
        }
    }

    private func load() async {
        guard let repo = container?.documentsRepo else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repo.list(filter: DocumentListFilter(episodeId: episodeId), limit: 50)
            documents = page.documents
            totalHint = page.documents.count
        } catch {
            documents = []
        }
    }
}
