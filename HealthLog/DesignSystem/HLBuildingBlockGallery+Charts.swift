#if DEBUG
    import Charts
    import SwiftUI

    /// The chart, header and glass blocks on one page, for the screenshot
    /// sweep: the tab header with its action group, an info sheet, a chart
    /// with both axes, a band, a resting scrub and its callout, the statistic
    /// raster, the in-target rail, the sparkline, a dismissible card and the
    /// period choice above the chart. The page stands in for the root when the app
    /// launches with ``launchArgument``; ``Sections`` can also be embedded in
    /// the main block page. Its texts are specimens, not product copy.
    struct HLChartBlocksGallery: View {
        static let launchArgument = "-uitest-chart-blocks"
        static let readyIdentifier = "chartBlocks.ready"
        static let infoIdentifier = "chartBlocks.info"
        static let endIdentifier = "chartBlocks.end"

        var body: some View {
            NavigationStack {
                HLPage {
                    Sections()
                    Text(verbatim: "Ende der Diagrammseite")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .accessibilityIdentifier(Self.endIdentifier)
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        }

        /// The specimens, without a page of their own.
        struct Sections: View {
            @State private var selectedDate: Date? = HLChartBlocksGallery.points[19].at
            @State private var dismissed = false
            @State private var range: HLTimeRange = .standard

            var body: some View {
                HLTabHeader(
                    "Resting heart rate",
                    subtitle: "Last 30 days",
                    titleIdentifier: HLChartBlocksGallery.readyIdentifier,
                    actions: [
                        .coach {},
                        .info(HLChartBlocksGallery.info, identifier: HLChartBlocksGallery.infoIdentifier),
                        .settings(label: "Adjust target range") {}
                    ]
                )
                HLSectionHeader(verbatim: "Vier Aktionen: Mehr fasst die inneren")
                HLTabHeader("Medications", actions: [
                    .add(label: "Add medication") {},
                    .info(HLChartBlocksGallery.info, identifier: "chartBlocks.info.four"),
                    .settings(label: "Adjust target range") {},
                    .coach {}
                ])
                HLSectionHeader(verbatim: "Gepushte Seite: keine Aktionen")
                HLTabHeader(LocalizedStringResource(String.LocalizationValue(HLChartBlocksGallery.markerName)), actions: .none)

                HLSectionHeader(verbatim: "Statistik")
                HLStatGrid(cells: [
                    HLStatCell(label: "Min", value: "52", unit: "bpm"),
                    HLStatCell(label: "Ø", value: "58,4", unit: "bpm"),
                    HLStatCell(label: "Max", value: "66", unit: "bpm"),
                    HLStatCell(label: "Median", value: "58", unit: "bpm")
                ])

                HLSectionHeader(verbatim: "Zeitraum über dem Diagramm, abgetastet, mit Zielbereich")
                HLPeriodPicker(selection: $range)
                HLCard {
                    chart
                }

                HLSectionHeader(verbatim: "Im Zielbereich")
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.md) {
                        RangeBandRow(share: 84, window: "30 T")
                        RangeBandRow(band: RangeBand(lowerLabel: "50", upperLabel: "60", unit: "bpm", pctInRange: 62))
                    }
                }

                HLSectionHeader(verbatim: "Sparkline")
                HLCard {
                    HLSparkline(values: HLChartBlocksGallery.points.map(\.value))
                        .frame(height: HLChartStyle.heightCompact)
                }

                if !dismissed {
                    HLCard {
                        HStack(alignment: .top) {
                            Text(verbatim: "Hinweis zum Wegklicken")
                                .font(.hlSubhead.weight(.semibold))
                                .foregroundStyle(HLText.primary)
                            Spacer()
                            HLDismissButton { dismissed = true }
                        }
                    }
                }
            }

            private var chart: some View {
                let points = HLChartBlocksGallery.points
                return Chart {
                    ForEach(points, id: \.at) { point in
                        LineMark(x: .value(Text(verbatim: "Datum"), point.at), y: .value(Text(verbatim: "Wert"), point.value))
                            .foregroundStyle(HLChartTints.series)
                            .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth))
                            .interpolationMethod(.monotone)
                    }
                    // After the series, so the label lies above the curve.
                    HLChartReferenceLines.band(lower: 50, upper: 60, label: "Zielbereich", unit: "bpm")
                    HLChartScrubber.marks(selectedDate: selectedDate, in: points, date: \.at, value: \.value) { point in
                        HLScrubCallout(
                            title: HLDateFormat.dayMonth(point.at),
                            value: HLValueFormat.number(point.value, fractionDigits: 0 ... 0),
                            unit: "bpm"
                        )
                    }
                }
                .chartYScale(domain: 44 ... 70)
                .hlChartAxes(dates: points.map(\.at), unit: "bpm")
                .hlChartScrub($selectedDate)
                .accessibilityChartDescriptor(HLChartDescriptor(HLChartAX.singleSeries(
                    title: "Ruhepuls",
                    summary: "Dreißig Tage Ruhepuls",
                    xAxisTitle: "Datum",
                    yAxisTitle: "bpm",
                    seriesName: "Ruhepuls",
                    points: points.enumerated().map { index, point in
                        (x: Double(index), y: point.value, xLabel: HLDateFormat.dayMonth(point.at))
                    }
                )))
                .frame(height: HLChartStyle.heightRegular)
            }
        }

        /// A name from data, shown as it is.
        static let markerName = "Ferritin"

        struct Point {
            let at: Date
            let value: Double
        }

        /// Thirty days of a resting pulse, fixed so the picture never changes.
        static let points: [Point] = (0 ..< 30).map { day in
            let start = Date(timeIntervalSince1970: 1_793_000_000)
            let wave = sin(Double(day) / 3.0) * 4
            return Point(at: start.addingTimeInterval(Double(day) * 86400), value: 57 + wave + Double(day % 3))
        }

        static var info: HLInfoContent {
            HLInfoContent(
                title: "Ruhepuls",
                identifier: "chartBlocks.info.sheet",
                about: "Der Ruhepuls ist dein Puls in völliger Ruhe, am besten morgens vor dem Aufstehen gemessen.",
                sections: [
                    .init(
                        title: "So liest du das Diagramm",
                        paragraphs: ["Halte den Finger auf dem Diagramm und zieh ihn zur Seite, um jeden Wert zu lesen."]
                    )
                ]
            )
        }
    }

    extension HLBuildingBlockGallery {
        /// The chart, header and glass specimens, for the main block page.
        var chartBlockSections: some View {
            HLChartBlocksGallery.Sections()
        }
    }
#endif
