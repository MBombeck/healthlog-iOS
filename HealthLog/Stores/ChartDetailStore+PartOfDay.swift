import Foundation

/// **1.5 LAB-LINES, from BP-TOD (#161, server #1331, v1.47.0)** — the
/// blood pressure chart narrowed to the morning, midday or evening.
///
/// Only the chart card follows the choice (and the full-screen chart it opens
/// into). The hero, the statistics, the 30-day card and the range change keep
/// reading the whole day from the server's series, so no figure on the page
/// changes its meaning; the card names the part instead of the change line.
/// The choice lives as long as the page and applies from a week up: a single
/// day has no daily means to narrow.
public struct PartOfDayChart: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed
    }

    /// The chosen part; `nil` is the whole day.
    public internal(set) var part: BloodPressureTimeOfDay.Part?
    public internal(set) var phase: Phase = .idle
    /// The narrowed series on screen and what it was read for. It stays up,
    /// dimmed, while the next part or range is read.
    public internal(set) var series: MeasurementSeries?
    var seriesKey: Key?
    /// The server answered the whole day where a part was asked for: the
    /// choice is withdrawn for the visit.
    public internal(set) var isUnsupported = false

    struct Key: Equatable, Sendable {
        let part: BloodPressureTimeOfDay.Part
        let days: Int
    }

    public init() {}
}

public extension ChartDetailStore {
    /// The part the chart card draws, or `nil` for the whole day.
    var activePartOfDay: BloodPressureTimeOfDay.Part? {
        guard Self.partOfDayApplies(kind: kind, range: range), !partOfDayChart.isUnsupported else { return nil }
        return partOfDayChart.part
    }

    nonisolated static func partOfDayApplies(kind: MetricKind, range: Range) -> Bool {
        kind == .bloodPressure && range != .day
    }

    /// Chooses a part (or the whole day again). The page's extras block reads it.
    func choosePartOfDay(_ part: BloodPressureTimeOfDay.Part?) {
        guard part != partOfDayChart.part else { return }
        partOfDayChart.part = part
        if part == nil {
            partOfDayChart.phase = .idle
        }
    }

    /// Reads the chosen part over the chart's window. A superseded read (the
    /// part or the range moved on) leaves the state for its successor.
    func loadPartOfDay(now: Date = .now, calendar: Calendar = .current) async {
        guard let part = activePartOfDay else { return }
        let key = PartOfDayChart.Key(part: part, days: range.rawValue)
        partOfDayChart.phase = .loading
        let window = Self.partOfDayWindow(days: key.days, now: now, calendar: calendar)
        do {
            let points = try await measurementsRepo.bloodPressureDailySeries(part: part, from: window.from, to: window.to)
            guard activePartOfDay == key.part, range.rawValue == key.days else { return }
            // The statistics only feed the chart's audio graph; the page's
            // figures keep the server's whole-day series.
            let narrowed = points.map { MeasurementSeries(kind: .bloodPressure, points: $0, stats: MetricChartMath.statsFor($0)) }
            partOfDayChart.series = narrowed
            partOfDayChart.seriesKey = key
            partOfDayChart.phase = narrowed == nil ? .failed : .loaded
        } catch is PartOfDayNotNarrowed {
            partOfDayChart.isUnsupported = true
            partOfDayChart.part = nil
            partOfDayChart.phase = .idle
        } catch {
            if Task.isCancelled || ChartLabOverlayModel.isCancellation(error) { return }
            guard activePartOfDay == key.part, range.rawValue == key.days else { return }
            partOfDayChart.phase = .failed
        }
    }

    /// `days` local days ending now, from the first day's midnight.
    nonisolated static func partOfDayWindow(days: Int, now: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: now) ?? now
        return (calendar.startOfDay(for: start), now)
    }

    // MARK: - What the chart card draws

    /// The narrowed series while a part is chosen, else ``displaySeries``.
    var chartCardSeries: MeasurementSeries? {
        activePartOfDay == nil ? displaySeries : partOfDayChart.series
    }

    /// The chart card's points: the narrowed ones while a part is chosen
    /// (none until the first read lands), else ``chartPoints``.
    var chartCardPoints: [SeriesPoint] {
        activePartOfDay == nil ? chartPoints : (partOfDayChart.series?.points ?? [])
    }

    /// The chart card dims and spins while either read is on its way.
    var chartCardIsLoading: Bool {
        isLoading || (activePartOfDay != nil && partOfDayChart.phase == .loading)
    }

    var chartCardHasError: Bool {
        error != nil || (activePartOfDay != nil && partOfDayChart.phase == .failed)
    }

    /// ``accessibilitySeries(units:)`` for what the card draws.
    func chartCardAccessibilitySeries(units: UnitPreferences) -> MeasurementSeries {
        guard activePartOfDay != nil else { return accessibilitySeries(units: units) }
        let plotted = plotPoints(chartCardPoints, units: units)
        return MeasurementSeries(kind: kind, points: plotted, stats: MetricChartMath.statsFor(plotted))
    }

    /// "Tageszeit: Morgens, 04:00 bis 11:59" for the card's caption line.
    nonisolated static func partOfDayCaption(_ part: BloodPressureTimeOfDay.Part) -> String {
        let name = BloodPressureTimeOfDaySection.name(part)
        let hours = partOfDayHours(part)
        return String(localized: "chart.partOfDay.caption \(name) \(hours)")
    }

    /// The part's hours as the server cuts them (`partOfDay` on
    /// `/api/measurements`, v1.47.0): morning 04:00 to 11:59, midday 12:00 to
    /// 17:59, evening 18:00 to 03:59.
    nonisolated static func partOfDayHours(_ part: BloodPressureTimeOfDay.Part) -> String {
        let (start, end) = switch part {
        case .morning: ("04:00", "11:59")
        case .midday: ("12:00", "17:59")
        case .evening: ("18:00", "03:59")
        }
        return String(localized: "insights.bpTimeOfDay.hours \(start) \(end)")
    }
}
