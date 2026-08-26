import SwiftUI
#if canImport(PDFKit)
    import PDFKit
#endif

/// Inline preview of a stored document's original bytes. Renders by
/// `servingClass` (never by a MIME guess): `inline` PDFs via PDFKit, `inline`
/// images via `UIImage`; `attachment`-class files show a download/share box (no
/// fake preview). Fetches the decrypted bytes through the store (pinned session +
/// Bearer token).
struct DocumentPreviewView: View {
    let store: DocumentsStore
    let document: InboundDocument

    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading
        case pdf(Data)
        case image(Data)
        case attachment
        case failed
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                loadingBox
            case let .pdf(data):
                #if canImport(PDFKit)
                    PDFKitView(data: data)
                        .frame(height: 420)
                        .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
                #else
                    attachmentBox
                #endif
            case let .image(data):
                imageView(data)
            case .attachment:
                attachmentBox
            case .failed:
                failedBox
            }
        }
        .task(id: document.id) { await load() }
    }

    // MARK: - Sub-views

    private var loadingBox: some View {
        RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous)
            .fill(HLSurface.secondary)
            .frame(height: 200)
            .overlay { ProgressView() }
            .accessibilityLabel(Text("documents.detail.previewLoading"))
    }

    @ViewBuilder
    private func imageView(_ data: Data) -> some View {
        #if canImport(UIKit)
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
                    .accessibilityLabel(Text("documents.detail.previewImage"))
            } else {
                failedBox
            }
        #else
            attachmentBox
        #endif
    }

    private var attachmentBox: some View {
        VStack(spacing: HLSpace.sm) {
            Image(systemName: DocumentKindMeta.icon(document.kind))
                .font(.hlLargeTitle)
                .foregroundStyle(HLText.secondary)
            Text(document.filename ?? String(localized: "documents.card.untitled"))
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(previewUnavailableLine)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(HLSpace.lg)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
    }

    private var failedBox: some View {
        VStack(spacing: HLSpace.xs) {
            Image(systemName: "exclamationmark.triangle")
                // Audit-01 C2 — same placeholder-glyph role as `attachmentBox`
                // above, so same size (was a raw, smaller `.title2`).
                .font(.hlLargeTitle)
                .foregroundStyle(HLText.tertiary)
            Text("documents.detail.previewFailed")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(HLSpace.lg)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
    }

    private var previewUnavailableLine: String {
        let template = String(localized: "documents.detail.previewUnavailable")
        return String(format: template, DocumentFormat.bytes(document.byteSize))
    }

    // MARK: - Load

    private func load() async {
        // Attachment-class files are never rendered inline (serving posture).
        guard document.servingClass == .inline else {
            phase = .attachment
            return
        }
        phase = .loading
        do {
            let (data, _) = try await store.original(id: document.id)
            if document.mimeType == "application/pdf" || document.mimeType.hasSuffix("/pdf") {
                phase = .pdf(data)
            } else {
                phase = .image(data)
            }
        } catch {
            phase = .failed
        }
    }
}

#if canImport(PDFKit) && canImport(UIKit)
    /// Minimal PDFKit host for inline PDF preview.
    struct PDFKitView: UIViewRepresentable {
        let data: Data

        func makeUIView(context _: Context) -> PDFView {
            let view = PDFView()
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            view.document = PDFDocument(data: data)
            return view
        }

        func updateUIView(_ view: PDFView, context _: Context) {
            if view.document == nil {
                view.document = PDFDocument(data: data)
            }
        }
    }
#endif
