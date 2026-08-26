import Foundation
import Observation

/// **W-VORSORGE-DETAIL (b244) — the data model behind the Vorsorge reminder
/// detail sheet.**
///
/// Loads the honest chart substance for one preventive-care reminder, branching
/// on ``VorsorgeCard/detailArm(for:)``:
///
/// - **metric** — the linked metric's reading history via
///   `MeasurementsRepository.recent(kind:limit:)` (the SAME SWR-cached seam the
///   7-day strip uses, just a wider window). Auto Y-axis.
/// - **screening** — the mental-wellbeing severity-band history via
///   `MentalHealthStore.loadDetail(_:)`, fixed `0…maxScore` Y-domain (identical
///   to the mental-health card the operator already loves).
/// - **free-text** — no series; the sheet shows an honest Next/Last, no chart.
///
/// Errors are best-effort like the strip (`VorsorgeTrendStripView`): the chart
/// simply falls away rather than raising an alarm banner on a secondary surface.
/// Points obey the SAME "one dot is no trend" rule as ``VorsorgeCard/chartPoints(from:)``.
@MainActor
@Observable
final class VorsorgeDetailModel {
    let row: MeasurementReminderRow

    private let measurementsRepo: MeasurementsRepository
    private let mentalHealthStore: MentalHealthStore

    /// Oldest → newest chart points for the current arm; empty when there is no
    /// chartable series (free-text, a read error, or fewer than two points).
    private(set) var points: [HistoryLineChart.Point] = []
    /// Fixed Y-domain (screening `0…maxScore`) or `nil` for an auto axis (metric).
    private(set) var yDomain: ClosedRange<Double>?
    private(set) var isLoading = false

    /// Metric arm only — the raw readings (newest-first) behind the chart, so the
    /// sheet renders honest "date · value" rows (BP as sys/dia, not just the
    /// plotted systolic). Empty on the screening / free-text arms.
    private(set) var metricMeasurements: [Measurement] = []

    /// Screening arm only — the raw severity-band history, retained for the band
    /// annotation + history rows the screening sheet renders (Commit 7). Empty on
    /// the metric / free-text arms.
    private(set) var screeningRows: [MentalHealthAssessmentDTO] = []

    /// The resolved arm for this reminder (screening → metric → free-text).
    var arm: VorsorgeCard.DetailArm {
        VorsorgeCard.detailArm(for: row)
    }

    init(
        row: MeasurementReminderRow,
        measurementsRepo: MeasurementsRepository,
        mentalHealthStore: MentalHealthStore
    ) {
        self.row = row
        self.measurementsRepo = measurementsRepo
        self.mentalHealthStore = mentalHealthStore
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        switch arm {
        case let .metric(kind):
            await loadMetric(kind)
        case let .screening(instrument):
            await loadScreening(instrument)
        case .freeText:
            points = []
            yDomain = nil
        }
    }

    // MARK: - Arms

    private func loadMetric(_ kind: MetricKind) async {
        // Best-effort: a failed read just leaves the chart absent (the sheet keeps
        // its Next/Last + action), never an alarm banner on a secondary surface.
        let recent = await (try? measurementsRepo.recent(kind: kind, limit: 60)) ?? []
        metricMeasurements = recent
        if let tuples = VorsorgeCard.chartPoints(from: recent) {
            points = tuples.map { HistoryLineChart.Point(id: $0.id, date: $0.date, value: $0.value) }
        } else {
            points = []
        }
        yDomain = nil // metric: auto axis over the value's own range
    }

    private func loadScreening(_ instrument: MentalHealthInstrument) async {
        await mentalHealthStore.loadDetail(instrument)
        let rows = mentalHealthStore.detailHistory
        screeningRows = rows
        let mapped = rows.compactMap { row -> HistoryLineChart.Point? in
            guard let date = MentalHealthDateFormat.date(row.takenAt) else { return nil }
            return HistoryLineChart.Point(id: row.id, date: date, value: Double(row.totalScore))
        }
        // Same "one dot is no trend" rule as the metric arm.
        points = HistoryLineChart.ordered(mapped).count >= 2 ? HistoryLineChart.ordered(mapped) : []
        yDomain = 0 ... Double(instrument.maxScore)
    }
}
