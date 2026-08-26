import SwiftUI

// The two EMPTY-PAGE fallbacks for `MeasurementListScreen`, split out of the
// screen file under the PROJECT_GUIDE.md file-length discipline when Build 3 / item
// 3.3 added the date-range filter and Load-more paging. **Pure move** apart
// from the access level (`private` → module-internal, so a sibling file can
// host them).
//
// Only these two moved, deliberately: they take `container` as a PARAMETER and
// otherwise read nothing but `kind`, so they are the only loading helpers that
// do not touch the screen's file-private `@State`. Everything that does stays
// in the screen file, where `private` still reaches it.

extension MeasurementListScreen {
    /// v0.14.3 E5 / v0.14.4 D2 — synthesizes list rows when the default
    /// `recent(kind:)` page came back empty, so the drill-down list never shows
    /// "keine Daten" while the chart (and the all-time history) has data.
    ///
    /// Two honest paths, picked by whether the kind is series-backed:
    ///   • **series-backed** → derive rows from `/series` (mirrors the chart-detail
    ///     store's synthesis so the two surfaces never disagree).
    ///   • **non-series-backed** (BMI, Aktive Energie, flights, walking-distance,
    ///     the v1.10 IC kinds, …) → the series endpoint 422s these, so the E5
    ///     synthesis can't help. Instead retry a WIDE kind-scoped `recent(kind:)`
    ///     (`limit: 2000` → the server's ~10y history window): the default
    ///     `limit: 400` (~1y) page can miss older rows for a low-frequency or
    ///     long-dormant kind, which is exactly the operator's "tap reveals many
    ///     entries though the list said keine Daten". Generic across every
    ///     non-series kind — no per-kind hack.
    func seriesFallbackRows(container: AppContainer) async -> [Measurement] {
        guard ChartDetailStore.kindSupportsSeries(kind) else {
            return await wideRecentRows(container: container)
        }
        do {
            // Wide window so the drill-down's older buckets fill (matches the
            // chart's `.all`-range read; the server clamps internally).
            let series = try await container.measurementsRepo.series(kind: kind, days: 3650)
            guard !series.points.isEmpty else { return [] }
            return ChartDetailStore.measurementsFromSeriesPoints(series.points, kind: kind)
        } catch {
            HLLog.api.warning(
                "MeasurementList: series fallback failed for \(kind.rawValue, privacy: .public): \(LogSanitizer.redact(String(describing: error)))"
            )
            return []
        }
    }

    /// v0.14.4 D2 — the non-series fallback: a WIDE kind-scoped `recent(kind:)`
    /// read so a long-dormant or low-frequency kind surfaces its older rows
    /// instead of the empty state. `limit: 2000` opts the repo into the full
    /// ~10y history window (see `MeasurementsRepository.recent(kind:limit:)`).
    func wideRecentRows(container: AppContainer) async -> [Measurement] {
        // The repo logs its own kind-scoped fetch failures; a throw here just means
        // the honest empty state stands (same contract as the series-fallback arm).
        await (try? container.measurementsRepo.recent(kind: kind, limit: 2000)) ?? []
    }
}
