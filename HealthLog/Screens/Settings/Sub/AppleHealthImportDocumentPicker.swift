import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
    import UIKit
#endif

// Thin `UIViewControllerRepresentable` wrapping `UIDocumentPickerViewController`
// for picking the Apple Health `export.zip`. This is the **sanctioned UIKit
// exception** (per the task brief + PROJECT_GUIDE.md "ausser wo Apple zwingt"): SwiftUI
// has no native zip-file picker for arbitrary on-disk archives, so the document
// picker stays UIKit while everything around it is SwiftUI.
//
// The picked URL is security-scoped: the caller must bracket reads with
// `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.
#if canImport(UIKit)
    struct AppleHealthImportDocumentPicker: UIViewControllerRepresentable {
        /// Called with the picked `file://` URL. The closure runs on the main
        /// actor; the URL is still security-scoped at call time.
        let onPick: (URL) -> Void
        /// Called when the user dismisses the picker without choosing a file.
        let onCancel: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onPick: onPick, onCancel: onCancel)
        }

        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip])
            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_: UIDocumentPickerViewController, context _: Context) {}

        final class Coordinator: NSObject, UIDocumentPickerDelegate {
            private let onPick: (URL) -> Void
            private let onCancel: () -> Void

            init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
                self.onPick = onPick
                self.onCancel = onCancel
            }

            func documentPicker(
                _: UIDocumentPickerViewController,
                didPickDocumentsAt urls: [URL]
            ) {
                guard let url = urls.first else {
                    onCancel()
                    return
                }
                onPick(url)
            }

            func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
                onCancel()
            }
        }
    }
#endif
