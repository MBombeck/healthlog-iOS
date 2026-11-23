import PhotosUI
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// Standalone sheet that captures a photo of a medication package, runs
/// on-device OCR, asks Apple FoundationModels or, as the fallback, the
/// lexical heuristic to extract a `MedicationDraft`, and hands the
/// confirmed draft back to the caller via an async callback.
///
/// **Touch-disjoint with T-3 (AddMedicationSheet):** this sheet does NOT
/// modify T-3's create flow. The contract for post-merge wiring:
///
/// ```swift
/// PhotoOfMedSheet { draft in
///     // T-3's AddMedicationSheet will prefill its form fields from the
///     // confirmed draft.
///     await self.prefillFields(from: draft)
/// }
/// ```
///
/// The `onConfirm` closure is `(MedicationDraft) async -> Void` — async
/// because the caller may need to await form-prefill, and `Void` returning
/// because the sheet dismisses itself on confirm (the caller decides what
/// to do with the draft thereafter).
///
/// **No clinical-claim UX:** the preview card reads "Erkanntes Medikament:"
/// (DE) / "Detected medication:" (EN) and explicitly states that the user
/// must verify before saving. No auto-confirm path — the user must tap
/// "Übernehmen" to dispatch the callback.
///
/// TODO(maintainer, 2026-07-15, BH-L2): this file uses ~13 English string literals as
/// LocalizedStringKeys (button titles + error messages) — pre-existing file-wide
/// debt, not new. Localize the whole file into Localizable.xcstrings (de+en) in
/// one sweep rather than piecemeal; converting individual strings creates
/// intra-file inconsistency. Tracked separately from the Lab-OCR reconciliation.
public struct PhotoOfMedSheet: View {
    /// Callback fired when the user taps "Übernehmen". Receives the
    /// MDR-filtered (FoundationModels) or heuristic-extracted (fallback)
    /// `MedicationDraft`. Async so callers can await form-prefill.
    public let onConfirm: (MedicationDraft) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: PhotoOfMedState = .pickingSource
    @State private var ocrService = MedicationOCRService()
    @State private var extractionService = MedicationExtractionService()
    @State private var pickerSelection: PhotosPickerItem?
    @State private var showScanner = false

    public init(onConfirm: @escaping (MedicationDraft) async -> Void) {
        self.onConfirm = onConfirm
    }

    public var body: some View {
        // A sheet of steps: close leads out, the preview's own pair accepts
        // or retakes.
        HLSheetScaffold("Photograph medication") {
            content
        }
        #if canImport(UIKit) && canImport(VisionKit)
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView(
                onScan: { images in
                    showScanner = false
                    state = .processing
                    Task { await runPipeline(onFirstOf: images) }
                },
                onCancel: { showScanner = false },
                onError: {
                    showScanner = false
                    state = .error(message: "An error occurred while reading the photo.")
                }
            )
            .ignoresSafeArea()
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .pickingSource:
            sourcePicker
        case .processing:
            processingView
        case let .preview(draft, _):
            previewCard(draft: draft)
        case let .error(message):
            errorView(message: message)
        }
    }

    // MARK: - Sub-views

    private var sourcePicker: some View {
        HLEmptyState(
            icon: "pill.fill",
            title: "Choose photo",
            message: "Photograph the front of a medication package — name and dose are read on-device. The photo never leaves your iPhone."
        ) {
            VStack(spacing: HLSpace.md) {
                #if canImport(UIKit) && canImport(VisionKit)
                    if DocumentScannerView.isSupported {
                        HLButton("Capture with camera", systemImage: "camera.fill") {
                            showScanner = true
                        }
                    }
                #endif
                // The picker brings its own button, so it takes only the label.
                PhotosPicker(selection: $pickerSelection, matching: .images, photoLibrary: .shared()) {
                    HLButtonLabel("Choose from library", systemImage: "photo.fill", variant: .secondary)
                }
                .hlPressable()
            }
        }
        .padding()
        .onChange(of: pickerSelection) { _, newValue in
            guard let newValue else { return }
            state = .processing
            Task { await processPickerItem(newValue) }
        }
    }

    private var processingView: some View {
        HLInlineProgress("Reading photo …")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewCard(draft: MedicationDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    HLCardLabel("Detected medication")
                    Text(draft.name)
                        .font(.hlHeadline)
                }
                HLFactGroup {
                    if let dose = draft.doseStrength {
                        HLFactRow("Dose strength", value: dose)
                    }
                    if let form = draft.doseForm {
                        HLFactRow("Dose form", value: form)
                    }
                    if let manufacturer = draft.manufacturerHint {
                        HLFactRow("Manufacturer", value: manufacturer)
                    }
                }
                // The next step is the form itself; no line announces it.
                HLButtonPair {
                    HLButton("Use", systemImage: "checkmark") {
                        Task { await confirm(draft: draft) }
                    }
                } secondary: {
                    HLButton("Retake", systemImage: "arrow.uturn.backward", variant: .secondary, action: retake)
                }
            }
            .padding()
        }
        .accessibilityElement(children: .contain)
    }

    private func errorView(message: LocalizedStringKey) -> some View {
        HLEmptyState(icon: "exclamationmark.triangle", title: "Could not extract", message: message) {
            HLButton("Retake", systemImage: "arrow.uturn.backward", variant: .secondary, action: retake)
        }
        .padding()
    }

    // MARK: - Actions

    private func retake() {
        pickerSelection = nil
        state = .pickingSource
    }

    private func confirm(draft: MedicationDraft) async {
        await onConfirm(draft)
        dismiss()
    }

    /// Reads the chosen `PhotosPickerItem` as a `UIImage`, runs OCR, runs
    /// the extraction tandem (FoundationModels with heuristic fallback), and
    /// transitions to `.preview` on success or `.error` on any failure.
    private func processPickerItem(_ item: PhotosPickerItem) async {
        #if canImport(UIKit)
            do {
                // A7 LOW — decode off the MainActor. A large captured/picked
                // photo decoded via `UIImage(data:)` on this view method blocks
                // the main thread before OCR; hop to a detached task so the
                // sheet transition doesn't hitch on the decode.
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = await Task.detached(priority: .userInitiated, operation: {
                          UIImage(data: data)
                      }).value else
                {
                    state = .error(message: "Could not load the photo.")
                    return
                }
                await runPipeline(on: image)
            } catch {
                state = .error(message: "Could not load the photo.")
            }
        #else
            state = .error(message: "Photo selection is unavailable on this platform.")
        #endif
    }

    #if canImport(UIKit)
        /// Runs OCR → extraction pipeline on a UIImage.
        /// On devices with Apple Intelligence available, prefers the
        /// FoundationModels tandem; on a fallback reason routes to the
        /// heuristic.
        @MainActor
        private func runPipeline(on image: UIImage) async {
            do {
                let ocr = try await ocrService.recognise(image)
                let outcome = await extractionService.extract(from: ocr.rawText, locale: AppLanguage.current.locale)
                if let draft = outcome.draft {
                    state = .preview(draft: draft, rawText: ocr.rawText)
                    return
                }
                // FoundationModels was unavailable / refused / empty-input —
                // try the lexical heuristic. It works on every iOS 18+
                // device and is the documented fallback.
                if let heuristicDraft = MedicationDraftHeuristic.extract(from: ocr.rawText) {
                    state = .preview(draft: heuristicDraft, rawText: ocr.rawText)
                } else {
                    state = .error(message: "No medication detected in the photo. Try a clearer image or enter the data manually.")
                }
            } catch MedicationOCRError.noTextRecognised {
                state = .error(message: "No text recognised in the photo. Try better lighting or a closer crop.")
            } catch {
                state = .error(message: "An error occurred while reading the photo.")
            }
        }

        /// Camera-capture pipeline entry. Routes the first scanned page from
        /// `DocumentScannerView` (a real `VNDocumentCameraViewController`) into
        /// `runPipeline(on:)`. Replaces the former no-op stub — the meds camera
        /// button now works (INV-1 follow-up: the doc scanner built for labs
        /// also fixes the long-standing meds camera no-op).
        @MainActor
        private func runPipeline(onFirstOf images: [UIImage]) async {
            guard let first = images.first else {
                state = .error(message: "An error occurred while reading the photo.")
                return
            }
            await runPipeline(on: first)
        }
    #endif

    // MARK: - State machine

    private enum PhotoOfMedState: Equatable {
        case pickingSource
        case processing
        case preview(draft: MedicationDraft, rawText: String)
        case error(message: LocalizedStringKey)

        static func == (lhs: PhotoOfMedState, rhs: PhotoOfMedState) -> Bool {
            switch (lhs, rhs) {
            case (.pickingSource, .pickingSource): true
            case (.processing, .processing): true
            case let (.preview(l, _), .preview(r, _)): l == r
            case (.error, .error): true
            default: false
            }
        }
    }
}

#if DEBUG && canImport(UIKit)
    #Preview("PhotoOfMedSheet – preview card") {
        PhotoOfMedSheet { _ in }
    }
#endif
