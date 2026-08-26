import Foundation

// MARK: - v0.7.0 W-STEPS Layer 3 — cumulative-kind series routing

extension MeasurementsRepository {
    /// Series-backed `recent(kind:)` for cumulative kinds — see the routing
    /// note on `recent(kind:limit:)`. Translates the requested `limit` into a
    /// `days` window (≈ one day-row per row of the global page) and synthesizes
    /// `Measurement` rows from the returned `SeriesPoint`s.
    ///
    /// **Why a separate path:** `.steps` is stored server-side as one
    /// `stats:<id>:<day>` row per day, but a HK-power-user who walks all day
    /// produces dozens of per-sample step rows, so the global limit-400
    /// `/api/measurements` page could cover just a few weeks — the
    /// operator-reported "Schritte alle Daten zeigt nichts" symptom once the
    /// drill-down asks for a wide range. The `/api/measurements/series` route
    /// returns the dense per-day frame the server already aggregates.
    ///
    /// The synthesized rows carry a `.appleHealth` source attribution since the
    /// cumulative pipeline is HK-sourced; the series payload itself does not
    /// carry per-point provenance, so the SourcesChipStrip collapses to a
    /// single Apple-Health chip for these kinds (acceptable — steps are
    /// near-exclusively HK-sourced in practice).
    func recentCumulative(kind: MetricKind, limit: Int) async throws -> [Measurement] {
        let days = Self.seriesDays(forLimit: limit)
        let series = try await series(kind: kind, days: days)
        return series.points.map { point in
            let value: MeasurementValue = if let secondary = point.secondary {
                .bloodPressure(systolic: point.value, diastolic: secondary)
            } else {
                .scalar(point.value)
            }
            return Measurement(
                id: point.id,
                kind: kind,
                recordedAt: point.at,
                value: value,
                source: .appleHealth
            )
        }
    }

    /// Maps a `recent(kind:)` row-limit onto a `series(days:)` window for the
    /// cumulative routing path. A `limit >= 2000` (the `.all` chart range) asks
    /// for the widest history; everything smaller stays at the ~1y window the
    /// legacy limit-400 page covered. Clamped to a sane floor so a tiny limit
    /// still returns a usable frame.
    ///
    /// The returned value is the *requested* window — `series(kind:days:)`
    /// itself clamps to `MeasurementsRepository.serverDaysCap` (now 3650, the
    /// server v1.5.5 cap) before the wire call. With the cap raised the `.all`
    /// request (3650) carries the real all-time span instead of being trimmed
    /// to a year. See `serverDaysCap`.
    static func seriesDays(forLimit limit: Int) -> Int {
        if limit >= 2000 {
            return 3650
        }
        return max(365, limit)
    }
}
