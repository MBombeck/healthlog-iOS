import PhotosUI
import SwiftUI

/// The lab-report scan flow: **choose a source → recognise on device → review
/// every parsed row → save the batch**.
///
/// The three steps live in one sheet so the user never loses the batch by
/// navigating; ``LabScanStore/step`` decides which is on screen.
///
/// **Nothing leaves the device before the user says so.** VisionKit captures,
/// Vision recognises, ``LabReportParser`` parses — all locally. The only network
/// call in the whole flow is the batch `POST /api/labs` the user triggers from
/// the review screen, and it carries exactly the rows they left switched on.
struct LabScanSheet: View {
    @Environment(\.dismiss) private var dismiss

    let labsStore: LabsStore

    @State private var scan: LabScanStore?
    @State private var showScanner = false
    @State private var showPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            Group {
                if let scan {
                    content(scan: scan)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .hlScreenBackground()
            .navigationTitle(Text("labs.scan.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task {
                if scan == nil { scan = LabScanStore(labsStore: labsStore) }
            }
            .photosPicker(
                isPresented: $showPhotos,
                selection: $photoSelection,
                maxSelectionCount: 4,
                matching: .images
            )
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                Task { await handlePhotos(items) }
            }
            #if canImport(UIKit) && canImport(VisionKit)
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView(
                    onScan: { images in
                        showScanner = false
                        Task { await scan?.ingest(images: images) }
                    },
                    onCancel: { showScanner = false },
                    onError: {
                        showScanner = false
                        scan?.report(.camera)
                    }
                )
                .ignoresSafeArea()
            }
            #endif
        }
    }

    @ViewBuilder
    private func content(scan: LabScanStore) -> some View {
        switch scan.step {
        case .chooser:
            chooser(scan: scan)
        case .processing:
            processing
        case .review, .saving:
            LabScanReviewList(scan: scan)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("labs.action.cancel") { dismiss() }
                .disabled(scan.map { $0.step == .saving } ?? false)
        }
        ToolbarItem(placement: .confirmationAction) {
            if let scan, scan.step == .review || scan.step == .saving {
                Button("labs.scan.save") {
                    Task { await save(scan: scan) }
                }
                .disabled(!scan.canCommit)
                .accessibilityIdentifier("labs.scan.save")
            }
        }
    }

    // MARK: - Step 1 — source chooser

    private func chooser(scan: LabScanStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.lg) {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    Text("labs.scan.choose.title")
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.primary)
                    Text("labs.scan.choose.body")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: HLSpace.sm) {
                    #if canImport(UIKit) && canImport(VisionKit)
                        if DocumentScannerView.isSupported {
                            HLButton("labs.scan.capture", icon: "doc.viewfinder", variant: .primary) {
                                showScanner = true
                            }
                            .accessibilityIdentifier("labs.scan.capture")
                        }
                    #endif
                    HLButton("labs.scan.library", icon: "photo.on.rectangle", variant: .secondary) {
                        showPhotos = true
                    }
                    .accessibilityIdentifier("labs.scan.library")
                }

                if let failure = scan.failure {
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        Text("labs.scan.error.title")
                            .font(.hlHeadline)
                            .foregroundStyle(HLText.primary)
                        HLFormErrorText(failure.message)
                    }
                }
            }
            .padding(HLSpace.lg)
        }
    }

    // MARK: - Step 2 — on-device recognition

    private var processing: some View {
        VStack(spacing: HLSpace.md) {
            ProgressView()
            Text("labs.scan.processing")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func save(scan: LabScanStore) async {
        // `commit()` reloads the labs list once for the whole batch; a partial
        // failure keeps the sheet open with the failed rows still listed.
        if await scan.commit() { dismiss() }
    }

    /// Photo-library source. Images are decoded in-process and handed straight
    /// to the recogniser — nothing is written to disk.
    private func handlePhotos(_ items: [PhotosPickerItem]) async {
        defer { photoSelection = [] }
        #if canImport(UIKit)
            var images: [UIImage] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { continue }
                images.append(image)
            }
            guard !images.isEmpty else {
                scan?.report(.load)
                return
            }
            await scan?.ingest(images: images)
        #else
            scan?.report(.platform)
        #endif
    }
}
