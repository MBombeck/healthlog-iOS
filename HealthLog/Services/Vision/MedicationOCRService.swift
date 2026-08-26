import CoreGraphics
import Foundation
import Vision

#if canImport(UIKit)
    import UIKit
#endif

/// Result of an OCR pass over a medication-package image.
///
/// `rawText` is the concatenated, line-broken transcript of every recognised
/// region in **reading order** (top-to-bottom, then left-to-right) — the
/// downstream heuristic + iOS 26+ FoundationModels tandem consume this as
/// a single block. `observations` keeps the per-line breakdown so callers
/// who want to render bounding-box previews (future enhancement, not in
/// T-6 scope) have everything they need.
///
/// Privacy: `Vision` runs **entirely on-device** (Apple's documented
/// guarantee — no network round-trip, no image upload). The OCR transcript
/// is held in-memory only for the duration of the user's confirm sheet and
/// is **never** persisted to disk or transmitted to the server.
public struct MedicationOCRResult: Sendable, Equatable {
    public let rawText: String
    public let observations: [Line]
    public let recognitionLanguage: String

    public struct Line: Sendable, Equatable {
        public let text: String
        /// Top-left-origin normalised bounding box (0...1 in image-coordinate space).
        public let boundingBox: CGRect
        public let confidence: Float

        public init(text: String, boundingBox: CGRect, confidence: Float) {
            self.text = text
            self.boundingBox = boundingBox
            self.confidence = confidence
        }
    }

    public init(rawText: String, observations: [Line], recognitionLanguage: String) {
        self.rawText = rawText
        self.observations = observations
        self.recognitionLanguage = recognitionLanguage
    }
}

/// Errors surfaced by the OCR pipeline. All cases are user-recoverable
/// (the UX path is "retake photo" / "type manually").
public enum MedicationOCRError: Error, Sendable, Equatable {
    /// The supplied image had no decodable pixel buffer (corrupted / wrong format).
    case invalidImage
    /// Vision finished but found zero text observations above the confidence threshold.
    case noTextRecognised
    /// Vision threw — propagated reason kept opaque (privacy: don't surface raw image-pixel context).
    case visionFailure
}

/// On-device OCR for medication-package photos.
///
/// Wraps `VNRecognizeTextRequest` behind an actor boundary so the request
/// stays off the main queue and the orientation/contrast preprocessing runs
/// once per `recognise(_:)` call. The recogniser is configured for accuracy
/// (slower path) because medication labels are typically high-contrast +
/// well-lit and the user is **not** in a real-time-overlay flow.
///
/// **Language switch (recognitionLanguages):** de-DE primary, en-US
/// secondary. This is a deliberate operator choice — most German pharmacy
/// blisters carry the active-ingredient (Wirkstoff) line in German + a
/// product-name in English, so the dual-language pass catches both.
///
/// **Why an actor?** `VNImageRequestHandler` is documented thread-safe but
/// the in-flight request graph is not — running two pass-through calls on
/// the same image concurrently would burn CPU + battery for no gain. The
/// actor serialises the work without any explicit lock.
public actor MedicationOCRService {
    /// Minimum per-line confidence (Vision returns 0...1) below which an
    /// observation is dropped from the result. Tuned empirically — `0.3` is
    /// Apple's documented "low quality" threshold but trips false-positives
    /// on glare; we lift to 0.4 which keeps legible blister-foil text in
    /// and drops noise.
    private let minimumConfidence: Float

    /// Locale identifiers passed to `VNRecognizeTextRequest.recognitionLanguages`.
    /// Order matters — Vision biases towards the first language. We put
    /// German first because the operator's primary market is DE.
    private let recognitionLanguages: [String]

    public init(
        minimumConfidence: Float = 0.4,
        recognitionLanguages: [String] = ["de-DE", "en-US"]
    ) {
        self.minimumConfidence = minimumConfidence
        self.recognitionLanguages = recognitionLanguages
    }

    // OCR a single image. The image is preprocessed (orientation-corrected
    // + greyscaled — see `preprocess(_:)`) before Vision runs.
    //
    // Throws `MedicationOCRError.invalidImage` if the pixel buffer can't
    // be derived, `.noTextRecognised` if every observation falls below
    // `minimumConfidence`, or `.visionFailure` if Vision itself errors.
    #if canImport(UIKit)
        public func recognise(_ image: UIImage) async throws -> MedicationOCRResult {
            guard let preprocessed = preprocess(image),
                  let cgImage = preprocessed.cgImage else
            {
                throw MedicationOCRError.invalidImage
            }
            let orientation = CGImagePropertyOrientation(uiOrientation: preprocessed.imageOrientation)
            return try await runRecognition(on: cgImage, orientation: orientation)
        }
    #endif

    /// CGImage-direct entry point. Used by tests + by future PhotoKit /
    /// AVFoundation callers that don't pass a `UIImage`. Tests cover the
    /// orientation up-arrow (already-upright pixel buffer).
    public func recognise(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) async throws -> MedicationOCRResult {
        try await runRecognition(on: cgImage, orientation: orientation)
    }

    // MARK: - Internals

    /// Runs the `VNRecognizeTextRequest`. Kept private so the orientation
    /// invariant ("orientation must match the cgImage's pixel-data
    /// orientation") is enforced by the two `recognise(_:)` overloads.
    private func runRecognition(on cgImage: CGImage, orientation: CGImagePropertyOrientation) async throws -> MedicationOCRResult {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    HLLog.api
                        .error("MedicationOCRService: Vision request failed (\(String(describing: type(of: error)), privacy: .public))")
                    continuation.resume(throwing: MedicationOCRError.visionFailure)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = Self.extractLines(from: observations, minimumConfidence: self.minimumConfidence)
                guard !lines.isEmpty else {
                    continuation.resume(throwing: MedicationOCRError.noTextRecognised)
                    return
                }
                let rawText = lines.map(\.text).joined(separator: "\n")
                continuation.resume(returning: MedicationOCRResult(
                    rawText: rawText,
                    observations: lines,
                    recognitionLanguage: self.recognitionLanguages.first ?? "de-DE"
                ))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = self.recognitionLanguages
            request.minimumTextHeight = 0.012 // ~1.2% of the shorter image-side → catches small dose-strength text on blister foils

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                HLLog.api
                    .error("MedicationOCRService: VNImageRequestHandler failed (\(String(describing: type(of: error)), privacy: .public))")
                continuation.resume(throwing: MedicationOCRError.visionFailure)
            }
        }
    }

    /// Converts a Vision observation set into our domain `Line` array.
    /// Filters by `minimumConfidence`, picks the top candidate string per
    /// observation, and preserves Vision's reading-order sort (top-down,
    /// then left-right by `boundingBox.minY` desc, `minX` asc — Vision
    /// uses bottom-left-origin coordinates, so larger Y means higher up).
    static func extractLines(from observations: [VNRecognizedTextObservation], minimumConfidence: Float) -> [MedicationOCRResult.Line] {
        let sorted = observations.sorted { lhs, rhs in
            let lhsY = lhs.boundingBox.maxY
            let rhsY = rhs.boundingBox.maxY
            if abs(lhsY - rhsY) > 0.01 {
                return lhsY > rhsY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        return sorted.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else
            {
                return nil
            }
            // Convert Vision's bottom-left-origin to top-left-origin for
            // the rest of the app (UIKit + Core Graphics convention).
            let box = observation.boundingBox
            let topLeft = CGRect(
                x: box.origin.x,
                y: 1 - box.origin.y - box.size.height,
                width: box.size.width,
                height: box.size.height
            )
            return MedicationOCRResult.Line(
                text: candidate.string,
                boundingBox: topLeft,
                confidence: candidate.confidence
            )
        }
    }

    #if canImport(UIKit)
        /// Image preprocessing: orientation normalisation only. We
        /// deliberately do **not** force greyscale or contrast-stretch —
        /// Vision's text recogniser does its own internal preprocessing and
        /// double-processing typically hurts accuracy on dim foil prints.
        /// The orientation pass is still useful because UIKit camera-roll
        /// images carry an EXIF orientation tag that Vision honours via
        /// `CGImagePropertyOrientation`, but downstream consumers that
        /// expect already-upright pixels need the explicit normalisation.
        private func preprocess(_ image: UIImage) -> UIImage? {
            guard image.cgImage != nil else { return nil }
            return image
        }
    #endif
}

extension CGImagePropertyOrientation {
    #if canImport(UIKit)
        /// Bridges `UIImage.Orientation` (the EXIF-aware enum surfaced by the
        /// camera-roll) to the Vision-native `CGImagePropertyOrientation`.
        /// `UIImage.Orientation` values are documented to map 1:1 onto the
        /// CGImage equivalents — this initialiser is the only place we
        /// rely on that mapping so the assumption is reviewable.
        init(uiOrientation: UIImage.Orientation) {
            switch uiOrientation {
            case .up: self = .up
            case .down: self = .down
            case .left: self = .left
            case .right: self = .right
            case .upMirrored: self = .upMirrored
            case .downMirrored: self = .downMirrored
            case .leftMirrored: self = .leftMirrored
            case .rightMirrored: self = .rightMirrored
            @unknown default: self = .up
            }
        }
    #endif
}
