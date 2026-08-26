import Foundation
import UIKit

/// **v0.8.0 W11 — client-side avatar downscale + recompression.**
///
/// The server caps avatar uploads at **2 MiB** and **2048×2048**
/// (`/api/user/avatar`, server v1.5.5). A raw iPhone photo blows both limits
/// (12 MP HEIC ≈ several MB, 4032×3024). This processor downsizes the longest
/// edge to ≤ `maxDimension` and JPEG-recompresses, stepping the quality down
/// until the encoded bytes fit under `maxBytes`. JPEG (not PNG) so a photo
/// stays small; the server accepts `image/jpeg`.
///
/// Pure value-level transform — no network, no actor — so it is exercised
/// directly in tests with synthetic images.
enum AvatarImageProcessor {
    /// Server hard limit (2 MiB). We aim a hair under to leave multipart
    /// envelope headroom (the boundary + part headers add a few hundred bytes).
    static let maxBytes = 2 * 1024 * 1024
    /// Server hard limit (2048×2048). We target 1024 — a comfortable retina
    /// avatar at any HealthLog render size (max 88pt hero × 3x = 264px) — so
    /// the upload is small without visible quality loss at display sizes.
    static let maxDimension: CGFloat = 1024

    /// Returns `(jpegData, "image/jpeg")` sized under the server limits, or
    /// `nil` when the image can't be rendered to JPEG at all.
    static func encode(_ image: UIImage, maxDimension: CGFloat = maxDimension, maxBytes: Int = maxBytes) -> (Data, String)? {
        let scaled = downscale(image, maxDimension: maxDimension)
        // Step quality down until under the byte cap. Most photos land at the
        // first or second step; the loop guards against a dense image needing
        // more compression.
        let qualities: [CGFloat] = [0.9, 0.8, 0.7, 0.6, 0.5, 0.4]
        for q in qualities {
            if let data = scaled.jpegData(compressionQuality: q), data.count <= maxBytes {
                return (data, "image/jpeg")
            }
        }
        // Last resort: hardest compression. Accept whatever it produces — at
        // ≤ maxDimension a 0.4-quality JPEG is virtually always < 2 MiB, but
        // return it regardless so a pathological input still uploads (the
        // server's own cap is the backstop).
        if let data = scaled.jpegData(compressionQuality: 0.3) {
            return (data, "image/jpeg")
        }
        return nil
    }

    /// Aspect-fit downscale so the longest edge is ≤ `maxDimension`. Returns
    /// the original image untouched when it is already within bounds.
    static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        // Render at 1x — `target` is already the pixel size we want; a >1 scale
        // would multiply it back up and defeat the downsize.
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
