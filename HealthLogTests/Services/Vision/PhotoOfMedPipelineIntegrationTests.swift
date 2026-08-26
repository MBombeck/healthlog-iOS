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

/// End-to-end integration test for the Photo-of-Med pipeline.
///
/// Drives the actual `MedicationOCRService` against a procedurally rendered
/// CGImage, feeds the OCR transcript into the heuristic (the FoundationModels
/// tandem is gate-bypassed at the simulator level — Apple Intelligence is
/// not available in CI), and verifies the resulting `MedicationDraft` is
/// the one a real user would see in the `PhotoOfMedSheet` preview card.
///
/// This is the contract test for the T-6 hand-off: callers (T-3's
/// `AddMedicationSheet` in the post-merge wiring step) can rely on the
/// pipeline producing a `MedicationDraft` with `name` populated whenever
/// the source image has any legible medication text.
@Suite("Photo-of-Med pipeline — OCR → extraction → draft round-trip (T-6)")
@MainActor
struct PhotoOfMedPipelineIntegrationTests {
    @Test("Pipeline — OCR + heuristic extracts a name + dose from a synthetic blister image")
    func roundTripFromImageToDraft() async throws {
        let image = try Self.renderImage(lines: ["Metformin Hexal", "500 mg", "Filmtablette"])
        let ocrService = MedicationOCRService()
        let extractionService = MedicationExtractionService()

        let ocr = try await ocrService.recognise(cgImage: image)
        #expect(ocr.rawText.isEmpty == false)

        let outcome = await extractionService.extract(from: ocr.rawText, locale: .init(identifier: "de_DE"))
        // On the simulator the FM tandem is unavailable so the outcome
        // falls back. The view layer then routes to the heuristic, which
        // is what we assert directly here.
        let draft: MedicationDraft
        if let extracted = outcome.draft {
            draft = extracted
        } else {
            guard let heuristic = MedicationDraftHeuristic.extract(from: ocr.rawText) else {
                Issue.record("heuristic returned nil for non-empty OCR text")
                return
            }
            draft = heuristic
        }
        // Name should contain "Metformin" or "Hexal" — either survives
        // the heuristic's longest-non-keyword pick.
        let nameLower = draft.name.lowercased()
        #expect(nameLower.contains("metformin") || nameLower.contains("hexal"))
        // Dose should have been captured.
        #expect(draft.doseStrength?.contains("500") == true)
        // Dose form should be Filmtablette (most-specific wins).
        #expect(draft.doseForm == "Filmtablette")
    }

    @Test("Pipeline — onConfirm callback receives the round-tripped draft")
    func onConfirmCallbackRoundTrip() async throws {
        let image = try Self.renderImage(lines: ["Naproxen", "400 mg"])
        let ocrService = MedicationOCRService()
        let ocr = try await ocrService.recognise(cgImage: image)
        guard let draft = MedicationDraftHeuristic.extract(from: ocr.rawText) else {
            Issue.record("heuristic returned nil for non-empty OCR text")
            return
        }

        let box = DraftBox()
        let sheet = PhotoOfMedSheet { incoming in
            await box.store(incoming)
        }
        await sheet.onConfirm(draft)
        let captured = await box.draft
        #expect(captured?.name.lowercased().contains("naproxen") == true)
        #expect(captured?.doseStrength?.contains("400") == true)
        #expect(captured?.source == .heuristic)
    }

    @Test("Pipeline — empty image surfaces noTextRecognised, never reaches onConfirm")
    func emptyImageNeverConfirms() async throws {
        let image = try Self.renderImage(lines: [])
        let ocrService = MedicationOCRService()
        let box = DraftBox()
        _ = PhotoOfMedSheet { incoming in
            await box.store(incoming)
        }

        await #expect(throws: MedicationOCRError.noTextRecognised) {
            _ = try await ocrService.recognise(cgImage: image)
        }
        let captured = await box.draft
        #expect(captured == nil)
    }

    // MARK: - Renderer

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

private actor DraftBox {
    private(set) var draft: MedicationDraft?

    func store(_ draft: MedicationDraft) {
        self.draft = draft
    }
}
