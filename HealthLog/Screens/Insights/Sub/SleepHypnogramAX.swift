import Accessibility
import Foundation

/// A11Y (audit-v0162 §5) — pure builder for the measured-hypnogram VoiceOver
/// chart descriptor behind ``SleepHypnogramScreen``. Extracted into its own
/// file (file_length discipline) so the ordered-segment contract stays
/// unit-testable without a SwiftUI render host and the descriptor wiring thin.
///
/// The measured hypnogram chart carried a single flat `.accessibilityLabel`
/// before this — VoiceOver announced one static phrase and nothing about the
/// stages. The descriptor exposes one discrete data point per stage segment,
/// each with a spoken `<stage>, <start> bis <end>` label, so the audio-graph
/// rotor walks the night phase by phase (X = clock time, Y = stage depth).
enum SleepHypnogramAX {
    /// The ORDERED stage segments the descriptor reads: `IN_BED` excluded and
    /// spans clamped to the bed span (both via ``SleepHypnogramLayout``), then
    /// sorted by onset so VoiceOver walks the night chronologically.
    nonisolated static func orderedSegments(for session: SleepSession) -> [SleepSegment] {
        SleepHypnogramLayout.positionedSegments(for: session)
            .sorted { $0.start < $1.start }
    }

    /// Builds the `AXChartDescriptor` for the measured hypnogram. One discrete
    /// data point per ordered segment, each carrying a localized spoken label
    /// naming the stage and its clock span.
    nonisolated static func descriptor(for session: SleepSession) -> AXChartDescriptor {
        let segments = orderedSegments(for: session)
        let duration = max(1, session.end.timeIntervalSince(session.start))

        func clock(_ date: Date) -> String {
            date.formatted(.dateTime.hour().minute())
        }

        let xAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "sleep.hypnogram.a11y.axis.time"),
            range: 0 ... duration,
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                guard value.isFinite else { return "" }
                return clock(session.start.addingTimeInterval(value))
            }
        )

        // Y = stage depth rank (0 = awake … 5 = deep); spoken as the stage name.
        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "sleep.hypnogram.a11y.axis.stage"),
            range: 0 ... 5,
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                guard value.isFinite else { return "" }
                let rank = Int(value.rounded())
                guard let stage = SleepStage.allCases.first(where: { $0.depthRank == rank }) else {
                    return ""
                }
                return String(localized: stage.displayKey)
            }
        )

        let points = segments.map { segment -> AXDataPoint in
            let midX = segment.start.timeIntervalSince(session.start)
                + segment.end.timeIntervalSince(segment.start) / 2
            let label = String(
                localized: "sleep.hypnogram.a11y.segment \(String(localized: segment.stage.displayKey)) \(clock(segment.start)) \(clock(segment.end))"
            )
            return AXDataPoint(
                x: midX,
                y: Double(segment.stage.depthRank),
                label: label
            )
        }

        let series = AXDataSeriesDescriptor(
            name: String(localized: "sleep.hypnogram.a11y.series"),
            isContinuous: false,
            dataPoints: points
        )

        return AXChartDescriptor(
            title: String(localized: "sleep.hypnogram.title"),
            summary: String(
                localized: "sleep.hypnogram.a11y.summary \(segments.count) \(clock(session.start)) \(clock(session.end))"
            ),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}
