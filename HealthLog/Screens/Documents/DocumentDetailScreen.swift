import SwiftUI

/// Detail for a single stored document: an inline preview, editable metadata
/// (title / kind via a menu / filing date via an inline DatePicker), condition-
/// link editing (replace-set), the optional AI-assist card (suggest / summarise /
/// per-document chat), a download/share affordance, and soft-delete with undo.
/// When indexing is possible the document is content-indexed silently on open —
/// there is no user-facing "indexieren" button.
///
/// Metadata edits commit inline (on submit / on change) — like the web sheet —
/// so there is no dirty-guard here; the edits persist immediately.
struct DocumentDetailScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    let store: DocumentsStore
    let documentId: String
    /// The list snapshot, painted instantly while the full detail loads.
    @State var document: InboundDocument
    @State var isLoading = true
    @State var actionError: String?
    @State var showDeleteConfirm = false
    @State var shareURL: URL?
    @State var showConditionEditor = false
    @State var availableEpisodes: [IllnessEpisodeDTO] = []
    /// The detail's staged facts — kept so the "N Laborwerte" jump can count
    /// non-rejected OBSERVATION facts without a second request (Wave 4.5).
    @State var facts: [ExtractedFact] = []

    // Inline metadata edit state. The filing date is edited directly via an
    // inline DatePicker (defaults to the stored date, else today).
    @State var titleDraft = ""
    @State var filingDate = Date()

    /// Guards the silent auto-index so it fires at most once per detail open.
    @State var didAttemptAutoIndex = false

    // Vault Phase 2 — AI-assist + content-index state (all screen-local /
    // session-only; suggestion drafts + summaries are never persisted).
    @State var suggestion: DocumentSuggestion?
    @State var suggestApplied = DocumentAssistApplied()
    @State var isSuggesting = false
    @State var suggestError: String?
    @State var summary: DocumentSummary?
    @State var summaryMode: DocumentSummaryMode?
    @State var isSummarising = false
    @State var summaryError: String?

    // Vault Phase 4 — document chat (server v1.27.33). The scoped Q&A store is
    // built lazily on open (needs the repository + this document's id); the sheet
    // is gated on `document.hasContentIndex` + the same assist/consent gate.
    @State var chatStore: DocumentChatStore?
    @State var showChat = false

    init(store: DocumentsStore, documentId: String, initialDocument: InboundDocument) {
        self.store = store
        self.documentId = documentId
        _document = State(initialValue: initialDocument)
        _titleDraft = State(initialValue: initialDocument.title ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                // Wave 4.3 — web tier order: preview → persisted summary → the
                // (collapsible) AI action block → the editable fields. The
                // metadata card used to sit directly under the preview, which
                // buried the AI narrative below the form.
                DocumentPreviewView(store: store, document: document)
                summarySection
                if aiAssistEnabled, showsAssistActions {
                    assistCard
                }
                metadataCard
                conditionsCard
                labValuesLink
                if let actionError {
                    HLFormErrorText(actionError)
                }
                uploadedMetaLine
                aiReadProvenanceLine
            }
            .padding(HLSpace.lg)
        }
        .hlScreenBackground()
        .navigationTitle(Text(verbatim: document.resolvedTitle ?? String(localized: "documents.card.untitled")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await onAppear() }
        .hlConfirmDestructive(
            Text("documents.detail.deleteConfirm.title"),
            isPresented: $showDeleteConfirm,
            confirm: Text("documents.detail.delete"),
            cancel: Text("documents.action.cancel"),
            action: {
                Task { await performDelete() }
            }
        )
        .sheet(isPresented: $showConditionEditor) {
            DocumentConditionLinkEditor(
                linkedEpisodeIds: Set(document.conditionLinks.map(\.episodeId)),
                available: availableEpisodes
            ) { newIds in
                Task { await applyConditionLinks(newIds) }
            }
        }
        #if canImport(UIKit)
        .sheet(item: shareItem) { item in
            DocumentShareSheet(url: item.url) { shareURL = nil }
        }
        #endif
        .sheet(isPresented: $showChat) {
            if let chatStore {
                DocumentChatSheet(store: chatStore)
            }
        }
    }

    /// Open the document-scoped chat. Builds the store lazily from the documents
    /// repository + this document's id (chat is offered only for a content-indexed
    /// document, gated in the assist card).
    func openChat() {
        chatStore = DocumentChatStore(repository: store.repository, documentId: documentId)
        showChat = true
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if canAskDocument {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openChat()
                } label: {
                    Label("documents.chat.open", systemImage: "bubble.left.and.text.bubble.right")
                }
                .accessibilityIdentifier("documents.chat.open")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task { await prepareShare() }
                } label: {
                    Label("documents.detail.download", systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("documents.detail.delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(Text("documents.action.more"))
            }
            .accessibilityIdentifier("documents.detail.menu")
        }
    }

    private var uploadedMetaLine: some View {
        Text(uploadedText)
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var uploadedText: String {
        let template = String(localized: "documents.detail.uploadedMeta")
        return String(format: template, DocumentFormat.mediumDate(document.createdAt), DocumentFormat.bytes(document.byteSize))
    }

    // MARK: - Phase 2 assist gate

    /// The AI-assist affordances (suggest / summarise) render only when BOTH
    /// halves of the gate hold: the server offers assist (`assistAvailable` from
    /// usage — a document-scan provider is configured) AND the user has granted
    /// exact server-mediated document consent (current provider/scope + account
    /// session). No new per-module toggle — `.none`, on-device-only, and BYO
    /// users see nothing because those modes do not authorize server document AI.
    /// Reading both here in a SwiftUI body establishes observation, so the area
    /// appears/disappears live when consent or server availability changes.
    var aiAssistEnabled: Bool {
        store.assistAvailable && (container?.documentExternalAIConsentGranted ?? false)
    }

    /// The content-search index affordances gate on the same AI consent plus the
    /// server's `contentIndex.enabled` (a vision provider is configured). This is
    /// also iOS's "auto-read is on" signal: when it holds, the document is
    /// indexed silently on open and the server's background summary is expected.
    var contentIndexEnabled: Bool {
        store.contentIndexEnabled && (container?.documentExternalAIConsentGranted ?? false)
    }

    /// Whether the labs module is on — gates the "N Laborwerte" jump (web
    /// `labsModuleEnabled`). Unknown container ⇒ treated as on, like the rest of
    /// the app's module reads.
    var labsModuleEnabled: Bool {
        container?.moduleGate.isEnabled(.labs) != false
    }

    /// **Wave 4.3 collapse rule.** The web hides its whole AI action box when
    /// auto-read is on and nothing is pending to review, so the content under
    /// the preview starts straight with the summary + fields
    /// (`document-ai-section.tsx` returns `null`). iOS is AUTO-ONLY by operator
    /// decision — there is no "Mit KI lesen" button to fall back to — so the row
    /// collapses only once the persisted summary has actually LANDED. That keeps
    /// the calm web shape in the normal case while never stranding a user whose
    /// auto-read failed or has not run yet: no summary ⇒ the manual actions stay
    /// reachable. Anything pending (a suggestion under review, an open
    /// summary/text panel, an assist error) always keeps the row open.
    var showsAssistActions: Bool {
        if suggestion != nil || summaryMode != nil || suggestError != nil { return true }
        let autoReadSettled = contentIndexEnabled && document.resolvedSummary != nil
        return !autoReadSettled
    }

    /// The per-document Q&A entry point. Promoted out of the buried assist-card
    /// row into the toolbar (Wave 4.4) so it reads as a first-class action, like
    /// the web's footer "Ask the Coach". The sheet itself stays the bespoke
    /// `DocumentChatSheet` — the platform-native stand-in for the web's coach
    /// drawer. Gated on the assist/consent gate AND a content index (the indexed
    /// text is the grounding; the server refuses an un-indexed document).
    var canAskDocument: Bool {
        aiAssistEnabled && document.hasContentIndex
    }

    // MARK: - Lifecycle

    private func onAppear() async {
        syncEditState(from: document)
        await loadEpisodes()
        await reload()
        await autoIndexIfNeeded()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await store.detail(id: documentId)
            document = detail.document
            facts = detail.facts
            syncEditState(from: detail.document)
        } catch {
            if DocumentsRepository.isModuleDisabled(error) {
                dismiss()
            } else {
                actionError = String(localized: "documents.detail.loadError")
            }
        }
    }

    /// Silently content-index the document the first time its detail opens, so
    /// full-text search covers it without any user-facing "indexieren" button.
    /// Only runs when indexing is possible (a vision provider is configured AND
    /// the app's remote-AI consent is granted — `contentIndexEnabled`), and only
    /// when the body is not yet indexed. Any failure is swallowed: this is a
    /// quiet background nicety, never a surfaced error. On success the detail is
    /// re-read so the flipped `hasContentIndex` unlocks the chat affordance.
    private func autoIndexIfNeeded() async {
        guard !didAttemptAutoIndex else { return }
        didAttemptAutoIndex = true
        guard contentIndexEnabled, !document.hasContentIndex else { return }
        do {
            _ = try await store.indexContent(id: documentId)
            await reload()
        } catch {
            // Best-effort only — search simply won't cover this document yet.
        }
    }

    private func loadEpisodes() async {
        guard let illness = container?.illnessStore else { return }
        if illness.episodes.isEmpty {
            await illness.load()
        }
        availableEpisodes = illness.episodes
    }

    func syncEditState(from document: InboundDocument) {
        titleDraft = document.title ?? ""
        if let date = document.documentDate, let parsed = Self.parseDay(date) {
            filingDate = parsed
        } else {
            filingDate = Date()
        }
    }

    // MARK: - Actions

    private func performDelete() async {
        await store.delete(document, undoMessage: String(localized: "documents.toast.deleted"))
        dismiss()
    }

    func applyConditionLinks(_ ids: Set<String>) async {
        if let detail = await store.updateMetadata(id: documentId, .episodeIds(Array(ids))) {
            document = detail.document
        } else {
            actionError = String(localized: "documents.detail.saveError")
        }
    }

    private func prepareShare() async {
        do {
            let (data, response) = try await store.original(id: documentId)
            let name = document.filename ?? "document"
            let ext = Self.fileExtension(for: document.mimeType, response: response)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent(name.hasSuffix(ext) ? name : name + ext)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
            shareURL = url
        } catch {
            actionError = String(localized: "documents.detail.downloadError")
        }
    }

    // MARK: - Helpers

    private var shareItem: Binding<ShareURLItem?> {
        Binding(
            get: { shareURL.map(ShareURLItem.init) },
            set: { if $0 == nil { shareURL = nil } }
        )
    }

    static func parseDay(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: String(raw.prefix(10)))
    }

    static func formatDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private static func fileExtension(for mimeType: String, response: HTTPURLResponse) -> String {
        switch mimeType {
        case "application/pdf": ".pdf"
        case "image/jpeg": ".jpg"
        case "image/png": ".png"
        case "image/webp": ".webp"
        case "image/gif": ".gif"
        default:
            // Fall back to any filename hint from the response, else no extension.
            ""
        }
    }
}

/// Identifiable wrapper so the share URL drives a `.sheet(item:)`.
struct ShareURLItem: Identifiable {
    let url: URL
    var id: String {
        url.absoluteString
    }
}
