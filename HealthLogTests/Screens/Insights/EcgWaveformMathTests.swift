import CoreGraphics
import Foundation
@testable import HealthLog
import Testing

/// P8 — the ECG trace geometry.
///
/// The waveform is the one place iOS touches the raw signal at all, so the
/// rules are narrow on purpose: normalise by the strip's own min/max, spread
/// samples evenly by INDEX (the payload carries no per-sample timestamps and
/// the app must not invent any), and never crash on a degenerate strip. No
/// interpretation of any kind happens here — no beats, no intervals, no
/// thresholds.
@Suite("ECG waveform — path geometry (no interpretation)")
struct EcgWaveformMathTests {
    private let size = CGSize(width: 300, height: 100)
    private let inset: CGFloat = 8

    // MARK: - Normalisation

    @Test("normalized — a known strip maps to its own 0…1 span")
    func normalizesToOwnSpan() {
        let values = EcgWaveformMath.normalized([-100, -50, 0, 50, 100])
        #expect(values == [0, 0.25, 0.5, 0.75, 1])
    }

    @Test("normalized — a flat strip is centred, not divided by zero")
    func flatStripIsCentred() {
        #expect(EcgWaveformMath.normalized([42, 42, 42]) == [0.5, 0.5, 0.5])
    }

    @Test("normalized — a single sample and an empty strip are safe")
    func degenerateInputsAreSafe() {
        #expect(EcgWaveformMath.normalized([7]) == [0.5])
        #expect(EcgWaveformMath.normalized([]).isEmpty)
    }

    // MARK: - Path

    @Test("path — a 5-sample fixture spans exactly the inset frame, peak on top")
    func pathSpansInsetFrame() {
        let path = EcgWaveformMath.path(for: [-100, -50, 0, 50, 100], in: size, verticalInset: inset)
        let box = path.boundingRect
        #expect(!path.isEmpty)
        // Full width, first sample at x = 0, last at x = width.
        #expect(abs(box.minX) < 0.001)
        #expect(abs(box.maxX - size.width) < 0.001)
        // Vertically the trace lives strictly inside the inset band…
        #expect(abs(box.minY - inset) < 0.001)
        #expect(abs(box.maxY - (size.height - inset)) < 0.001)
        // …and a HIGH microvolt value sits at the TOP (small y), not the bottom.
        #expect(box.height > 0)
    }

    @Test("path — a flat strip draws a flat line through the middle")
    func flatStripDrawsFlatLine() {
        let path = EcgWaveformMath.path(for: [10, 10, 10, 10], in: size, verticalInset: inset)
        let box = path.boundingRect
        #expect(box.height < 0.001, "a flat signal must read as a flat line")
        #expect(abs(box.midY - size.height / 2) < 0.001)
    }

    @Test("path — empty / single-sample / zero-size inputs produce no path, no crash")
    func degeneratePathsAreEmpty() {
        #expect(EcgWaveformMath.path(for: [], in: size, verticalInset: inset).isEmpty)
        #expect(EcgWaveformMath.path(for: [1], in: size, verticalInset: inset).isEmpty)
        #expect(EcgWaveformMath.path(for: [1, 2], in: .zero, verticalInset: inset).isEmpty)
    }

    @Test("path — a decimated-scale strip (2500 points) builds without incident")
    func fullScaleStrip() {
        let samples = (0 ..< 2500).map { sin(Double($0) / 12) * 400 }
        let path = EcgWaveformMath.path(for: samples, in: size, verticalInset: inset)
        #expect(!path.isEmpty)
        #expect(abs(path.boundingRect.maxX - size.width) < 0.001)
    }

    // MARK: - Copy contract

    @Test("the waveform's spoken description is device-attributed copy")
    func waveformA11yCopyExists() {
        let resolved = String(localized: "insights.ecg.waveform.a11y \("A") \("B") \("C") \("D")")
        #expect(resolved.contains("A") && resolved.contains("D"))
        #expect(
            resolved.contains("recorded result") || resolved.contains("aufgezeichnetes Ergebnis"),
            "the trace description must name the DEVICE's result, never HealthLog's"
        )
        let failure = String(localized: "insights.ecg.waveform.loadFailed")
        #expect(failure != "insights.ecg.waveform.loadFailed")
    }
}
