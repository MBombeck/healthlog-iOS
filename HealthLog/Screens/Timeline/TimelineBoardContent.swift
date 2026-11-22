import SwiftUI

/// One value line with what its row says beside it.
struct TimelineValueRow: Equatable, Identifiable {
    let track: TimelineValueTrack
    let title: String
    /// The newest value in the window, formatted; `nil` without one.
    let latest: String?
    /// The direction of the last step, worded for VoiceOver.
    let trend: String?
    let color: Color

    var id: String {
        track.id
    }
}

/// Everything the board draws, built once per answer, choice and window.
/// The chosen day is not part of it: picking a day redraws only the
/// selection layer and the summary, never the rows.
struct TimelineBoardContent: Equatable {
    let window: TimelineWindow
    let today: Int
    let bucket: TimelineBucket
    let lanes: [TimelineLaneTrack]
    let values: [TimelineValueRow]

    var isEmpty: Bool {
        lanes.isEmpty && values.allSatisfy(\.track.isEmpty)
    }

    static func make(
        read: TimelineRead,
        window: TimelineWindow,
        today: Int,
        chosenValues: [String],
        hiddenLanes: Set<TimelineLaneKey>,
        wording: TimelineWording
    ) -> TimelineBoardContent {
        let lanes = TimelineLaneTrack.tracks(read: read, window: window, today: today, hidden: hiddenLanes) {
            wording.words($0)
        }
        let values = chosenValues.compactMap { key in
            track(for: key, read: read, window: window).map { track in
                TimelineValueRow(
                    track: track,
                    title: wording.title(forValue: key),
                    latest: track.latest.map { wording.value($0.value, key: key) },
                    trend: wording.trend(track.trend),
                    color: TimelinePalette.color(forValue: key)
                )
            }
        }
        return TimelineBoardContent(window: window, today: today, bucket: read.bucket, lanes: lanes, values: values)
    }

    /// The line of `key` when the answer carries it. A key the server left
    /// out (a deleted marker, a module that is off) has no row.
    static func track(for key: String, read: TimelineRead, window: TimelineWindow) -> TimelineValueTrack? {
        if key.hasPrefix("lab:") {
            return read.labSeries.first { $0.key == key }.map { TimelineValueTrack.labTrack($0, window: window) }
        }
        if key.hasPrefix("symptom:") {
            return read.symptomSeries.first { $0.key == key }.map {
                TimelineValueTrack.meanTrack(
                    key: key, source: .symptom, unit: nil, points: $0.points, bucket: read.bucket, window: window
                )
            }
        }
        return read.series.first { $0.key == key }.map {
            TimelineValueTrack.meanTrack(
                key: key, source: .measurement, unit: $0.unit, points: $0.points, bucket: read.bucket, window: window
            )
        }
    }
}

/// The measures of the board's rows at one density.
struct TimelineDensity: Equatable, Sendable {
    let laneRow: CGFloat
    let valuePlot: CGFloat
    let valueRow: CGFloat
    let labelColumn: CGFloat?
    let rowPadding: CGFloat

    static let regular = TimelineDensity(
        laneRow: TimelineMetrics.laneRowHeight, valuePlot: TimelineMetrics.valuePlotHeight,
        valueRow: TimelineMetrics.boardValueRowHeight, labelColumn: nil, rowPadding: HLSpace.xs
    )

    /// A phone held across has about 400 pt of height: shorter rows and a
    /// narrower name column, so the lanes and the first lines fit at once.
    static let short = TimelineDensity(laneRow: 22, valuePlot: 26, valueRow: 32, labelColumn: 128, rowPadding: 0)

    /// A window under 480 pt high is short.
    static func forHeight(_ height: CGFloat) -> TimelineDensity {
        height > 0 && height < 480 ? .short : .regular
    }

    /// The height the density is read from: the page with its safe areas.
    /// The period bar sits in the bottom inset or in the top bar, so where
    /// it stands moves points between the content and the insets but never
    /// changes this sum, and the density it decides cannot flip it back.
    nonisolated static func pageHeight(content: CGFloat, top: CGFloat, bottom: CGFloat) -> CGFloat {
        content + top + bottom
    }

    /// The line height of the small names on the bars (`caption2`) at a
    /// text size, in points: Apple's type ramp with a line spacing of 1.2.
    nonisolated static func nameLineHeight(_ size: DynamicTypeSize) -> CGFloat {
        let points: CGFloat = switch size {
        case .xSmall, .small, .medium, .large: 11
        case .xLarge: 13
        case .xxLarge: 15
        case .xxxLarge: 17
        case .accessibility1: 20
        case .accessibility2: 24
        case .accessibility3: 29
        case .accessibility4: 34
        case .accessibility5: 40
        @unknown default: 11
        }
        return (points * 1.2).rounded(.up)
    }

    /// The rows grown with the text: a bar row keeps its name above the bar
    /// at every size, a value row its name and value, so large text never
    /// spills into the row above or is cut off.
    func scaled(for size: DynamicTypeSize) -> TimelineDensity {
        let extra = Self.nameLineHeight(size) - Self.nameLineHeight(.large)
        guard extra > 0 else { return self }
        return TimelineDensity(
            laneRow: laneRow + extra,
            valuePlot: valuePlot,
            valueRow: valueRow + 2 * extra,
            labelColumn: labelColumn,
            rowPadding: rowPadding
        )
    }
}

/// The fixed measures of the board's rows.
enum TimelineMetrics {
    /// The month names above the plot.
    static let axisHeight: CGFloat = 24
    /// One bar row of a lane: its name above a thin bar.
    static let laneRowHeight: CGFloat = 30
    /// The plot of one value line.
    static let valuePlotHeight: CGFloat = 40
    /// A value row on the board, name and value beside the plot.
    static let boardValueRowHeight: CGFloat = 56
    /// Room under the page for the floating period bar: its capsule, its
    /// margin and a breath.
    static let bottomClearance: CGFloat = 88
    /// The same on a short window, where the period stands in the top bar.
    static let shortBottomClearance: CGFloat = 16
    /// The bar's thickness.
    static let barHeight: CGFloat = 4
}
