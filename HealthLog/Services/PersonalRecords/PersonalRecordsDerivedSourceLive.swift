import Foundation

/// Live implementation of `PersonalRecordsDerivedSource`. Pulls the
/// cumulative-kind series the server already supports
/// (`/api/measurements/series?kind=steps&days=365`) and hands the points
/// to `StreakComputer.derive(...)`.
///
/// **Year-window:** 365 days. PRs are inherently long-tail —
/// "Bester Tag" needs at least a couple-of-months window to mean
/// anything. The series endpoint caches via SWR (5-min TTL), so the
/// repeated call cost is one cache-hit after the first paint.
///
/// **Logout cleanup:** the source itself holds no per-user state. The
/// repository cache lives in `MeasurementsRepository` and is invalidated
/// via the existing `SWRCoordinator.invalidateAll()` logout hook.
public actor PersonalRecordsDerivedSourceLive: PersonalRecordsDerivedSource {
    private let measurementsRepo: MeasurementsRepository
    private let windowDays: Int
    private let clock: @Sendable () -> Date

    public init(
        measurementsRepo: MeasurementsRepository,
        windowDays: Int = 365,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.measurementsRepo = measurementsRepo
        self.windowDays = windowDays
        self.clock = clock
    }

    public func derivedRecords(
        metricTypeFilter: String?,
        excluding serverMetricTypes: Set<String>
    ) async -> [PersonalRecordDTO] {
        var out: [PersonalRecordDTO] = []
        for (kind, config) in StreakComputer.canonicalConfigs {
            // Server-shipped record for this metric-type wins — skip the
            // derivation entirely to keep the bucket single-source.
            if serverMetricTypes.contains(config.metricType) {
                continue
            }
            // Per-metric narrow narrows on the canonical metric-type.
            if let filter = metricTypeFilter, filter != config.metricType {
                continue
            }
            let derived = await derive(for: kind)
            out.append(contentsOf: derived)
        }
        return out
    }

    private func derive(for kind: MetricKind) async -> [PersonalRecordDTO] {
        let series: MeasurementSeries
        do {
            series = try await measurementsRepo.series(kind: kind, days: windowDays)
        } catch {
            HLLog.api.warning(
                "PersonalRecordsDerivedSourceLive series fetch for \(kind.rawValue, privacy: .private) failed: \(String(describing: error), privacy: .private)"
            )
            return []
        }
        return StreakComputer.derive(
            points: series.points,
            kind: kind,
            userId: "local",
            now: clock()
        )
    }
}
