import Foundation
@testable import HealthLog
import Testing
import UIKit

/// **v0.8.0 W11 — client-side downscale respects the server limits.**
///
/// The server caps uploads at 2 MiB + 2048×2048. The processor must shrink an
/// oversized image's longest edge to ≤ `maxDimension` and recompress under the
/// byte cap before the multipart POST.
@Suite("AvatarImageProcessor")
struct AvatarImageProcessorTests {
    /// Renders a solid-colour image at the given pixel size (scale 1).
    private func makeImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test("Downscale shrinks the longest edge to the cap, preserving aspect")
    func downscaleShrinks() {
        let big = makeImage(width: 4032, height: 3024)
        let scaled = AvatarImageProcessor.downscale(big, maxDimension: 1024)
        #expect(max(scaled.size.width, scaled.size.height) <= 1024)
        // Aspect ratio (4:3) preserved within rounding.
        let ratio = scaled.size.width / scaled.size.height
        #expect(abs(ratio - (4032.0 / 3024.0)) < 0.05)
    }

    @Test("Downscale leaves an already-small image untouched")
    func downscaleNoOp() {
        let small = makeImage(width: 256, height: 256)
        let scaled = AvatarImageProcessor.downscale(small, maxDimension: 1024)
        #expect(scaled.size == small.size)
    }

    @Test("encode produces JPEG bytes under the 2 MiB cap and ≤ maxDimension")
    func encodeRespectsLimits() throws {
        let big = makeImage(width: 4032, height: 3024)
        let result = AvatarImageProcessor.encode(big)
        let (data, mime) = try #require(result)
        #expect(mime == "image/jpeg")
        #expect(data.count <= AvatarImageProcessor.maxBytes)
        // The decoded JPEG's longest edge must be within the dimension cap.
        let decoded = try #require(UIImage(data: data))
        #expect(max(decoded.size.width, decoded.size.height) <= AvatarImageProcessor.maxDimension + 1)
    }
}
