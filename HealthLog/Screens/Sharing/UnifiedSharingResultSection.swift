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

    var body: some View {
        outcomeBody
    }

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
            // CU-13 — an empty server bundle is a contract-correct answer that
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
                        .frame(height: 280)
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
            if let source = store.artifactSource {
                Text(UnifiedSharingCopy.sourceLabel(source, form: store.outputForm))
                    .font(.hlCaption2)
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityIdentifier("sharing.unified.source")
            }
            ShareLink(items: store.artifacts) {
                HStack(spacing: HLSpace.md) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(HLColor.statusOK)
                    Text("sharing.unified.result.share")
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .font(.hlIcon(HLIconSize.sm))
                        .foregroundStyle(HLText.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sharing.unified.result.share")
        }
    }
}

#if canImport(UIKit)

    /// Moved here with the doctor report it belonged to (18-03). A thumbnail of
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
