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
    /// The preview takes the height it is offered (the pane beside the list)
    /// instead of the fixed height of a card in a page.
    var fillsHeight = false

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
                    pdfView(data)
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
            .frame(minHeight: 200, maxHeight: fillsHeight ? .infinity : 200)
            .overlay { ProgressView() }
            .accessibilityLabel(Text("documents.detail.previewLoading"))
    }

    #if canImport(PDFKit)
        @ViewBuilder
        private func pdfView(_ data: Data) -> some View {
            if fillsHeight {
                PDFKitView(data: data).frame(minHeight: 160, maxHeight: .infinity)
            } else {
                PDFKitView(data: data).frame(height: 420)
            }
        }
    #endif

    @ViewBuilder
    private func imageView(_ data: Data) -> some View {
        #if canImport(UIKit)
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: fillsHeight ? .infinity : 420)
                    .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
                    .accessibilityLabel(Text("documents.detail.previewImage"))
            } else {
                failedBox
            }
        #else
            attachmentBox
        #endif
    }

    /// A file without an inline picture shows as one row of the app's
    /// list form: the kind's symbol, the file name, and why there is no
    /// preview with its size. A large empty plate looked like a fault.
    private var attachmentBox: some View {
        fileCard(reason: String(format: String(localized: "documents.detail.previewUnavailable"), DocumentFormat.bytes(document.byteSize)))
    }

    private var failedBox: some View {
        fileCard(reason: HLRowDetail.joined([
            String(localized: "documents.detail.previewFailed"),
            DocumentFormat.bytes(document.byteSize)
        ]) ?? "")
    }

    private func fileCard(reason: String) -> some View {
        HLCard(layout: .rows) {
            HLRow(
                title: Text(verbatim: document.filename ?? String(localized: "documents.card.untitled")),
                detail: Text(verbatim: reason)
            ) {
                // The row stands for the file, not for its kind: a lab
                // report's flask would repeat the lab row under it.
                HLRowGlyph(symbol: "doc.text")
            }
        }
        .accessibilityIdentifier("documents.detail.preview.none")
    }

    // MARK: - Load

    /// A PDF with at least one page.
    static func isReadablePDF(_ data: Data) -> Bool {
        #if canImport(PDFKit)
            (PDFDocument(data: data)?.pageCount ?? 0) > 0
        #else
            false
        #endif
    }

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
                // Bytes that are no readable PDF would leave an empty grey
                // plate; they get the file row instead.
                phase = Self.isReadablePDF(data) ? .pdf(data) : .failed
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
