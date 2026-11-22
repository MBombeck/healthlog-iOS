import Accessibility
import Charts
import SwiftUI

/// Per-nutrient detail (Build 7.6, GH #48): the dense day series
/// (`GET /api/nutrients/daily`) plus the server-resolved EFSA reference. The
/// reference and its sex resolution are the server's (`null` when the profile
/// sex is unknown, then the reference line hides); this view never resolves a
/// reference itself.
///
/// Laid out like the metric pages: today's figure, the reference as context,
/// the statistic and the chart over the loaded window, then the history of the
/// days with data. The window is fixed (the server caps it at 90 days), so
/// its section head names it instead of offering a period control.
struct NutrientDetailScreen: View {
    let code: NutrientCode
    let store: NutrientStore

    @State private var selectedDate: Date?
    @State private var showsTargetEditor = false

    var body: some View {
        HLPage {
            if let series = store.dailyByCode[code] {
                todaySection(series)
                referenceSection(series)
                personalTargetSection(series)
                windowSection(series)
                historySection(series)
            } else if store.loadingDaily.contains(code) {
                HLCard {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: HLChartStyle.heightRegular)
                }
            } else {
                HLEmptyState(icon: "leaf", title: "nutrients.detail.empty.title")
            }
            HLSyncStatusFooter(screenLoading: store.loadingDaily.contains(code))
        }
        .navigationTitle(Text(NutrientDisplay.name(for: code)))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.loadDaily(code)
            await store.loadTargets()
        }
        .hlRefresh(in: .scrollView) {
            await store.loadDaily(code)
            await store.loadTargets()
        }
        .sheet(isPresented: $showsTargetEditor) {
            NutrientTargetEditorSheet(code: code, wireUnit: store.dailyByCode[code]?.unit ?? "", store: store)
        }
    }

    private func unit(_ series: NutrientDailySeriesDTO) -> String {
        NutrientDisplay.unitGlyph(series.unit)
    }

    // MARK: - Today

    @ViewBuilder
    private func todaySection(_ series: NutrientDailySeriesDTO) -> some View {
        let latest = series.latestNonEmptyDay
        HLSectionHeader("nutrients.detail.section.today", rank: .area)
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    HLValueText(
                        latest?.amount,
                        unit: HLUnit(symbol: unit(series)),
                        size: .hero,
                        fractionDigits: NutrientDetailSeries.fractionDigits(for: latest?.amount ?? 0)
                    )
                    .accessibilityIdentifier("nutrients.detail.today")
                    // The figure is the latest day with data, which need not
                    // be today; the date says which day it is.
                    if let day = latest?.day, let date = RelatedRecordFormat.date(day) {
                        Text(verbatim: date)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                    }
                }
                NutrientSourceBreakdownView(breakdown: store.latestBreakdown(for: code))
            }
        }
    }

    // MARK: - Reference

    @ViewBuilder
    private func referenceSection(_ series: NutrientDailySeriesDTO) -> some View {
        let amount = series.latestNonEmptyDay?.amount ?? 0
        HLSectionHeader("nutrients.detail.section.reference", rank: .area)
        HLCard {
            if let reference = series.reference {
                referenceProgress(amount: amount, reference: reference, unit: series.unit)
            } else if NutrientDisplay.missingReferenceMeansNoSex(for: code) {
                // Honest to the server contract: a code without a reference
                // of its own (DHA, EPA) says so; otherwise the reference is
                // sex-split and the profile has no sex on file.
                HLEmptyNote("nutrients.detail.reference.unknown")
            } else {
                HLEmptyNote("nutrients.detail.reference.none")
            }
        }
    }

    private func referenceProgress(
        amount: Double,
        reference: NutrientReferenceDTO,
        unit: String
    ) -> some View {
        let fraction = NutrientDisplay.progressFraction(amount: amount, reference: reference.value)
        return VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLFactRow(
                label: Text(verbatim: referenceHeadline(reference)),
                value: Text(verbatim: NutrientDisplay.formatted(amount: reference.value, wireUnit: unit))
            )
            ProgressView(value: min(fraction ?? 0, 1))
                .tint(reference.direction == .upperGuidance ? HLColor.statusWarn : HLColor.statusOK)
                .accessibilityIdentifier("nutrients.detail.progress")
            // The reference values' own citation: the server's reference
            // name is the citation control itself.
            HLSourcesLink(topic: .nutrition, style: .captionText(reference.source))
        }
    }

    // MARK: - Personal target (#182 A2)

    /// The person's own target or limit for this nutrient, against the latest
    /// day, and the one way to set or change it. Only offered where the server
    /// keeps targets (a series that carries `personalTarget`, or a target
    /// already read); an older server shows nothing here.
    @ViewBuilder
    private func personalTargetSection(_ series: NutrientDailySeriesDTO) -> some View {
        if NutrientTargetPresentation.offersTargets(supported: store.targetsSupported, known: store.personalTarget(for: code)) {
            let target = store.personalTarget(for: code)
            HLSectionHeader("nutrients.detail.section.personalTarget", rank: .area)
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    if let target {
                        let amount = series.latestNonEmptyDay?.amount ?? 0
                        HLFactRow(
                            label: Text(NutrientTargetPresentation.label(for: target.direction)),
                            value: Text(verbatim: NutrientDisplay.formatted(amount: target.value, wireUnit: series.unit))
                        )
                        ProgressView(value: min(NutrientDisplay.progressFraction(amount: amount, reference: target.value) ?? 0, 1))
                            .tint(target.direction == .limit ? HLColor.statusWarn : HLColor.statusOK)
                            .accessibilityIdentifier("nutrients.detail.personalTarget.progress")
                    } else {
                        HLEmptyNote("nutrients.detail.personalTarget.none")
                    }
                    HLSettingsActionRow(
                        icon: "target",
                        title: target == nil ? "nutrients.target.set" : "nutrients.target.edit",
                        presents: target == nil ? .create : .sheet
                    ) {
                        showsTargetEditor = true
                    }
                    .accessibilityIdentifier("nutrients.detail.personalTarget.edit")
                }
            }
        }
    }

    /// "Referenzwert (PRI)" / "Zufuhrziel (AI)" / "Obergrenze" prose per kind +
    /// direction.
    private func referenceHeadline(_ reference: NutrientReferenceDTO) -> String {
        let kindKey: String? = switch reference.kind {
        case .pri: "nutrients.reference.kind.pri"
        case .ai: "nutrients.reference.kind.ai"
        case .safeLevel: "nutrients.reference.kind.safeLevel"
        // A kind this build cannot name: the direction alone.
        case .unknown: nil
        }
        let directionKey = reference.direction == .upperGuidance
            ? "nutrients.reference.direction.upper"
            : "nutrients.reference.direction.target"
        let direction = String(localized: String.LocalizationValue(directionKey))
        guard let kindKey else { return direction }
        let kind = String(localized: String.LocalizationValue(kindKey))
        return "\(direction) (\(kind))"
    }

    // MARK: - Statistic and chart

    @ViewBuilder
    private func windowSection(_ series: NutrientDailySeriesDTO) -> some View {
        let days = NutrientDetailSeries.chartDays(series.days)
        if let stats = NutrientDetailSeries.stats(series.days) {
            let windowDays = series.windowDays > 0 ? series.windowDays : 30
            HLSectionHeader("nutrients.detail.section.window \(windowDays)", rank: .area)
            HLStatGrid(cells: [
                HLStatCell(label: String(localized: "Min"), value: number(stats.min), unit: unit(series)),
                HLStatCell(label: String(localized: "chart.stat.mean"), value: number(stats.mean), unit: unit(series)),
                HLStatCell(label: String(localized: "Max"), value: number(stats.max), unit: unit(series)),
                HLStatCell(label: String(localized: "chart.stat.median"), value: number(stats.median), unit: unit(series))
            ])
            HLCard {
                NutrientDetailChart(
                    days: days,
                    unit: unit(series),
                    line: NutrientTargetPresentation.chartLine(
                        personalTarget: store.personalTarget(for: code),
                        reference: series.reference
                    ),
                    selectedDate: $selectedDate
                )
            }
        }
    }

    private func number(_ value: Double) -> String {
        HLValueFormat.number(value, fractionDigits: NutrientDetailSeries.fractionDigits(for: value))
    }

    // MARK: - History

    @ViewBuilder
    private func historySection(_ series: NutrientDailySeriesDTO) -> some View {
        let days = NutrientDetailSeries.history(series.days)
        if !days.isEmpty {
            HLSectionHeader("nutrients.detail.section.history", rank: .area)
            HLCard(layout: .rows) {
                ForEach(days) { day in
                    HLHistoryRow(
                        // The day in the user's date format, not the wire's
                        // `YYYY-MM-DD`.
                        date: Text(verbatim: RelatedRecordFormat.date(day.id) ?? day.id),
                        value: Text(verbatim: NutrientDisplay.formatted(amount: day.amount, wireUnit: series.unit))
                    )
                }
            }
        }
    }
}

/// What the personal-target block and the chart line read, as pure
/// functions (#182 A2).
enum NutrientTargetPresentation {
    /// One dashed line: a floor (an amount to reach) or a ceiling.
    struct ChartLine: Equatable {
        let lower: Double?
        let upper: Double?
    }

    /// The server's rule: a chart prefers the personal target over the
    /// reference (`personalTarget` in the contract).
    static func chartLine(personalTarget: NutrientPersonalTarget?, reference: NutrientReferenceDTO?) -> ChartLine? {
        if let personalTarget {
            return personalTarget.direction == .target
                ? ChartLine(lower: personalTarget.value, upper: nil)
                : ChartLine(lower: nil, upper: personalTarget.value)
        }
        guard let reference else { return nil }
        return reference.direction == .target
            ? ChartLine(lower: reference.value, upper: nil)
            : ChartLine(lower: nil, upper: reference.value)
    }

    /// Targets are offered once the server is known to keep them: the
    /// targets read answered, or a target is already known. A server before
    /// v1.48 has neither, and the block stays away.
    static func offersTargets(supported: Bool, known: NutrientPersonalTarget?) -> Bool {
        supported || known != nil
    }

    static func label(for direction: NutrientTargetDirection) -> String {
        switch direction {
        case .target: String(localized: "nutrients.target.direction.target")
        case .limit: String(localized: "nutrients.target.direction.limit")
        }
    }
}

/// The day bars of one nutrient, with the reference as a dashed line and the
/// same scrub as the metric charts.
private struct NutrientDetailChart: View {
    let days: [NutrientDetailSeries.Day]
    let unit: String
    /// The dashed line: the person's target when set, else the reference.
    let line: NutrientTargetPresentation.ChartLine?
    @Binding var selectedDate: Date?

    var body: some View {
        Chart {
            if let line {
                HLChartReferenceLines.band(lower: line.lower, upper: line.upper, unit: unit)
            }
            ForEach(days) { day in
                BarMark(
                    x: .value(String(localized: "Date"), day.day, unit: .day),
                    y: .value(String(localized: "Value"), day.amount)
                )
                .foregroundStyle(HLChartTints.series)
            }
            HLChartScrubber.marks(selectedDate: selectedDate, in: days, date: \.midday, value: \.amount) { day in
                HLScrubCallout(
                    title: HLDateFormat.date(day.day),
                    value: HLValueFormat.number(day.amount, fractionDigits: NutrientDetailSeries.fractionDigits(for: day.amount)),
                    unit: unit
                )
            }
        }
        .hlChartAxes(dates: days.map(\.day), unit: unit)
        .hlChartScrub($selectedDate) { date in
            HLChartScrubber.nearest(to: date, in: days, date: \.midday).map(spoken)
        }
        .frame(height: HLChartStyle.heightRegular)
        .accessibilityChartDescriptor(HLChartDescriptor(chartDescriptor))
    }

    private func spoken(_ day: NutrientDetailSeries.Day) -> String {
        "\(HLDateFormat.date(day.day)), \(NutrientDisplay.formatted(amount: day.amount, wireUnit: unit))"
    }

    private var chartDescriptor: AXChartDescriptor {
        let unit = unit
        return HLChartAX.singleSeries(
            title: String(localized: "nutrients.detail.chart.a11y"),
            summary: "",
            xAxisTitle: String(localized: "Date"),
            yAxisTitle: unit,
            seriesName: String(localized: "nutrients.detail.chart.a11y"),
            points: days.enumerated().map { index, day in
                (x: Double(index), y: day.amount, xLabel: HLDateFormat.date(day.day))
            },
            yValueLabel: { NutrientDisplay.formatted(amount: $0, wireUnit: unit) }
        )
    }
}
