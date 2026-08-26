import SwiftUI

/// The ECG trace: ONE `Path` drawn in a `Canvas` (P8, web `EcgWaveform`).
///
/// **Regulatory framing (load-bearing — do NOT soften).** This is a picture of
/// the recording, nothing more. There are no beat markers, no interval
/// measurements, no annotations, no thresholds and no verdict of any kind —
/// HealthLog does not read the trace. The accessibility label repeats the
/// RECORDING DEVICE's own result verbatim and never adds one.
///
/// **Why not Swift Charts.** The server ships ~2500 min/max-decimated display
/// points; that many marks janks. The web draws a single SVG path for exactly
/// the same reason (`ecg-waveform.tsx:9-19`), so iOS draws a single `Path`.
///
/// **Static.** No draw-on animation, so Reduce Motion has nothing to suppress.
struct EcgWaveformView: View {
    /// Microvolt samples, index-ordered, as served (already decimated).
    let samples: [Double]
    /// The device-attributed spoken description. Passed in so the view never
    /// composes a claim of its own.
    let accessibilityDescription: String

    private static let traceHeight: CGFloat = 160
    private static let strokeWidth: CGFloat = 1.5
    /// Vertical breathing room so an R-wave peak never clips the frame.
    private static let verticalInset: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let path = EcgWaveformMath.path(
                for: samples,
                in: size,
                verticalInset: Self.verticalInset
            )
            context.stroke(
                path,
                with: .color(HLText.primary),
                style: StrokeStyle(lineWidth: Self.strokeWidth, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(height: Self.traceHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityDescription))
    }
}

/// Pure geometry for the trace — separated so the normalisation can be pinned
/// by tests without a view host.
enum EcgWaveformMath {
    /// Maps samples into `0…1` by their own min/max.
    ///
    /// A flat (or single-sample) strip has no span to normalise against, so it
    /// is centred at `0.5` rather than divided by zero — a flat line is the
    /// honest picture of a flat signal, not a crash and not an invented shape.
    static func normalized(_ samples: [Double]) -> [Double] {
        guard let low = samples.min(), let high = samples.max() else { return [] }
        let span = high - low
        guard span > 0 else { return samples.map { _ in 0.5 } }
        return samples.map { ($0 - low) / span }
    }

    /// The trace as ONE path: x is the sample INDEX spread evenly across the
    /// width (the payload carries no per-sample timestamps and iOS must not
    /// invent any), y is the normalised amplitude inset top and bottom.
    ///
    /// Fewer than two samples yields an empty path — nothing to draw is drawn
    /// as nothing.
    static func path(for samples: [Double], in size: CGSize, verticalInset: CGFloat) -> Path {
        var path = Path()
        guard samples.count >= 2, size.width > 0, size.height > 0 else { return path }
        let values = normalized(samples)
        let usableHeight = Swift.max(1, size.height - 2 * verticalInset)
        let step = size.width / CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * step
            // Flip: a high microvolt value belongs at the TOP of the frame.
            let y = verticalInset + (1 - CGFloat(value)) * usableHeight
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}
