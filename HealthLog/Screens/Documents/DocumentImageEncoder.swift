import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// On-device image encoding for uploads — re-encodes picked photos to inline
/// JPEG and combines scanned pages into a single inline PDF. Nothing leaves the
/// device here; the encoded bytes are what the store-only upload sends. Mirrors
/// the web client's downscale-before-send (inline-previewable output, HEIC
/// avoided).
enum DocumentImageEncoder {
    #if canImport(UIKit)
        /// Longest-edge cap before JPEG re-encode (web parity: 3000 px). Keeps a
        /// phone photo well inside the per-file cap while staying legible.
        static let maxEdge: CGFloat = 3000

        /// Re-encode arbitrary image bytes to a downscaled JPEG (quality 0.85).
        /// Returns `nil` when the bytes aren't a decodable image.
        static func jpeg(from data: Data) -> Data? {
            guard let image = UIImage(data: data) else { return nil }
            return downscaled(image).jpegData(compressionQuality: 0.85)
        }

        /// Combine scanned page images into a single PDF (one page per image), so
        /// a multi-page scan stores as one inline-previewable document.
        static func pdf(from images: [UIImage]) -> Data? {
            guard !images.isEmpty else { return nil }
            let downscaled = images.map { self.downscaled($0) }
            let renderer = UIGraphicsPDFRenderer()
            return renderer.pdfData { context in
                for image in downscaled {
                    let bounds = CGRect(origin: .zero, size: image.size)
                    context.beginPage(withBounds: bounds, pageInfo: [:])
                    image.draw(in: bounds)
                }
            }
        }

        /// Downscale so the longest edge is ≤ ``maxEdge`` (no upscaling).
        private static func downscaled(_ image: UIImage) -> UIImage {
            let longest = max(image.size.width, image.size.height)
            guard longest > maxEdge else { return image }
            let scale = maxEdge / longest
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
    #else
        static func jpeg(from _: Data) -> Data? {
            nil
        }

        static func pdf(from _: [Any]) -> Data? {
            nil
        }
    #endif
}
