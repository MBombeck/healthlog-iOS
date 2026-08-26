import Foundation

// v0.11 W2 — standalone read-union + offline writes for MeasurementsRepository.
//
// These helpers are reached ONLY when a `StandaloneGate` is wired AND the live
// runtime mode reads standalone (`isStandalone`). The paired/SWR path in the
// main file is the default and is byte-for-byte unchanged. No `/api/*` request
// fires from any method here — reads come from HealthKit-direct ∪ the local
// mirror, writes land in the local mirror.

extension MeasurementsRepository {
    /// Read-union: HealthKit-direct samples (weight / heart-rate / steps that W1
    /// covers) ∪ the local manual-entry mirror, merged + sorted newest-first and
    /// deduped by `externalId`. `kind == nil` means "every kind" (the dashboard
    /// fan-out's wide page).
    func standaloneRecentUnion(kind: MetricKind?, limit: Int) async throws -> [Measurement] {
        guard let standalone else { return [] }

        // 1) Local manual rows (the canonical home for hand-entered values).
        let localSnaps = try await standalone.local.standaloneMeasurements(
            kind: kind?.rawValue,
            limit: nil // dedupe/sort below; cap after merge
        )
        var merged: [Measurement] = localSnaps.map { $0.toDomainMeasurement() }
        var seenExternalIds = Set(merged.compactMap(\.externalUUID))

        // 2) HealthKit-direct rows for the adapter-supported kinds. The adapter
        // already skips samples we wrote ourselves (HKMetadataKeyExternalUUID),
        // so HK + mirror don't double-count our own writes.
        let hkKinds: [MetricKind] = kind.map { [$0] } ?? Self.standaloneHKKinds
        for hkKind in hkKinds {
            let hkMeasurements = await standaloneHealthKitMeasurements(
                kind: hkKind,
                days: Self.standaloneDays(forLimit: limit),
                limit: limit
            )
            for measurement in hkMeasurements where !seenExternalIds.contains(measurement.id) {
                merged.append(measurement)
                seenExternalIds.insert(measurement.id)
            }
        }

        let sorted = merged.sorted { $0.recordedAt > $1.recordedAt }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Standalone series for a single kind: HK-direct points (cumulative steps
    /// via daily buckets, discrete weight/HR samples) ∪ the mirror's manual rows,
    /// projected into `SeriesPoint`s, sorted oldest-first. Stats recomputed
    /// locally so the chart's mean/min/max line up with the rendered points.
    func standaloneSeries(kind: MetricKind, days: Int) async throws -> MeasurementSeries {
        guard let standalone else {
            return MeasurementSeries(kind: kind, points: [], stats: Self.emptyStats)
        }
        var points: [SeriesPoint] = []
        var seenIds = Set<String>()

        // Local manual rows for the kind, within the window.
        let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 86400)
        let localSnaps = try await standalone.local.standaloneMeasurements(kind: kind.rawValue, limit: nil)
        for snap in localSnaps where snap.recordedAt >= cutoff {
            let point = SeriesPoint(
                id: snap.externalId,
                at: snap.recordedAt,
                value: snap.systolic ?? snap.value,
                secondary: snap.diastolic
            )
            if seenIds.insert(point.id).inserted {
                points.append(point)
            }
        }

        // HK-direct points.
        let hkPoints: [SeriesPoint] = if kind.standaloneIsCumulative {
            await standalone.healthKit.standaloneDailySeries(kind: kind, days: days)
        } else {
            await standalone.healthKit.standaloneRecentSamples(kind: kind, days: days, limit: 1000)
        }
        for point in hkPoints where seenIds.insert(point.id).inserted {
            points.append(point)
        }

        points.sort { $0.at < $1.at }
        return MeasurementSeries(kind: kind, points: points, stats: Self.stats(from: points))
    }

    // MARK: - HK helpers

    /// HK-direct measurements for `kind`, projected into domain `Measurement`s
    /// with a deterministic synthetic id (so the dedup set is stable).
    private func standaloneHealthKitMeasurements(
        kind: MetricKind,
        days: Int,
        limit: Int
    ) async -> [Measurement] {
        guard let standalone else { return [] }
        let points: [SeriesPoint] = if kind.standaloneIsCumulative {
            await standalone.healthKit.standaloneDailySeries(kind: kind, days: days)
        } else {
            await standalone.healthKit.standaloneRecentSamples(kind: kind, days: days, limit: limit)
        }
        return points.map { point in
            Measurement(
                id: "hk-\(kind.rawValue)-\(point.id)",
                kind: kind,
                recordedAt: point.at,
                value: .scalar(point.value),
                note: nil,
                source: .appleHealth,
                externalUUID: nil
            )
        }
    }

    // MARK: - Constants / pure helpers

    /// The kinds the W1 `HealthKitReadAdapter` can read directly today. Other
    /// kinds are mirror-only in standalone until W2b widens the adapter.
    static var standaloneHKKinds: [MetricKind] {
        [.weight, .pulse, .steps]
    }

    /// Derive a day-window from a row limit so the HK reads cover roughly the
    /// same span the caller asked for. `limit >= 2000` (the `.all` callers) maps
    /// to the full ~10y history; the default 400 keeps ~1y.
    static func standaloneDays(forLimit limit: Int) -> Int {
        limit >= 2000 ? 3650 : 365
    }

    static var emptyStats: SeriesStats {
        SeriesStats(mean: 0, min: 0, max: 0, stdDev: 0, count: 0)
    }

    /// Recompute series stats locally from the union points (primary value).
    static func stats(from points: [SeriesPoint]) -> SeriesStats {
        let values = points.map(\.value)
        guard !values.isEmpty else { return emptyStats }
        let count = values.count
        let mean = values.reduce(0, +) / Double(count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count)
        return SeriesStats(
            mean: mean,
            min: values.min() ?? 0,
            max: values.max() ?? 0,
            stdDev: variance.squareRoot(),
            count: count
        )
    }
}

extension MetricKind {
    /// Standalone-local mirror of `isCumulative` (which is module-internal). Used
    /// to pick the HK read shape (daily-bucketed sum vs discrete samples).
    var standaloneIsCumulative: Bool {
        switch self {
        case .steps, .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight:
            true
        default:
            false
        }
    }
}
