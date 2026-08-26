// 20-03 (R6) — the QR code that eats its own rows.
//
// `QRCodeImage.makeCGImage(from:)` scales the CoreImage bitmap by a FIXED 12×
// and `filter.correctionLevel = "H"` raised the redundancy, so a 100–130-byte
// share URL lands at ~61–69 modules ≈ 732–828 px. Both shipped consumers draw
// it into **200 pt** (`ShareLinkTokenPanel.swift:115`, new in b267, and
// `TwoFactorFlowSheets.swift:125`) with `.interpolation(.none)`.
//
// `.interpolation(.none)` is nearest-neighbour. Above the target size that is a
// DOWNSCALE, and nearest-neighbour downscaling drops whole module rows — the
// exact opposite of what the file's own comment claims it does ("scaled up with
// a non-interpolating transform so the output stays crisp at any display
// size"). On a 3× device 200 pt is 600 px, so ~132–228 px of module rows are
// discarded, unevenly.
//
// The contract this suite pins: the bitmap handed to SwiftUI is never LARGER
// than the pixels it will occupy, and its width is an integer multiple of the
// module count — so every module maps to a whole number of pixels and no row
// can be dropped.
//
// The module count is derived here with the same CoreImage filter the view
// uses, rather than read from a helper the fix would introduce, so this file
// compiles unmodified against the SHIPPED API and fails behaviourally (13-05's
// lesson: a RED written against a symbol that only exists after the fix is a
// compile error, not a measurement).

#if canImport(CoreImage)
    import CoreImage
    import CoreImage.CIFilterBuiltins
#endif
import CoreGraphics
import Foundation
@testable import HealthLog
import Testing

@Suite("QR render — the bitmap fits the pixels it is drawn into (20-03)")
struct QRCodeImageRenderTests {
    /// A representative share URL: absolute origin, opaque token, passphrase in
    /// the `#k=` fragment. 120 bytes, the middle of the 100–130-byte band the
    /// diagnosis measured.
    private static let shareURL =
        "https://healthlog.example.org/c/8f2c4a91d0b7e3465a8c#k=Qm9vazEyMzQ1Njc4OTBhYmNkZWZnaGlqa2xtbg"

    /// 200 pt at the densest shipped scale — the pixels the bitmap will occupy.
    private static let targetPixels = 200 * 3

    /// The native module count of the QR the view generates, derived from the
    /// same filter and the same correction level. The CoreImage generator emits
    /// one pixel per module (quiet zone included), so the extent IS the count.
    private static func moduleCount(for payload: String) -> Int? {
        #if canImport(CoreImage)
            guard let data = payload.data(using: .ascii) else { return nil }
            let filter = CIFilter.qrCodeGenerator()
            filter.message = data
            filter.correctionLevel = "H"
            guard let output = filter.outputImage else { return nil }
            return Int(output.extent.width)
        #else
            return nil
        #endif
    }

    @Test("Das QR-Bitmap ist nie größer als die Pixel, in die es gezeichnet wird")
    func bitmapNeverExceedsItsTargetAndMapsModulesToWholePixels() throws {
        let modules = try #require(Self.moduleCount(for: Self.shareURL))
        let image = try #require(QRCodeImage.makeCGImage(from: Self.shareURL))

        // Sanity on the instrument itself: a 120-byte payload at "H" really is
        // dense enough for the downscale to bite.
        #expect(modules >= 45, "a 120-byte payload at correction H must be a dense symbol")

        let fitsAndAligns = image.width <= Self.targetPixels
            && image.width % modules == 0
            && image.width == image.height
        #expect(
            fitsAndAligns,
            """
            EXPECTED_RED: the fixed 12× scale renders \(image.width) px into \
            \(Self.targetPixels) px, so `.interpolation(.none)` drops module rows
            """
        )
    }

    /// The floor case the fix must not turn into a row-dropper either: a target
    /// so small that no integer modules-to-pixels mapping exists. There the only
    /// honest answer is smooth interpolation, not a truncated symbol — pinned
    /// here as a shape, not as a promise about a specific size.
    @Test("Ein gültiges Bitmap entsteht auch für einen sehr kleinen Payload")
    func aShortPayloadStillProducesASquareBitmap() throws {
        let image = try #require(QRCodeImage.makeCGImage(from: "hl"))
        #expect(image.width == image.height)
        #expect(image.width > 0)
    }

    /// The payload must survive the render. A downscale that drops module rows
    /// is exactly what breaks this, so the round-trip is the user-visible half
    /// of the same contract.
    @Test("Der gerenderte Code lässt sich wieder zu seinem Payload dekodieren")
    func renderedCodeRoundTripsBackToItsPayload() throws {
        #if canImport(CoreImage)
            let image = try #require(QRCodeImage.makeCGImage(from: Self.shareURL))
            let detector = try #require(CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: CIContext(),
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            ))
            let features = detector.features(in: CIImage(cgImage: image))
            let decoded = features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            #expect(
                decoded.contains(Self.shareURL),
                "the rendered bitmap must still carry the share URL it encodes"
            )
        #endif
    }
}
