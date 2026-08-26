import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The upload entry sheet: pick a file (`.fileImporter`, accept list from
/// `usage.acceptedExtensions` — HEIC is excluded), scan a paper document (VisionKit,
/// combined into a single inline PDF), or pick from Photos (re-encoded to inline
/// JPEG). Each source becomes a store-only ``DocumentUploadDraft``; the store
/// pre-flights the per-file cap + quota and surfaces a duplicate as a success.
/// When opened from an illness episode card the upload pre-links that episode.
struct DocumentUploadSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: DocumentsStore
    let preselectedEpisodeId: String?

    @State private var showFileImporter = false
    @State private var showScanner = false
    @State private var showPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isUploading = false
    @State private var errorMessage: String?
    /// The drafts the last import could not store, kept so a retry costs no
    /// second trip through the picker. The bytes are already on this side.
    @State private var retryDrafts: [DocumentUploadDraft] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HLSpace.lg) {
                    header
                    if let usage = store.usage {
                        DocumentUsageBar(usage: usage)
                    }
                    sourceButtons
                    if let usage = store.usage {
                        acceptedTypesCaption(usage)
                    }
                    if isUploading {
                        ProgressView("documents.upload.uploading")
                            .frame(maxWidth: .infinity)
                    }
                    failureText
                    retryAction
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(HLSpace.lg)
            }
            .hlScreenBackground()
            .navigationTitle(Text("documents.pageUpload"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("documents.action.cancel") { dismiss() }
                }
            }
            .photosPicker(
                isPresented: $showPhotos,
                selection: $photoSelection,
                maxSelectionCount: 10,
                matching: .images
            )
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: true
            ) { result in
                Task { await handleFileImport(result) }
            }
            #if canImport(UIKit) && canImport(VisionKit)
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView(
                    onScan: { images in
                        showScanner = false
                        Task { await handleScan(images) }
                    },
                    onCancel: { showScanner = false },
                    onError: {
                        showScanner = false
                        errorMessage = String(localized: "documents.upload.scanError")
                    }
                )
                .ignoresSafeArea()
            }
            #endif
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                Task { await handlePhotos(items) }
            }
        }
    }

    // MARK: - Failure surface

    /// The one place this sheet says something went wrong — and the only place
    /// an automated check can read that it did, which is why it carries an
    /// identifier. Without one, "the failure was shown" is unfalsifiable.
    @ViewBuilder
    private var failureText: some View {
        if let message = displayedFailure {
            HLFormErrorText(message)
                .accessibilityIdentifier("documents.upload.error")
        }
    }

    /// Retry exactly what was refused, without a second trip through the
    /// picker. Absent when there is nothing retryable.
    @ViewBuilder
    private var retryAction: some View {
        if !retryDrafts.isEmpty, !isUploading {
            HLButton("async.list.error.retry", icon: "arrow.clockwise", variant: .secondary) {
                Task { await uploadAll(retryDrafts, unreadable: 0) }
            }
            .accessibilityIdentifier("documents.upload.retry")
        }
    }

    /// What this sheet is currently responsible for showing: the outcome of an
    /// import the user just made, or — before a single file has been picked —
    /// the refusal the loaded quota already guarantees. Saying the second one
    /// first is the only honest order: opening a picker to store bytes that
    /// cannot be stored wastes the user's time and then blames the file.
    private var displayedFailure: String? {
        if let errorMessage { return errorMessage }
        guard let refusal = preflightRefusal else { return nil }
        return Self.message(for: refusal)
    }

    /// A quota with no headroom left refuses every source, whatever is picked.
    private var preflightRefusal: DocumentOperationError? {
        guard let usage = store.usage, usage.remainingBytes <= 0 else { return nil }
        return .upload(.quotaExceeded(quotaBytes: usage.quotaBytes, usedBytes: usage.usedBytes))
    }

    /// True while no source can succeed — the buttons stand down with the copy.
    private var sourcesRefused: Bool {
        isUploading || preflightRefusal != nil
    }

    // MARK: - Header

    /// The add-sheet convention shared with the app's other create sheets: a clear
    /// heading and a short explanatory line, above the action buttons.
    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text("documents.upload.heading")
                .font(.hlTitle3)
                .foregroundStyle(HLText.primary)
            Text("documents.upload.subtitle")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Source buttons

    /// The three upload sources as consistent ``HLButton``s (no alien `.bordered`
    /// PhotosPicker button): pick a file, scan with the camera, or import photos.
    /// The Photos source is driven through the `.photosPicker(isPresented:)`
    /// modifier so it can wear the same button styling as the others.
    private var sourceButtons: some View {
        VStack(spacing: HLSpace.sm) {
            HLButton("documents.upload.browse", icon: "folder", variant: .primary) {
                showFileImporter = true
            }
            .disabled(sourcesRefused)

            #if canImport(UIKit) && canImport(VisionKit)
                if DocumentScannerView.isSupported {
                    HLButton("documents.upload.scan", icon: "doc.viewfinder", variant: .secondary) {
                        showScanner = true
                    }
                    .disabled(sourcesRefused)
                }
            #endif

            HLButton("documents.upload.photos", icon: "photo.on.rectangle", variant: .secondary) {
                showPhotos = true
            }
            .disabled(sourcesRefused)
        }
    }

    private func acceptedTypesCaption(_ usage: DocumentUsage) -> some View {
        let extensions = usage.acceptedExtensions.isEmpty ? Self.fallbackExtensions : usage.acceptedExtensions
        return Text(verbatim: extensions.joined(separator: " · "))
            .font(.hlCaption2)
            .foregroundStyle(HLText.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Accept list

    /// The concrete server-accepted extensions used as the `.fileImporter` scope
    /// (and the accepted-types caption) whenever `usage` hasn't loaded yet. HEIC is
    /// deliberately excluded, matching the server accept list.
    static let fallbackExtensions = [".pdf", ".jpg", ".jpeg", ".png", ".webp", ".gif"]

    /// The `.fileImporter` content types, scoped to the server's
    /// `usage.acceptedExtensions` (HEIC already excluded upstream) — NOT every
    /// `UTType`. Falls back to the concrete ``fallbackExtensions`` set when usage
    /// hasn't loaded, and to those same document/image types (never the catch-all
    /// `.data`) if none of the extensions resolve, so the picker never offers "a
    /// million file types".
    private var allowedContentTypes: [UTType] {
        let accepted = store.usage?.acceptedExtensions ?? []
        let extensions = accepted.isEmpty ? Self.fallbackExtensions : accepted
        let types = extensions.compactMap { raw -> UTType? in
            let ext = raw.hasPrefix(".") ? String(raw.dropFirst()) : raw
            return UTType(filenameExtension: ext)
        }
        return types.isEmpty ? [.pdf, .jpeg, .png, .gif] : types
    }

    // MARK: - Source handlers

    /// Every picked file contributes to the outcome, readable or not. Dropping
    /// an unreadable one silently is how a pick of five files could store two
    /// and report a plain success.
    private func handleFileImport(_ result: Result<[URL], Error>) async {
        switch result {
        case let .success(urls):
            var drafts: [DocumentUploadDraft] = []
            var unreadable = 0
            for url in urls {
                if let draft = readFileDraft(url) {
                    drafts.append(draft)
                } else {
                    unreadable += 1
                }
            }
            await uploadAll(drafts, unreadable: unreadable)
        case let .failure(error):
            errorMessage = LogSanitizer.redact(error.localizedDescription)
        }
    }

    private func readFileDraft(_ url: URL) -> DocumentUploadDraft? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        return DocumentUploadDraft(
            data: data,
            filename: url.lastPathComponent,
            mimeType: mime,
            episodeIds: preselectedEpisodeId.map { [$0] } ?? []
        )
    }

    /// Same rule as the file picker: a photo that will not load or re-encode is
    /// counted, not skipped.
    private func handlePhotos(_ items: [PhotosPickerItem]) async {
        photoSelection = []
        var drafts: [DocumentUploadDraft] = []
        var unreadable = 0
        for (index, item) in items.enumerated() {
            let data = try? await item.loadTransferable(type: Data.self)
            if let jpeg = data.flatMap(DocumentImageEncoder.jpeg(from:)) {
                drafts.append(DocumentUploadDraft(
                    data: jpeg,
                    filename: "photo-\(index + 1).jpg",
                    mimeType: "image/jpeg",
                    episodeIds: preselectedEpisodeId.map { [$0] } ?? []
                ))
            } else {
                unreadable += 1
            }
        }
        await uploadAll(drafts, unreadable: unreadable)
    }

    #if canImport(UIKit)
        private func handleScan(_ images: [UIImage]) async {
            guard !images.isEmpty else { return }
            let draft: DocumentUploadDraft
            if let pdf = DocumentImageEncoder.pdf(from: images) {
                draft = DocumentUploadDraft(
                    data: pdf,
                    filename: "scan.pdf",
                    mimeType: "application/pdf",
                    episodeIds: preselectedEpisodeId.map { [$0] } ?? []
                )
            } else if let jpeg = images.first?.jpegData(compressionQuality: 0.85) {
                draft = DocumentUploadDraft(
                    data: jpeg,
                    filename: "scan.jpg",
                    mimeType: "image/jpeg",
                    episodeIds: preselectedEpisodeId.map { [$0] } ?? []
                )
            } else {
                errorMessage = String(localized: "documents.upload.scanError")
                return
            }
            await uploadAll([draft], unreadable: 0)
        }
    #else
        private func handleScan(_: [Any]) async {}
    #endif

    // MARK: - Upload

    /// Store every draft, then say what happened to all of them.
    ///
    /// The old shape read the store's sticky `lastUploadError` after each hop
    /// and dismissed when it was nil, which made every failure the repository
    /// re-threw untyped look exactly like a success. This asks each upload for
    /// its own outcome, aggregates the whole gesture — including the inputs
    /// that never became drafts — keeps the refused drafts for a retry, and
    /// dismisses only when nothing at all was refused.
    private func uploadAll(_ drafts: [DocumentUploadDraft], unreadable: Int) async {
        guard !drafts.isEmpty || unreadable > 0 else { return }
        errorMessage = nil
        retryDrafts = []
        isUploading = true
        var stored = 0
        var refused: [DocumentUploadDraft] = []
        var reasons: [DocumentOperationError] = []
        for draft in drafts {
            let outcome = await store.upload(draft)
            if let reason = outcome.failure {
                reasons.append(reason)
                refused.append(draft)
            } else {
                stored += outcome.succeededCount
            }
        }
        isUploading = false
        let outcome = DocumentImportOutcome(
            selected: drafts.count + unreadable,
            uploaded: stored,
            unreadable: unreadable,
            failures: reasons
        )
        retryDrafts = refused
        errorMessage = outcome.failedCount == 0 ? nil : Self.message(for: outcome)
        if outcome.isComplete { dismiss() }
    }

    /// The one sentence an import gets. A single reason speaks for itself; a
    /// mixed result states the ratio rather than the first thing that broke.
    private static func message(for outcome: DocumentImportOutcome) -> String {
        if outcome.uploaded == 0, let first = outcome.failures.first {
            return message(for: first)
        }
        if outcome.uploaded == 0, outcome.unreadable > 0 {
            return String(format: String(localized: "documents.upload.unreadable"), outcome.unreadable)
        }
        return String(
            format: String(localized: "documents.upload.partial"),
            outcome.uploaded,
            outcome.selected
        )
    }

    /// A classification, never a string match. `moduleDisabled` and
    /// `notAuthenticated` are handled by the surfaces that own them (the
    /// enable-CTA and the re-auth path); here they read as the generic refusal
    /// rather than leaking a protocol word into the sheet.
    private static func message(for error: DocumentOperationError) -> String {
        switch error {
        case let .upload(reason):
            message(for: reason)
        case .moduleDisabled, .notAuthenticated, .superseded:
            String(localized: "documents.error.generic")
        }
    }

    private static func message(for error: DocumentUploadError) -> String {
        switch error {
        case let .fileTooLarge(maxFileBytes):
            String(format: String(localized: "documents.error.fileTooLarge"), DocumentFormat.bytes(maxFileBytes))
        case let .quotaExceeded(quotaBytes, usedBytes):
            String(
                format: String(localized: "documents.error.quotaExceeded"),
                DocumentFormat.bytes(usedBytes),
                DocumentFormat.bytes(quotaBytes)
            )
        case .unsupportedType:
            String(localized: "documents.error.unsupportedType")
        case .rateLimited:
            String(localized: "documents.error.rateLimited")
        case .generic:
            String(localized: "documents.error.generic")
        }
    }
}
