import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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
///
/// **LAB-OCR (#149 item 3).** When the server can read reports and the
/// person has given the document AI consent, the chooser offers "Genauer lesen
/// lassen" (``LabServerScanFlow``), off on every scan. Only while it is on does
/// the photo or a PDF go to the server; its rows land in the same review list.
struct LabScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainer) private var container

    let labsStore: LabsStore

    @State private var scan: LabScanStore?
    @State private var showScanner = false
    @State private var showPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    /// LAB-OCR — the server read, `nil` without a server.
    @State private var server: LabServerScanFlow?
    @State private var showPDFImporter = false

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
            // 1.4 B4 — while the values are reviewed, "Speichern" joins
            // "Abbrechen" in the bar and the long title was cut.
            .navigationTitle(Text(scan.map { $0.step == .review || $0.step == .saving } ?? false
                    ? "labs.scan.reviewTitle" : "labs.scan.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task {
                if scan == nil { scan = LabScanStore(labsStore: labsStore) }
                await prepareServerRead()
            }
            .onDisappear { server?.stop() }
            .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
                handlePDF(result)
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
                        Task { await ingest(images) }
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
            LabScanProcessingView(isServerRead: server?.isReading ?? false) {
                server?.cancel(scan: scan)
            }
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
                    // The on-device promise ("never leaves your iPhone") only
                    // stands while the server read is off.
                    Text(usesServerRead ? "labs.ocr.choose.body" : "labs.scan.choose.body")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if serverReadOffered, let server {
                    LabServerReadToggle(flow: server)
                }

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
                    if usesServerRead, server?.acceptsPDF == true {
                        HLButton("labs.ocr.choose.pdf", icon: "doc", variant: .secondary) {
                            showPDFImporter = true
                        }
                        .accessibilityIdentifier("labs.ocr.choose.pdf")
                    }
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

    // MARK: - LAB-OCR — the server read

    /// The server can read reports, the person consented to document AI, and
    /// the `labsOcr` capability is on. Read in the body, so the switch follows
    /// a consent change live.
    private var serverReadOffered: Bool {
        guard let server, server.serverCanRead, let container else { return false }
        #if DEBUG
            if LabOCRFixtures.isActive { return true }
        #endif
        return container.documentExternalAIConsentGranted && container.aiCapabilityGate.isAvailable(.labsOcr)
    }

    /// The person switched the server read on for this scan.
    private var usesServerRead: Bool {
        serverReadOffered && server?.isChosen == true
    }

    private func prepareServerRead() async {
        guard server == nil, let container else { return }
        #if DEBUG
            if LabOCRFixtures.isActive {
                let flow = LabServerScanFlow(repository: LabsOCRRepository(api: container.api, consent: .denied))
                flow.useFixture(LabOCRFixtures.capability)
                server = flow
                if LabOCRFixtures.opensOnReview {
                    flow.isChosen = true
                    scan?.ingest(server: LabOCRFixtures.result)
                }
                return
            }
        #endif
        guard container.backendAvailability.hasServer else { return }
        let flow = LabServerScanFlow(repository: LabsOCRRepository(
            api: container.api,
            consent: container.makeDocumentAIConsentLeaseProvider(),
            uploadGrace: UIKitLabUploadGrace()
        ))
        server = flow
        await flow.loadCapability()
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
            await ingest(images)
        #else
            scan?.report(.platform)
        #endif
    }

    #if canImport(UIKit)
        /// Scanned or picked pages: to the server when the person chose it,
        /// else recognised on the device as before.
        private func ingest(_ images: [UIImage]) async {
            guard let scan else { return }
            if usesServerRead, let server {
                server.read(images: images, into: scan)
            } else {
                await scan.ingest(images: images)
            }
        }
    #endif

    /// LAB-OCR — a picked PDF goes to the server unchanged.
    private func handlePDF(_ result: Result<URL, Error>) {
        guard let scan, let server, usesServerRead else { return }
        guard case let .success(url) = result else {
            scan.report(.load)
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            scan.report(.load)
            return
        }
        server.read(pdf: data, into: scan)
    }
}
