// 20-03 (R6) — the avatar that arrives 23× too big.
//
// `AvatarImageProcessor.encode` allows an UPLOAD of up to 2048 px under a
// 2 MiB cap, and the server stores what it is given; `AvatarRepository`
// requests the bytes back with **no size parameter**, and the display path
// decoded them with a bare `UIImage(data:)` — full pixel dimensions, scale
// **1.0**, no interpolation modifier anywhere.
//
// Both display surfaces are small: `HLProfileAvatar` at 44 pt in the header and
// 64 pt on the profile hero. A 1024 px bitmap at scale 1.0 drawn into 44 pt is
// a ~23× linear downscale performed by the render server on every pass, and at
// scale 1.0 UIKit is told the image is 1024 POINTS wide, so the layout system
// reasons about it wrongly as well.
//
// The contract pinned here: the avatar is decoded ONCE to a bounded thumbnail —
// 256 px, which is 64 pt at 3× (192 px) plus headroom — and it carries the
// screen scale, so `size × scale` is the pixel truth rather than a fiction.
//
// The seam (`AvatarStore.decodedImage(from:)`) is a pure lift of the previous
// private `makeImage` decode, committed before this test and behaviour-
// identical, because a `SwiftUI.Image` exposes neither pixel dimensions nor a
// scale and the display contract had no addressable seam at all.

#if !SWIFT_PACKAGE

    import CoreGraphics
    import Foundation
    @testable import HealthLog
    import Testing
    import UIKit

    @Suite("Avatar thumbnail — bounded pixels, honest scale (20-03)")
    @MainActor
    struct AvatarThumbnailTests {
        /// The largest rendered size is 64 pt; at 3× that is 192 px. 256 px is
        /// the next power-of-two bound above it and is what the store must not
        /// exceed.
        private static let bound = 256

        /// A 1024×1024 JPEG — the size an upload is allowed to land at.
        private nonisolated static func oversizedJPEG() throws -> Data {
            let side = 1024
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: side, height: side),
                format: {
                    let format = UIGraphicsImageRendererFormat.default()
                    format.scale = 1
                    format.opaque = true
                    return format
                }()
            )
            let image = renderer.image { context in
                // Not a flat fill: a flat image compresses to almost nothing and
                // would let a decoder short-circuit in ways a real photo cannot.
                for row in 0 ..< 16 {
                    for column in 0 ..< 16 {
                        let shade = CGFloat((row * 16 + column) % 255) / 255
                        context.cgContext.setFillColor(
                            red: shade, green: 1 - shade, blue: shade / 2, alpha: 1
                        )
                        context.cgContext.fill(CGRect(
                            x: column * side / 16,
                            y: row * side / 16,
                            width: side / 16,
                            height: side / 16
                        ))
                    }
                }
            }
            return try #require(image.jpegData(compressionQuality: 0.9))
        }

        @Test("Das Avatar-Bild kommt beschnitten und mit ehrlichem Maßstab an")
        func avatarDecodesToABoundedThumbnailAtScreenScale() throws {
            let data = try Self.oversizedJPEG()
            let decoded = try #require(AvatarStore.decodedImage(from: data))

            let pixelWidth = Int((decoded.size.width * decoded.scale).rounded())
            let pixelHeight = Int((decoded.size.height * decoded.scale).rounded())
            let expectedScale = UIScreen.main.scale

            let bounded = pixelWidth <= Self.bound
                && pixelHeight <= Self.bound
                && decoded.scale == expectedScale
            #expect(
                bounded,
                """
                EXPECTED_RED: UIImage(data:) returns \(pixelWidth)×\(pixelHeight) px at \
                scale \(decoded.scale), so a 64 pt avatar downscales the full upload on every draw
                """
            )
        }

        /// The bound must not be reached by throwing the image away: a decoded
        /// avatar that is blank is worse than a big one.
        @Test("Das beschnittene Bild ist ein echtes Bild, kein leerer Platzhalter")
        func theThumbnailIsStillAnImage() throws {
            let data = try Self.oversizedJPEG()
            let decoded = try #require(AvatarStore.decodedImage(from: data))
            #expect(decoded.size.width > 0 && decoded.size.height > 0)
            #expect(decoded.cgImage != nil, "the thumbnail must be backed by real pixels")
        }

        /// Undecodable bytes still resolve to `nil` so the display surface falls
        /// back to the initials monogram — the "never a broken state" contract
        /// the store documents.
        @Test("Unlesbare Bytes bleiben nil, damit das Monogramm greift")
        func undecodableBytesStayNil() {
            #expect(AvatarStore.decodedImage(from: Data([0x00, 0x01, 0x02])) == nil)
        }
    }

#endif
