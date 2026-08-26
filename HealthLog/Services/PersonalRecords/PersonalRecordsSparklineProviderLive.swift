import Foundation

/// v0.5.5.6 POLISH-PR — live `PersonalRecordsSparklineProvider`.
///
/// Pulls a 30-day trajectory leading to the record-day from the
/// `MeasurementsRepository.series(kind:days:)` SWR cache. The provider
/// is intentionally thin — the heavy lifting (network, dedup, caching)
/// lives in the repository; this actor only slices the series window
/// against the record-day and finds the peak index used by the
/// `RecordCard` overlay marker.
///
/// **Why a 30-day window:** the sparkline is a glanceable trajectory
/// indicator, not a chart. 30 days fits ~30 sample points horizontally
/// in a 160pt card without crowding, and it covers a meaningful
/// "leading-up-to-the-record" arc for both cumulative kinds (steps)
/// and snapshot kinds (weight, HRV).
///
/// **Peak index:** for cumulative kinds the record-day is typically
/// the chronological peak inside the window — we still scan to find
/// the actual max because record-class rows (e.g. "Longest Streak")
/// can report a `value` that doesn't align with the daily-totals peak.
public actor PersonalRecordsSparklineProviderLive: PersonalRecordsSparklineProvider {
    private let measurementsRepo: MeasurementsRepository
    private let windowDays: Int

    public init(
        measurementsRepo: MeasurementsRepository,
        windowDays: Int = 30
    ) {
        self.measurementsRepo = measurementsRepo
        self.windowDays = windowDays
    }

    public func sparkline(
        for kind: MetricKind,
        endingAt recordDay: Date
    ) async -> PersonalRecordsSparklineSnapshot {
        let series: MeasurementSeries
        do {
            // Pull a slightly wider window than the slice we'll keep so
            // a record near the cache boundary still has context to its
            // left. 90 days is the smallest "definitely enough" window.
            series = try await measurementsRepo.series(kind: kind, days: max(windowDays, 90))
        } catch {
            HLLog.api.warning(
                "PersonalRecordsSparklineProviderLive: series fetch for \(kind.rawValue, privacy: .private) failed — \(String(describing: error), privacy: .private)"
            )
            return .empty
        }
        return Self.slice(
            series: series,
            endingAt: recordDay,
            windowDays: windowDays
        )
    }

    /// Pure helper — testable without the actor surrounding. Returns
    /// the trailing `windowDays`-sized window of `series.points` ending
    /// at `recordDay`, plus the index of the peak inside that window.
    nonisolated static func slice(
        series: MeasurementSeries,
        endingAt recordDay: Date,
        windowDays: Int
    ) -> PersonalRecordsSparklineSnapshot {
        let cutoffEnd = recordDay
        guard let cutoffStart = Calendar.current.date(
            byAdding: .day, value: -windowDays, to: cutoffEnd
        ) else { return .empty }
        let inWindow = series.points
            .filter { $0.at >= cutoffStart && $0.at <= cutoffEnd }
            .sorted { $0.at < $1.at }
        guard !inWindow.isEmpty else { return .empty }
        let values = inWindow.map(\.value)
        let peakIndex = values.enumerated().max(by: { $0.element < $1.element })?.offset
        return PersonalRecordsSparklineSnapshot(values: values, peakIndex: peakIndex)
    }
}
