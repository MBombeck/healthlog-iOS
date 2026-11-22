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
        VStack(spacing: HLSpace.xs) {
            HLCard("documents.episodeCard.title") {
                if !documents.isEmpty {
                    Text(documents.count, format: .number)
                        .font(.hlCaption.monospacedDigit())
                        .foregroundStyle(HLText.secondary)
                }
            } content: {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        // No "no documents linked yet" under the heading:
                        // an empty card says it with its one action (upload),
                        // like every empty state. Linking an existing document
                        // stays on the document's own detail.
                        VStack(spacing: 0) {
                            ForEach(documents.prefix(Self.previewLimit)) { document in
                                documentRow(document)
                            }
                        }
                    }
                    actions
                }
            }
            if documents.count > Self.previewLimit {
                HLLinkButton("documents.episodeCard.viewAll", destination: {
                    DocumentsScreen(preselectedEpisodeId: episodeId)
                })
            }
        }
    }

    /// The same row as in the document list, so a document reads alike
    /// wherever it appears; the whole row opens it, without a chevron.
    @ViewBuilder
    private func documentRow(_ document: InboundDocument) -> some View {
        if let store = container?.documentsStore {
            DocumentCardRow(document: document, selectionMode: false, isSelected: false, isHighlighted: false)
                .hlRowLink {
                    DocumentDetailScreen(store: store, documentId: document.id, initialDocument: document)
                }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if documents.isEmpty {
            HLButton("documents.episodeCard.upload", systemImage: "arrow.up.doc", variant: .secondary) {
                showUpload = true
            }
        } else {
            HLButtonPair {
                HLButton("documents.episodeCard.upload", systemImage: "arrow.up.doc", variant: .secondary) {
                    showUpload = true
                }
            } secondary: {
                HLButton("documents.episodeCard.link", systemImage: "link", variant: .secondary) {
                    showLinkPicker = true
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
