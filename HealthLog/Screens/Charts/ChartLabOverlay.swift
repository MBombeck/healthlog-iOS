import Charts
import SwiftUI

/// One lab marker over the
/// metric chart's window, on its own axis directly under the chart.
///
/// Every point is one reading as the server sent it (`labSeries.points`):
/// never averaged, two readings on one day are two points (set a few hours
/// apart so both stay visible). The reference range is two dashed edges; a
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
                    HLEmptyNote(Text(Self.emptyLine(name: series.name)))
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
                        .hlText(.rowSubtitle)
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
                .hlText(.rowTitle)
            if let unit = LabUnit.suffix(series.unit) {
                Text(verbatim: unit)
                    .hlText(.rowSubtitle)
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
                        .font(.hlIcon(entry.id == shownPoint?.id ? HLIconSize.sm : HLIconSize.xs))
                        .foregroundStyle(HLChartTints.series)
                }
                .accessibilityLabel(Text(verbatim: Self.dayText(entry.point.date)))
                .accessibilityValue(Text(verbatim: Self.spokenValue(entry.point, unit: series.unit)))
            }
            // The reference range as its two edges, never a filled area,
            // drawn after the points so its label stands on top.
            if let band = series.band, !band.isEmpty {
                HLChartReferenceLines.band(lower: band.low, upper: band.high, unit: series.unit)
            }
        }
        .chartXScale(domain: window)
        .chartYScale(domain: domain)
        // Scrubbing pins the nearest reading (with the selection haptic);
        // the detail under the chart shows it.
        .hlChartScrub($selectedDate)
        // The axes of every chart; the unit stands in the card head, so the
        // axis carries none.
        .hlChartAxes(dates: [window.lowerBound, window.upperBound], unit: "", values: .automatic(desiredCount: 3))
        .accessibilityIdentifier("insights.labOverlay.chart")
    }

    /// Every chart with axes has the regular height.
    static let chartHeight: CGFloat = HLChartStyle.heightRegular

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
        return HLDateFormat.date(date, style: .long)
    }

    /// The reading as printed: the figure the report printed sets how many
    /// decimals the value keeps, else up to two.
    nonisolated static func valueText(_ point: TimelineLabPoint, unit: String) -> String {
        let digits = point.sourceValue.map(decimals(of:)) ?? 2
        let number = HLValueFormat.number(point.value, fractionDigits: 0 ... max(digits, 0))
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
                    .hlText(.objectName)
                    .monospacedDigit()
                LabRangeBadge(status: point.rangeStatus)
                Spacer(minLength: 0)
            }
            Text(verbatim: ChartLabOverlay.dayText(point.date))
                .hlText(.rowSubtitle)
            if let range = LabResultDetailScreen.rangeText(
                low: point.referenceLow,
                high: point.referenceHigh,
                unit: series.unit
            ) {
                Text(verbatim: range)
                    .hlText(.rowSubtitle)
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
                    // The link form of the app (``HLLinkButton``): 15
                    // semibold in the quiet ink, no underline, 44 pt tall.
                    // The report's name exists only at run time.
                    HStack(spacing: HLSpace.xs) {
                        Image(systemName: "doc.text")
                            .font(.hlFootnote.weight(.semibold))
                            .accessibilityHidden(true)
                        Text(verbatim: Self.reportTitle(report))
                            .font(.hlSubhead.weight(.semibold))
                            .lineLimit(2)
                    }
                    .foregroundStyle(HLText.secondary)
                    .frame(minHeight: HLLinkButton.hitHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hlRow)
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
