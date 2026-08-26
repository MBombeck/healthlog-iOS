#if canImport(CoreImage)
    import CoreImage
    import CoreImage.CIFilterBuiltins
#endif
import SwiftUI

/// A SwiftUI `Image` rendering a QR code for an arbitrary payload string, generated
/// fully on-device via CoreImage (`CIFilter.qrCodeGenerator()`) — no third-party
/// dependency.
///
/// Used by the share-link sheet to render the `qrUrl` (the share URL with the
/// passphrase in its `#k=` fragment) so the clinician can scan it instead of typing
/// the passphrase. The payload string is **secret** (it embeds the passphrase) — it
/// stays in memory only, is never logged, and is dropped when the host sheet clears
/// its fresh-token state.
///
/// **20-03 (R6) — the contract, corrected.** The comment here used to claim the
/// bitmap was "scaled up … so the output stays crisp at any display size". It
/// was not: a fixed 12× scale put a 120-byte share URL at 660 px, both shipped
/// consumers draw it into 200 pt, and `.interpolation(.none)` above the target
/// size is a nearest-neighbour DOWNSCALE that discards whole module rows.
///
/// What it does now: the CoreImage output is one pixel per module, and it is
/// scaled by `floor(targetPixels / moduleCount)` — the largest INTEGER factor
/// that still fits the pixels the view will occupy. Every module therefore maps
/// to a whole number of pixels and no row can be dropped. `targetPixels` is the
/// consumer's own `side` times the display scale, so the bitmap is sized for the
/// screen it lands on rather than for a constant.
///
/// If a target were ever smaller than the module count no integer factor exists;
/// there the code falls back to smooth interpolation rather than dropping rows,
/// because a truncated symbol does not scan and a soft one does.
///
/// If generation fails (empty payload / encoder error) the view renders an
/// `Image(systemName:)` placeholder instead.
struct QRCodeImage: View {
    /// The string to encode. ASCII-encoded for the QR payload (per the share `qrUrl`
    /// contract, which is an absolute URL).
    let payload: String
    /// The on-screen side length in points. The generated bitmap is sized for it.
    var side: CGFloat = 180

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let cgImage = Self.makeCGImage(from: payload, targetPixels: side * displayScale) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    // Whole modules to whole pixels — see `makeCGImage`. The
                    // moment the bitmap does NOT fit, nearest-neighbour would be
                    // the row-dropper, so it yields to smooth scaling there.
                    .interpolation(CGFloat(cgImage.width) <= side * displayScale ? .none : .medium)
                    .scaledToFit()
                    .frame(width: side, height: side)
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .foregroundStyle(.black)
            }
        }
        // QR codes require a white quiet-zone to scan reliably regardless of the
        // host's light/dark surface — own the white backing here.
        .padding(HLSpace.md)
        .background(
            RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                .fill(Color.white)
        )
        .accessibilityHidden(true)
    }

    /// Deterministically renders `payload` to a `CGImage` QR bitmap sized for
    /// `targetPixels`. Returns `nil` when the payload is empty or the encoder
    /// produces no output. Pure/static so it is unit-testable without a SwiftUI
    /// host.
    ///
    /// - Parameter targetPixels: the pixel side length the bitmap will occupy —
    ///   the consumer's point size times the display scale. The default is
    ///   200 pt at 3×, the densest shipped case, so a caller that cannot know
    ///   its geometry still never overshoots the surfaces that exist.
    nonisolated static func makeCGImage(from payload: String, targetPixels: CGFloat = 600) -> CGImage? {
        #if canImport(CoreImage)
            guard !payload.isEmpty, let data = payload.data(using: .ascii) else { return nil }
            let filter = CIFilter.qrCodeGenerator()
            filter.message = data
            // High error-correction ("H", 30%) so the code still scans from a
            // screen with minor glare/occlusion — the payload is a short URL, so
            // the extra redundancy costs little module density. (QA-b198 M2: was
            // "M", contradicting this doc + the scan-from-screen use case.)
            filter.correctionLevel = "H"
            guard let output = filter.outputImage else { return nil }
            // The generator emits ONE PIXEL PER MODULE, so the extent is the
            // module count. Scale by the largest integer factor that still fits
            // the pixels this bitmap will occupy: every module then covers a
            // whole number of pixels and `.interpolation(.none)` cannot drop a
            // row. Below one module per pixel no integer mapping exists, so the
            // native bitmap is returned and the view interpolates instead.
            let modules = max(output.extent.width, 1)
            let factor = max((targetPixels / modules).rounded(.down), 1)
            let scaled = output.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            let context = CIContext()
            return context.createCGImage(scaled, from: scaled.extent)
        #else
            return nil
        #endif
    }
}
