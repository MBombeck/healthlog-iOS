import Charts
import SwiftUI

/// **1.5 LAB-LINES (#158, server #1299)** — one lab marker over the
/// metric chart's window, on its own axis directly under the chart.
///
/// Every point is one reading as the server sent it (`labSeries.points`):
/// never averaged, two readings on one day are two points (set a few hours
/// apart so both stay visible). The reference band sits pale behind them; a
/// reading above or below its range is a triangle pointing up or down, the
/// rest are dots. The verdict is the server's `rangeStatus`, never derived,
/// and stays calm like everywhere else in Labs (no alarm colour).
///
/// Tapping a point shows its day, value, verdict, range and the report it
/// was read from; until then the newest reading is shown, so the detail is
/// also there for VoiceOver, which reads every point with its verdict.
struct ChartLabOverlay: View {
    let series: TimelineLabSeries
    /// The chart's window, first and last local day.
    let window: ClosedRange<Date>
    /// A newer window is on its way: the marker dims like the chart above.
    var isRefreshing = false

    @State private var selectedDate: Date?
    @State private var pinnedID: String?

    private var plotted: [ChartLabOverlay.Plotted] {
        Self.plotted(series.points)
    }

    var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                if plotted.isEmpty {
                    Text(Self.emptyLine(name: series.name))
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("insights.labOverlay.empty")
                } else {
                    chart
                        .frame(height: Self.chartHeight)
                        .opacity(isRefreshing ? 0.45 : 1)
                    if let shown = shownPoint {
                        ChartLabPointDetail(point: shown.point, series: series)
                    }
                }
                if series.excluded > 0 {
                    Text(Self.excludedLine(series.excluded))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("insights.labOverlay.excluded")
                }
            }
        }
        .onChange(of: selectedDate) { _, date in
            guard let date, let nearest = Self.nearest(to: date, in: plotted) else { return }
            pinnedID = nearest.id
        }
        .onChange(of: series.key) { _, _ in pinnedID = nil }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Text(verbatim: series.name)
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            if let unit = LabUnit.suffix(series.unit) {
                Text(verbatim: unit)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The point the detail shows: the tapped one, else the newest.
    private var shownPoint: Plotted? {
        if let pinnedID, let match = plotted.first(where: { $0.id == pinnedID }) { return match }
        return plotted.last
    }

    private var chart: some View {
        let domain = Self.valueDomain(points: series.points, band: series.band)
        return Chart {
            if let band = series.band, !band.isEmpty {
                RectangleMark(
                    xStart: .value("chart.labOverlay.day", window.lowerBound),
                    xEnd: .value("chart.labOverlay.day", window.upperBound),
                    yStart: .value("chart.labOverlay.value", band.low ?? domain.lowerBound),
                    yEnd: .value("chart.labOverlay.value", band.high ?? domain.upperBound)
                )
                .foregroundStyle(HLChartTints.seriesLow.opacity(0.18))
                .accessibilityHidden(true)
                // Dashed edges like the band on the lab detail page.
                ForEach([band.low, band.high].compactMap(\.self), id: \.self) { edge in
                    RuleMark(y: .value("chart.labOverlay.value", edge))
                        .foregroundStyle(HLChartTints.seriesLow)
                        .lineStyle(StrokeStyle(lineWidth: HLChartGrid.lineWidth, dash: HLChartGrid.thresholdDash))
                        .accessibilityHidden(true)
                }
            }
            if let shown = shownPoint {
                RuleMark(x: .value("chart.labOverlay.day", shown.date))
                    .foregroundStyle(HLChartTints.seriesLow)
                    .lineStyle(StrokeStyle(lineWidth: HLChartGrid.thresholdWidth, dash: HLChartGrid.thresholdDash))
                    .accessibilityHidden(true)
            }
            ForEach(plotted) { entry in
                PointMark(
                    x: .value("chart.labOverlay.day", entry.date),
                    y: .value("chart.labOverlay.value", entry.point.value)
                )
                .symbol {
                    // A plot symbol is chart geometry, sized like the other
                    // point marks; it must not grow with the text size.
                    Image(systemName: Self.symbolName(entry.point.rangeStatus))
                        // swiftlint:disable:next dynamic_type_bypass
                        .font(.system(size: entry.id == shownPoint?.id ? 13 : 10, weight: .semibold))
                        .foregroundStyle(HLChartTints.series)
                }
                .accessibilityLabel(Text(verbatim: Self.dayText(entry.point.date)))
                .accessibilityValue(Text(verbatim: Self.spokenValue(entry.point, unit: series.unit)))
            }
        }
        .chartXScale(domain: window)
        .chartYScale(domain: domain)
        .chartXSelection(value: $selectedDate)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                    .foregroundStyle(HLChartTints.series.opacity(HLChartGrid.lineOpacity))
                AxisValueLabel()
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
        }
        .chartXAxis { ChartDateAxis.marks(for: [window.lowerBound, window.upperBound]) }
        .accessibilityIdentifier("insights.labOverlay.chart")
    }

    static let chartHeight: CGFloat = 140

    /// One point as drawn: the reading and where on the day axis it sits.
    struct Plotted: Identifiable, Equatable {
        let point: TimelineLabPoint
        let date: Date

        var id: String {
            point.id
        }
    }
}

// MARK: - Pure helpers (testable)

extension ChartLabOverlay {
    /// The readings on the day axis, oldest first. Readings that share a day
    /// stay apart: three hours between neighbours, centred on midday. A point
    /// whose day the build cannot read is left out rather than guessed.
    nonisolated static func plotted(_ points: [TimelineLabPoint], calendar: Calendar = .current) -> [Plotted] {
        var byDay: [String: [TimelineLabPoint]] = [:]
        var order: [String] = []
        for point in points {
            if byDay[point.date] == nil { order.append(point.date) }
            byDay[point.date, default: []].append(point)
        }
        var result: [Plotted] = []
        for day in order {
            guard let noon = TimelineRepository.date(fromDayKey: day, calendar: calendar) else { continue }
            let sameDay = byDay[day, default: []]
            let centre = Double(sameDay.count - 1) / 2
            for (index, point) in sameDay.enumerated() {
                let offset = (Double(index) - centre) * 3 * 3600
                result.append(Plotted(point: point, date: noon.addingTimeInterval(offset)))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    nonisolated static func nearest(to date: Date, in plotted: [Plotted]) -> Plotted? {
        plotted.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// The value axis: every reading and both band edges, with a little room.
    nonisolated static func valueDomain(points: [TimelineLabPoint], band: TimelineLabBand?) -> ClosedRange<Double> {
        let values = (points.map(\.value) + [band?.low, band?.high].compactMap(\.self)).filter(\.isFinite)
        guard let low = values.min(), let high = values.max() else { return 0 ... 1 }
        let span = high - low
        let pad = span > 0 ? span * 0.15 : max(abs(high) * 0.1, 1)
        return (low - pad) ... (high + pad)
    }

    nonisolated static func symbolName(_ status: LabRangeStatus) -> String {
        switch status {
        case .above: "arrowtriangle.up.fill"
        case .below: "arrowtriangle.down.fill"
        case .inRange, .unknown: "circle.fill"
        }
    }

    nonisolated static func dayText(_ dayKey: String) -> String {
        guard let date = TimelineRepository.date(fromDayKey: dayKey) else { return dayKey }
        return date.formatted(.dateTime.day().month(.wide).year().locale(AppLanguage.current.formattingLocale))
    }

    /// The reading as printed: the figure the report printed sets how many
    /// decimals the value keeps, else up to two.
    nonisolated static func valueText(_ point: TimelineLabPoint, unit: String) -> String {
        let digits = point.sourceValue.map(decimals(of:)) ?? 2
        let number = point.value.formatted(.number.precision(.fractionLength(0 ... max(digits, 0))))
        return LabUnit.appending(unit, to: number)
    }

    /// "6,1 %, Über Bereich" for VoiceOver.
    nonisolated static func spokenValue(_ point: TimelineLabPoint, unit: String) -> String {
        "\(valueText(point, unit: unit)), \(point.rangeStatus.localizedLabel)"
    }

    nonisolated static func excludedLine(_ count: Int) -> String {
        count == 1
            ? String(localized: "insights.labOverlay.excluded.one")
            : String(localized: "insights.labOverlay.excluded \(count)")
    }

    nonisolated static func emptyLine(name: String) -> String {
        String(localized: "insights.labOverlay.empty \(name)")
    }

    private nonisolated static func decimals(of value: Double) -> Int {
        guard value.isFinite else { return 2 }
        let text = String(value)
        guard let dot = text.firstIndex(of: "."), !text.contains("e") else { return 0 }
        let fraction = text[text.index(after: dot)...].trimmingCharacters(in: CharacterSet(charactersIn: "0"))
        return min(fraction.count, 4)
    }
}

/// The tapped reading under the marker: day and verdict, value, range and the
/// report it came from (a link only when the server names one).
struct ChartLabPointDetail: View {
    let point: TimelineLabPoint
    let series: TimelineLabSeries

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Text(verbatim: ChartLabOverlay.valueText(point, unit: series.unit))
                    .font(.hlHeadline)
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
                LabRangeBadge(status: point.rangeStatus)
                Spacer(minLength: 0)
            }
            Text(verbatim: ChartLabOverlay.dayText(point.date))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            if let range = LabResultDetailScreen.rangeText(
                low: point.referenceLow,
                high: point.referenceHigh,
                unit: series.unit
            ) {
                Text(verbatim: range)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
            }
            if let report = point.report {
                NavigationLink {
                    RelatedRecordDestination(link: RelatedLink(
                        kind: .document,
                        recordID: report.id,
                        label: Self.reportTitle(report),
                        date: point.date
                    ))
                } label: {
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: "doc.text")
                            .font(.hlCaption)
                            .accessibilityHidden(true)
                        Text(verbatim: Self.reportTitle(report))
                            .font(.hlSubhead)
                            .lineLimit(2)
                            .underline()
                    }
                    .foregroundStyle(HLText.primary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("insights.labOverlay.report.a11y \(Self.reportTitle(report))"))
                .accessibilityIdentifier("insights.labOverlay.report")
            }
        }
    }

    nonisolated static func reportTitle(_ report: TimelineLabReport) -> String {
        let title = report.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? String(localized: "insights.labOverlay.report.untitled") : title
    }
}
