import Foundation

/// v0.14.8 W3 — v1.15.13 adoption: server-side source filter for the
/// measurement management lists (`GET /api/measurements?sourceEq=…`,
/// RESEARCH-SERVER-PARITY A2).
///
/// Before this, `MeasurementListScreen` filtered its loaded page CLIENT-side
/// (`MeasurementListFilter.apply`), which silently under-reports: the loaded
/// page is recency-capped, so rows of the selected source that fell off the
/// page never appear even though the server has them. `sourceEq` narrows the
/// page server-side (validated against `measurementSourceEnum`, backed by the
/// `(userId, source, measuredAt)` index — migration 0136), so the filtered
/// list is as deep as the unfiltered one.
///
/// Client-side filtering deliberately REMAINS for offline / standalone
/// snapshots (no server reachable) and as the defensive fallback on older
/// deploys — see the per-arm fallbacks below.
public extension MeasurementsRepository {
    /// Kind-scoped recent page narrowed to one ingest source, server-side.
    ///
    /// `source == nil` delegates to the canonical `recent(kind:limit:)` so
    /// callers can pass their optional filter state straight through.
    ///
    /// Routing mirrors `recent(kind:limit:)` arm-for-arm:
    /// - **standalone** → on-device union, filtered locally (no `/api/*`).
    /// - **cumulative / series-routed kinds** (steps, active energy, flights,
    ///   walking-distance, daylight) → the server's `groupBy=day` collapse
    ///   with `sourceEq`, because `/api/measurements/series` has no source
    ///   param. One summed row per user-tz day, scoped to the source.
    /// - **blood pressure** → the paired SYS+DIA type pages, each `sourceEq`-
    ///   scoped, merged (never "124/0").
    /// - **every other kind** → the plain kind-scoped page with `sourceEq`.
    func recent(
        kind: MetricKind,
        limit: Int = 400,
        source: MeasurementSource?
    ) async throws -> [Measurement] {
        guard let source else {
            return try await recent(kind: kind, limit: limit)
        }
        if standalone?.isActive == true {
            let union = try await standaloneRecentUnion(kind: kind, limit: limit)
            return union.filter { $0.source == source }
        }
        // Steps (`prefersSeriesForRecent`) stays on the series-synthesized
        // path + a local slice: its wire type (`ACTIVITY_STEPS`) is not in
        // `ServerMeasurementType`, so a `groupBy=day` list page would be
        // dropped row-by-row by the tolerant decoder. The series rows carry
        // a synthetic source anyway, so a server-side filter has nothing
        // extra to offer here.
        if kind.prefersSeriesForRecent {
            let rows = try await recent(kind: kind, limit: limit)
            return rows.filter { $0.source == source }
        }
        if kind.isCumulative, let typeKey = kind.availabilitySummaryKey {
            return try await recentKindScoped(
                typeKey: typeKey,
                kind: kind,
                limit: limit,
                groupByDay: true,
                sourceEq: source
            )
        }
        if kind == .bloodPressure {
            return try await recentBloodPressurePairScoped(limit: limit, sourceEq: source)
        }
        if let typeKey = kind.availabilitySummaryKey {
            return try await recentKindScoped(
                typeKey: typeKey,
                kind: kind,
                limit: limit,
                sourceEq: source
            )
        }
        // No server `MeasurementType` key (cannot happen today — every charted
        // kind is mapped): degrade to the global page + local filter.
        let all = try await recent(limit: limit)
        return all.filter { $0.kind == kind && $0.source == source }
    }
}
