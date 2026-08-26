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

// T-7 Commit 3 — `DoctorReportChartRenderer` (MainActor-bound
// ImageRenderer wrapper for SwiftUI Charts → UIImage).
//
// Tests the MainActor hop produces a UIImage per kind, an empty
// charts block produces zero images, and the resulting bitmap pool
// is keyed by `MetricKind` so the SectionDrawer can look up images
// without scanning the array.
#if canImport(UIKit)
    @MainActor
    @Suite("DoctorReportChartRenderer — MainActor ImageRenderer hop")
    struct DoctorReportChartRendererTests {
        private static let now = Date(timeIntervalSince1970: 1_716_000_000)

        @Test("renderImages produces one ChartImage per series in the block")
        func renderImagesCountMatchesSeries() {
            let block = DoctorReportSpec.ChartsBlock(series: [
                makeSeries(kind: .pulse, sampleCount: 5),
                makeSeries(kind: .weight, sampleCount: 5),
                makeSeries(kind: .glucose, sampleCount: 5)
            ])
            let images = DoctorReportChartRenderer.renderImages(block)
            #expect(images.count == 3)
            #expect(images.map(\.kind) == [.pulse, .weight, .glucose])
        }

        @Test("renderImages emits a non-nil UIImage for each non-empty series")
        func renderImagesProducesValidBitmaps() {
            let block = DoctorReportSpec.ChartsBlock(series: [
                makeSeries(kind: .pulse, sampleCount: 5)
            ])
            let images = DoctorReportChartRenderer.renderImages(block)
            #expect(images.count == 1)
            #expect(images[0].isValid)
            #expect(images[0].image?.size.width ?? 0 > 0)
            #expect(images[0].image?.size.height ?? 0 > 0)
        }

        @Test("renderImages survives a series with a single data point")
        func renderImagesSinglePoint() {
            let block = DoctorReportSpec.ChartsBlock(series: [
                makeSeries(kind: .pulse, sampleCount: 1)
            ])
            let images = DoctorReportChartRenderer.renderImages(block)
            #expect(images.count == 1)
            #expect(images[0].isValid)
        }

        @Test("renderImages preserves the canonical MetricKind ordering of the block")
        func renderImagesOrderingMirrorsBlock() {
            let block = DoctorReportSpec.ChartsBlock(series: [
                makeSeries(kind: .glucose, sampleCount: 3),
                makeSeries(kind: .weight, sampleCount: 3),
                makeSeries(kind: .pulse, sampleCount: 3)
            ])
            let images = DoctorReportChartRenderer.renderImages(block)
            #expect(images.map(\.kind) == [.glucose, .weight, .pulse])
        }

        @Test("renderImages handles blood-pressure series with secondary diastolic")
        func renderImagesBloodPressure() {
            let points: [DoctorReportSpec.ChartsBlock.Point] = (0 ..< 5).map { offset in
                DoctorReportSpec.ChartsBlock.Point(
                    at: Date(timeInterval: TimeInterval(offset * 86400), since: Self.now),
                    value: 120 + Double(offset),
                    secondary: 78 + Double(offset)
                )
            }
            let block = DoctorReportSpec.ChartsBlock(series: [
                DoctorReportSpec.ChartsBlock.Series(kind: .bloodPressure, points: points)
            ])
            let images = DoctorReportChartRenderer.renderImages(block)
            #expect(images.count == 1)
            #expect(images[0].isValid)
        }

        // MARK: - Helpers

        private static func makeSeries(
            kind: MetricKind,
            sampleCount: Int
        ) -> DoctorReportSpec.ChartsBlock.Series {
            let points: [DoctorReportSpec.ChartsBlock.Point] = (0 ..< sampleCount).map { offset in
                DoctorReportSpec.ChartsBlock.Point(
                    at: Date(timeInterval: TimeInterval(offset * 86400), since: now),
                    value: Double(70 + offset * 2)
                )
            }
            return DoctorReportSpec.ChartsBlock.Series(kind: kind, points: points)
        }

        private func makeSeries(
            kind: MetricKind,
            sampleCount: Int
        ) -> DoctorReportSpec.ChartsBlock.Series {
            Self.makeSeries(kind: kind, sampleCount: sampleCount)
        }
    }
#endif
