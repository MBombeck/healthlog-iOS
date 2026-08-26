#if canImport(UIKit) && canImport(VisionKit)
    import SwiftUI
    import UIKit
    import VisionKit

    /// A real document scanner over `VNDocumentCameraViewController` — edge
    /// detection, perspective correction, multi-page. The correct, higher-quality
    /// camera primitive for photographing a paper document (a lab report, a
    /// medication package), far better than `UIImagePickerController`.
    ///
    /// Shared by the medications (`PhotoOfMedSheet`) and documents
    /// (`DocumentUploadSheet`) photo flows. Privacy: the scan stays on-device —
    /// nothing is uploaded without an explicit user action.
    struct DocumentScannerView: UIViewControllerRepresentable {
        /// Fired with the captured page images on a successful scan.
        let onScan: ([UIImage]) -> Void
        /// Fired when the user cancels the scanner without a capture.
        let onCancel: () -> Void
        /// Fired on a scanner failure (camera unavailable, capture error).
        let onError: () -> Void

        func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
            let controller = VNDocumentCameraViewController()
            controller.delegate = context.coordinator
            return controller
        }

        func updateUIViewController(_: VNDocumentCameraViewController, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(onScan: onScan, onCancel: onCancel, onError: onError)
        }

        /// Whether document scanning is supported on this device (camera +
        /// VisionKit). The capture button hides when `false`.
        static var isSupported: Bool {
            VNDocumentCameraViewController.isSupported
        }

        final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
            private let onScan: ([UIImage]) -> Void
            private let onCancel: () -> Void
            private let onError: () -> Void

            init(
                onScan: @escaping ([UIImage]) -> Void,
                onCancel: @escaping () -> Void,
                onError: @escaping () -> Void
            ) {
                self.onScan = onScan
                self.onCancel = onCancel
                self.onError = onError
            }

            func documentCameraViewController(
                _: VNDocumentCameraViewController,
                didFinishWith scan: VNDocumentCameraScan
            ) {
                var images: [UIImage] = []
                for index in 0 ..< scan.pageCount {
                    images.append(scan.imageOfPage(at: index))
                }
                if images.isEmpty {
                    onError()
                } else {
                    onScan(images)
                }
            }

            func documentCameraViewControllerDidCancel(_: VNDocumentCameraViewController) {
                onCancel()
            }

            func documentCameraViewController(
                _: VNDocumentCameraViewController,
                didFailWithError _: Error
            ) {
                // Don't surface the raw error (it can carry capture-pipeline
                // detail); the recoverable UX is "try again / pick from library".
                HLLog.api.error("DocumentScannerView: document camera failed")
                onError()
            }
        }
    }
#endif
