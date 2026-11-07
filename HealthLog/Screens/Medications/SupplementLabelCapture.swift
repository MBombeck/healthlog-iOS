import PhotosUI
import SwiftUI

/// SUPP-EDIT (1.5.0, #131 P3) — "Vom Etikettfoto lesen": the label photo
/// part of the composition form.
///
/// Offered only where ``MedicationCompositionAccess/offersLabelPhoto(access:reportsCapabilities:capability:usage:)``
/// says so. The photo comes from the library (an inline `PhotosPicker`) or,
/// on a device with a camera, from the document camera on a pushed page; the
/// frozen presentation census admits no new sheet or cover. Whatever the
/// source, the picture goes out as a JPEG (never HEIC), made smaller until it
/// fits 10 MB (``MedicationIngredientsRepository/labelJPEG(from:limit:)``).
struct SupplementLabelCapture: View {
    let model: MedicationCompositionEditorModel

    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        Section {
            if model.isReading {
                HStack(spacing: HLSpace.sm) {
                    ProgressView()
                    Text("medications.composition.label.reading")
                        .foregroundStyle(HLText.secondary)
                }
                .accessibilityElement(children: .combine)
                Button("medications.composition.label.cancel", role: .cancel) {
                    model.cancelRead()
                }
                .accessibilityIdentifier("medications.composition.label.cancel")
            } else {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Label("medications.composition.label.choosePhoto", systemImage: "photo.on.rectangle")
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("medications.composition.label.library")
                #if canImport(UIKit) && canImport(VisionKit)
                    if DocumentScannerView.isSupported {
                        NavigationLink {
                            SupplementLabelCameraPage(model: model)
                        } label: {
                            Label("medications.composition.label.camera", systemImage: "camera")
                        }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("medications.composition.label.camera")
                    }
                #endif
            }
            if let error = model.labelError {
                HLFormErrorText(error)
                    .font(.hlCaption)
                    .accessibilityIdentifier("medications.composition.label.error")
            }
        } header: {
            Text("medications.composition.label.title")
        } footer: {
            Text("medications.composition.label.footer")
                .font(.hlCaption)
        }
        #if DEBUG && canImport(UIKit)
        .task {
            // The hermetic label world: the system picker runs outside the
            // app, so the form reads a generated photo once it opens.
            guard SuppEditFixtures.readsLabelOnOpen, model.proposal == nil,
                  let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image(actions: { _ in })
                  .jpegData(compressionQuality: 0.85) else { return }
            model.readLabel(jpeg: jpeg)
        }
        #endif
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await read(item) }
        }
    }

    private func read(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            model.reportLocal(.unreadable)
            return
        }
        #if canImport(UIKit)
            let encoded = await Task.detached(priority: .userInitiated) {
                Result { try MedicationIngredientsRepository.labelJPEG(from: data) }
            }.value
            switch encoded {
            case let .success(jpeg): model.readLabel(jpeg: jpeg)
            case let .failure(error): model.reportLocal(SupplementLabelReadFailure(error) ?? .unreadable)
            }
        #else
            model.reportLocal(.unreadable)
        #endif
    }
}

#if canImport(UIKit) && canImport(VisionKit)
    /// The document camera on a pushed page. The first page is the label.
    struct SupplementLabelCameraPage: View {
        let model: MedicationCompositionEditorModel

        @Environment(\.dismiss) private var dismiss

        var body: some View {
            DocumentScannerView(
                onScan: { images in
                    dismiss()
                    guard let first = images.first else { return }
                    Task { await encode(first) }
                },
                onCancel: { dismiss() },
                onError: {
                    model.reportLocal(.unreadable)
                    dismiss()
                }
            )
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
        }

        private func encode(_ image: UIImage) async {
            let encoded = await Task.detached(priority: .userInitiated) {
                Result { try MedicationIngredientsRepository.labelJPEG(from: image) }
            }.value
            switch encoded {
            case let .success(jpeg): model.readLabel(jpeg: jpeg)
            case let .failure(error): model.reportLocal(SupplementLabelReadFailure(error) ?? .unreadable)
            }
        }
    }
#endif
