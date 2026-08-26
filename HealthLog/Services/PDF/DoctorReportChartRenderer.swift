import Charts
import Foundation
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UIKit)

    /// **Charts-to-PDF bridge (T-7 Commit 3).**
    ///
    /// Renders each `DoctorReportSpec.ChartsBlock.Series` into a `UIImage`
    /// via SwiftUI Charts + `ImageRenderer`. This step is `@MainActor`-
    /// bound because `ImageRenderer` requires the main actor (iOS 16+).
    /// The renderer-actor (`DoctorReportRenderer`) calls this from
    /// `renderData(_:)` and feeds the resulting bitmap array into the
    /// `SectionDrawer`'s `drawCharts` path.
    ///
    /// **Bitmap pool semantics:** images are produced *once* per render
    /// session, on the main actor, then handed to the PDF context. The
    /// renderer-actor itself never touches `MainActor` after the bitmap
    /// pool returns.
    @MainActor
    enum DoctorReportChartRenderer {
        /// Pre-renders every chart series in the block into a UIImage list,
        /// suitable for tiling on a single PDF page.
        static func renderImages(
            _ block: DoctorReportSpec.ChartsBlock,
            tileSize: CGSize = CGSize(width: 540, height: 120)
        ) -> [ChartImage] {
            block.series.map { series in
                ChartImage(
                    kind: series.kind,
                    image: renderSeriesImage(series: series, size: tileSize)
                )
            }
        }

        private static func renderSeriesImage(
            series: DoctorReportSpec.ChartsBlock.Series,
            size: CGSize
        ) -> UIImage? {
            let view = ChartTile(series: series)
                .frame(width: size.width, height: size.height)
                .padding(.horizontal, 0)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2.0
            return renderer.uiImage
        }
    }

    /// One pre-rendered chart bitmap keyed by metric kind.
    struct ChartImage {
        let kind: MetricKind
        /// UIImage is not Sendable; the rendering happens on the main
        /// actor and the image is only consumed inside the same render
        /// call before the renderer-actor returns. We mark Sendable
        /// unchecked at the call site — see `DoctorReportRenderer.renderData`
        /// for the hand-off boundary. Here we model the image as nil-
        /// tolerant so test paths can stub it.
        let image: UIImage?

        // We never cross an actor boundary with this struct; the actor
        // receives the array on its own queue inside renderData() after
        // the MainActor pre-pass completes. Suppress Sendable strictness
        // for the bare nominal type — `UIImage` is reference-typed but
        // immutable after creation.
        // swiftlint:disable:next discouraged_optional_boolean
        var isValid: Bool {
            image != nil
        }
    }

    // MARK: - Chart view

    /// Small-multiples chart tile — one metric per row, sized to a PDF
    /// tile. Uses Apple Charts directly; no HealthLog DesignSystem
    /// styling because the PDF must render against a white background
    /// regardless of the user's app-side dark/light mode.
    ///
    /// **AXChartDescriptor:** wired even though the chart is destined
    /// for a PDF bitmap (not for on-screen rendering with VoiceOver).
    /// Keeps `ChartAXCoverageTests` happy and means a future preview
    /// surface (e.g. an in-app DoctorReport preview) inherits a usable
    /// VoiceOver path for free.
    struct ChartTile: View {
        let series: DoctorReportSpec.ChartsBlock.Series

        // v0.14 light-mode walk: the doctor PDF always prints on white
        // (mode-independent), so it can NOT use the adaptive `HLColor.inkGraphite`
        // token (which inverts to near-white in dark mode and would vanish on
        // the white page). These are fixed print-graphite values: title on
        // `#1C1C1E` (Apple-label), chart line on the softer `#2C2C2E` graphite —
        // premium print-legible, never harsh pure-black.
        private static let printInk = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
        private static let printGraphite = Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(series.kind.displayName)
                    // Fixed print size — renders onto a fixed-metrics PDF page,
                    // Dynamic Type has no meaning for print output (audit-01 M1).
                    // swiftlint:disable:next dynamic_type_bypass
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Self.printInk)
                Chart {
                    ForEach(series.points.indices, id: \.self) { index in
                        let point = series.points[index]
                        LineMark(
                            x: .value("at", point.at),
                            y: .value("value", point.value)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Self.printGraphite)
                        if let secondary = point.secondary {
                            LineMark(
                                x: .value("at", point.at),
                                y: .value("secondary", secondary),
                                series: .value("kind", "diastolic")
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.gray)
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Color.gray.opacity(0.3))
                        AxisValueLabel().foregroundStyle(Self.printGraphite.opacity(0.6))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Color.gray.opacity(0.3))
                        AxisValueLabel().foregroundStyle(Self.printGraphite.opacity(0.6))
                    }
                }
                .background(Color.white)
                .accessibilityChartDescriptor(HLChartDescriptor(makeChartDescriptor()))
            }
            .padding(8)
            .background(Color.white)
        }

        private func makeChartDescriptor() -> AXChartDescriptor {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            let points = series.points.enumerated().map { offset, point in
                AXPoint(x: Double(offset), y: point.value, xLabel: formatter.string(from: point.at))
            }
            return HLChartAX.singleSeries(
                title: series.kind.displayName,
                summary: series.kind.displayName,
                xAxisTitle: "Datum",
                yAxisTitle: series.kind.displayName,
                seriesName: series.kind.displayName,
                points: points.map { ($0.x, $0.y, $0.xLabel) }
            )
        }

        /// Local helper to keep the X-Y-label triple within the lint
        /// rule `large_tuple` (max 2 members) — wrap as a small struct.
        private struct AXPoint {
            let x: Double
            let y: Double
            let xLabel: String
        }
    }

#endif
