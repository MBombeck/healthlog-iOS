import PDFKit
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// The one feedback shape, for all four outputs.
///
/// The four old cards each invented their own working / ready / error
/// rendering, which is part of why they read as four products rather than four
/// forms of one. Everything the surface says after the action lives here and is
/// driven by ``UnifiedSharingStore/outcome`` alone.
///
/// A freshly minted link reveals its one-time token **in place**, through the
/// same ``ShareLinkTokenPanel`` the link-management sheet renders — one
/// implementation of a Class-D promise, two hosts.
struct UnifiedSharingResultSection: View {
    let store: UnifiedSharingStore
    let linkStore: ShareLinkStore?
    let baseURL: URL?

    /// The width the preview gets, measured on the result's own column.
    @State private var columnWidth: CGFloat?

    var body: some View {
        outcomeBody
    }

    /// Height of the inline report preview at a measured column width. On a
    /// phone it is the 280 pt it always was; where the column is wide (an
    /// iPad, an open Duo) the report is shown at a reading size, about as
    /// tall as it is wide, never more than 640 pt, so a page of the report is
    /// legible without opening the file.
    nonisolated static func previewHeight(width: CGFloat?) -> CGFloat {
        guard let width, width >= regularPreviewMinimum else { return compactPreviewHeight }
        return min(maximumPreviewHeight, (width * 0.9).rounded())
    }

    /// Column width from which the preview grows. A phone's card holds at most
    /// 376 pt, the narrowest regular window more than 480.
    nonisolated static let regularPreviewMinimum: CGFloat = 480
    nonisolated static let compactPreviewHeight: CGFloat = 280
    nonisolated static let maximumPreviewHeight: CGFloat = 640

    @ViewBuilder
    private var outcomeBody: some View {
        if case let .failed(message) = store.outcome {
            Text(verbatim: message)
                .font(.hlFootnote)
                .foregroundStyle(HLColor.statusBad)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sharing.unified.error")
        }
        if let hasSelection = store.emptyBundleHasSelection {
            // An empty server bundle is a contract-correct answer that
            // needs an instruction, not an error and not a file.
            Text(
                hasSelection
                    ? String(localized: "Your saved report selection returned no data, so the server bundle is empty.")
                    : String(
                        localized: "The server bundle follows the selection you save in the doctor report. Save one there first, then generate again."
                    )
            )
            .font(.hlCaption)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("sharing.unified.emptyBundle")
        }
        if store.outcome == .produced {
            if store.didMintLink, let linkStore {
                ShareLinkTokenPanel(store: linkStore, baseURL: baseURL)
            } else if !store.artifacts.isEmpty {
                artifactResult
            }
        }
    }

    private var artifactResult: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            #if canImport(UIKit)
                // The report used to preview itself before it was handed over,
                // and losing that on the way into one surface would have been a
                // silent downgrade — so the preview came along.
                if store.outputForm == .pdf, let pdf = store.artifacts.first(where: { $0.pathExtension == "pdf" }) {
                    PDFInlinePreview(url: pdf)
                        .frame(height: Self.previewHeight(width: columnWidth))
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: HLRadius.md, style: .continuous))
                }
            #endif
            ForEach(store.artifacts, id: \.self) { url in
                Text(url.lastPathComponent)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // No "Source: your server (rendered PDF)" line: which
            // machine rendered the file is a technical detail.
            ShareLink(items: store.artifacts) {
                HLButtonLabel("sharing.unified.result.share", systemImage: "square.and.arrow.up")
            }
            .hlPressable()
            .accessibilityIdentifier("sharing.unified.result.share")
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
    }
}

#if canImport(UIKit)

    /// Moved here with the doctor report it belonged to. A thumbnail of
    /// what is about to leave the device is worth more on the sharing surface
    /// than it was on a screen that only made PDFs.
    private struct PDFInlinePreview: UIViewRepresentable {
        let url: URL

        func makeUIView(context _: Context) -> PDFView {
            let view = PDFView()
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            view.displayDirection = .vertical
            view.backgroundColor = .clear
            view.document = PDFDocument(url: url)
            return view
        }

        func updateUIView(_ view: PDFView, context _: Context) {
            if view.document?.documentURL != url {
                view.document = PDFDocument(url: url)
            }
        }
    }

#endif
