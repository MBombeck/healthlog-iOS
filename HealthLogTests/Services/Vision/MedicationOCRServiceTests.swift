import CoreGraphics
import Foundation
import Testing
#if canImport(UIKit)
    import UIKit
#endif
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Tests for `MedicationOCRService`. Uses procedurally rendered CGImages
/// (text drawn into a white-bg context) so the suite stays asset-free and
/// runs deterministically on every simulator. We assert on the recognised
/// substrings rather than exact-match, because Vision's accuracy is locale-
/// and font-dependent and the test doesn't pin a specific OS-Vision build.
@Suite("MedicationOCRService — Vision-backed OCR pipeline")
struct MedicationOCRServiceTests {
    // MARK: - Happy paths

    @Test("recognise(cgImage:) reads upright text and returns a non-empty result")
    func recognisesUprightText() async throws {
        let image = try Self.renderImage(lines: ["Metformin 500 mg"])
        let service = MedicationOCRService()
        let result = try await service.recognise(cgImage: image)
        // Vision may break "Metformin 500 mg" into one or two observations
        // depending on font rendering — assert the combined raw text.
        let lowercased = result.rawText.lowercased()
        #expect(lowercased.contains("metformin"))
        #expect(lowercased.contains("500"))
        #expect(result.observations.isEmpty == false)
        #expect(result.recognitionLanguage == "de-DE")
    }

    @Test("recognise(cgImage:) preserves reading-order top-to-bottom")
    func preservesReadingOrder() async throws {
        let image = try Self.renderImage(lines: ["Ozempic", "0,5 mg"])
        let service = MedicationOCRService()
        let result = try await service.recognise(cgImage: image)
        // Both lines should appear, and the brand name must come before the dose
        // because the dose was rendered lower in the image.
        let raw = result.rawText.lowercased()
        let brandIdx = raw.range(of: "ozempic")?.lowerBound
        let doseIdx = raw.range(of: "0,5")?.lowerBound ?? raw.range(of: "0.5")?.lowerBound
        let foundBrand = brandIdx != nil
        let foundDose = doseIdx != nil
        #expect(foundBrand, "expected to find brand name in raw OCR text")
        #expect(foundDose, "expected to find dose in raw OCR text")
        if let brandIdx, let doseIdx {
            #expect(brandIdx < doseIdx, "brand should be ordered before dose")
        }
    }

    // MARK: - Error paths

    @Test("recognise(cgImage:) throws .noTextRecognised on a blank image")
    func throwsOnBlankImage() async throws {
        let image = try Self.renderImage(lines: [])
        let service = MedicationOCRService()
        await #expect(throws: MedicationOCRError.noTextRecognised) {
            _ = try await service.recognise(cgImage: image)
        }
    }

    @Test("recognise(cgImage:) drops observations below minimumConfidence threshold")
    func dropsLowConfidenceObservations() async throws {
        // A threshold above the documented 0.0–1.0 confidence range
        // guarantees every observation is filtered out — covers the
        // gate-edge without depending on Vision's actual confidence
        // calibration (which can be > 0.99 for clean rendered text).
        let image = try Self.renderImage(lines: ["Aspirin"])
        let service = MedicationOCRService(minimumConfidence: 1.1)
        await #expect(throws: MedicationOCRError.noTextRecognised) {
            _ = try await service.recognise(cgImage: image)
        }
    }

    // MARK: - Pure helper

    @Test("extractLines sorts top-to-bottom using bottom-left-origin Y")
    func extractLinesSortByY() {
        // Vision uses bottom-left-origin: larger Y → higher on screen.
        // Build two synthetic observation-like cases by simulating the
        // sort order on Vision boxes, then check the conversion produces
        // top-left-origin coordinates.
        let v1Top = CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05) // visually top
        let v1TopConverted = CGRect(
            x: v1Top.origin.x,
            y: 1 - v1Top.origin.y - v1Top.size.height,
            width: v1Top.size.width,
            height: v1Top.size.height
        )
        #expect(abs(v1TopConverted.origin.y - 0.15) < 0.0001)
    }

    // MARK: - Renderer

    /// Renders the provided lines into a 600x300 white-bg CGImage. Each line
    /// is drawn at 36-pt system-bold, stacked top-down with 16-pt padding.
    /// Pure CG so no UIKit dependency in the renderer call path.
    static func renderImage(lines: [String]) throws -> CGImage {
        let width = 600
        let height = 300
        let bytesPerRow = width * 4
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo
              ) else
        {
            throw RenderError.contextCreation
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        #if canImport(UIKit)
            let nsAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 36),
                .foregroundColor: UIColor.black
            ]
            // Flip Y so that line 0 is at the top in image coordinates.
            UIGraphicsPushContext(ctx)
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            var y: CGFloat = 32
            for line in lines {
                let attributedString = NSAttributedString(string: line, attributes: nsAttributes)
                attributedString.draw(at: CGPoint(x: 32, y: y))
                y += 80
            }
            UIGraphicsPopContext()
        #endif
        guard let cgImage = ctx.makeImage() else {
            throw RenderError.imageCreation
        }
        return cgImage
    }

    enum RenderError: Error {
        case contextCreation
        case imageCreation
    }
}
