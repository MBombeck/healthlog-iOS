import SwiftUI

/// **v0.8.4 WWIDGET-2 — widget-safe compliance ring.**
///
/// The app's `HLRing` (DesignSystem) depends on app-target-only tokens
/// (`HLChartTints`, `HLText`, `HLSurface`, `HLChartGrid`, `.hlMetric`,
/// `.hlCaption`) that are NOT in the extension's shared source set — only
/// `Tokens.swift` crosses the boundary. Pulling the whole DesignSystem
/// across just to render one ring would drag the app's font + chart stack
/// into the extension. Instead this is a small self-contained ring that
/// mirrors `HLRing`'s geometry contract exactly:
///
/// - Stroke = `max(minStroke, side * strokeRatio)` (the same 8.5 % / 6pt
///   Withings proportion `HLRing.derivedStroke` uses), so the ring reads
///   visually identical to the in-app ring at the same size.
/// - Flat single-accent foreground over a hairline track, `-90°` start,
///   rounded caps — same look as `HLRing`.
///
/// Colours come from the shared ``LAColor`` palette (the app's documented
/// Tonal-Mono design system — monochrome ring foreground over a hairline
/// track, matching `HLRing`'s monochrome `HLChartTints.series`), so the
/// widget reads on-brand without the asset-catalog colours the extension
/// can't resolve.
struct WidgetRing: View {
    /// 0...1 progress.
    let progress: Double
    /// Centre value label, e.g. "4/6". Optional.
    var value: String?
    /// Caption under the value, e.g. "heute". Optional.
    var caption: String?

    /// Mirrors `HLRing.strokeRatio` / `HLRing.minStroke` so the stroke
    /// derivation matches the app ring 1:1.
    private static let strokeRatio: CGFloat = 0.085
    private static let minStroke: CGFloat = 6

    private static func stroke(forSide side: CGFloat) -> CGFloat {
        max(minStroke, side * strokeRatio)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let lineWidth = Self.stroke(forSide: side)
            ZStack {
                Circle()
                    .stroke(
                        LAColor.text.opacity(0.12),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                Circle()
                    .trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(
                        LAColor.accent,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 1) {
                    if let value {
                        // Geometry-locked to the ring side (mirrors
                        // `HLRing`'s `side * fontRatio`): the centre value
                        // must scale with the ring container, not Dynamic
                        // Type, or it overflows the stroke. `minimumScale
                        // Factor` keeps a long "10/10" inside the circle.
                        // swiftlint:disable dynamic_type_bypass
                        Text(value)
                            .font(.system(size: side * 0.26, weight: .semibold).monospacedDigit())
                            // swiftlint:enable dynamic_type_bypass
                            .foregroundStyle(LAColor.text)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                    if let caption {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(LAColor.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .combine)
    }
}
