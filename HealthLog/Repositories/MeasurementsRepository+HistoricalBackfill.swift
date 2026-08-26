import Foundation

/// **W-HKBACKFILL** — full-history, source-scoped measurement fetch for the
/// one-shot Apple-Health historical backfill.
///
/// The b198 latest-page mirror only ever sees the newest SWR page
/// (`recent(limit: 400)`), so server-origin history that predates the app
/// install — or that is older than the current page — never reaches Apple
/// Health. This method pages the server's full per-kind history for ONE ingest
/// source so the backfill driver can hand each page to the existing mirror.
///
/// **Deliberately uncached.** Unlike `recentKindScoped` / `recent(kind:source:)`
/// this issues a direct, SWR-bypassing request: a one-shot ~10y page is far too
/// large to write into the SWR cache (it would evict the live list pages and
/// never be re-read), and the backfill runs exactly once per user. The wire
/// call + BP-pair merge are identical to the cached paths, so the rows decode
/// the same way. Standalone short-circuits to `[]` (no server history offline,
/// and the mirror is suppressed in standalone anyway).
public extension MeasurementsRepository {
    /// Server cap-saturating limit. `recentDirect`/`recentKindScoped` treat any
    /// `limit >= 2000` as "the full ~10y history" (see `serverDaysCap` /
    /// `cumulativeDaysFor`), so `5000` reliably saturates the window for the
    /// non-cumulative, list-scoped kinds the mirror writes.
    private static var backfillHistoryLimit: Int {
        5000
    }

    /// Full server history for `kind`, narrowed to one mirror-eligible `source`,
    /// uncached. Returns `[]` in standalone mode. BP is fetched as the paired
    /// SYS+DIA pages and merged (never "124/0"); every other mirror-writable
    /// kind uses the plain `?type=…&sourceEq=…` page.
    func historyForBackfill(
        kind: MetricKind,
        source: MeasurementSource
    ) async throws -> [Measurement] {
        if standalone?.isActive == true { return [] }
        let limit = Self.backfillHistoryLimit
        if kind == .bloodPressure {
            return try await fetchBloodPressureHistoryUncached(limit: limit, source: source)
        }
        guard let typeKey = kind.availabilitySummaryKey else {
            // No server `MeasurementType` key — cannot happen for a
            // mirror-writable kind today, but degrade to empty rather than
            // pulling the whole global page just to filter one kind out.
            return []
        }
        return try await fetchKindHistoryUncached(typeKey: typeKey, kind: kind, limit: limit, source: source)
    }

    private func fetchKindHistoryUncached(
        typeKey: String,
        kind: MetricKind,
        limit: Int,
        source: MeasurementSource
    ) async throws -> [Measurement] {
        let req: APIRequest<MeasurementListWireResponse> = .get(
            "/api/measurements",
            query: [
                ("limit", String(limit)),
                ("type", typeKey),
                ("sourceEq", source.wire.rawValue)
            ]
        )
        let response = try await api.send(req)
        let merged = MeasurementAggregator.mergeBloodPressure(response.measurements)
        // Defensive client-side narrow: an older deploy that ignores `sourceEq`
        // / `type` must not feed foreign rows into the mirror (the mirror's own
        // source policy would still drop them, but keep the fetch honest).
        return merged.filter { $0.kind == kind && $0.source == source }
    }

    private func fetchBloodPressureHistoryUncached(
        limit: Int,
        source: MeasurementSource
    ) async throws -> [Measurement] {
        func page(_ typeKey: String) async throws -> MeasurementListWireResponse {
            let req: APIRequest<MeasurementListWireResponse> = .get(
                "/api/measurements",
                query: [
                    ("limit", String(limit)),
                    ("type", typeKey),
                    ("sourceEq", source.wire.rawValue)
                ]
            )
            return try await api.send(req)
        }
        async let sys = page("BLOOD_PRESSURE_SYS")
        async let dia = page("BLOOD_PRESSURE_DIA")
        let wires = try await sys.measurements + dia.measurements
        let merged = MeasurementAggregator.mergeBloodPressure(wires)
        return merged.filter { $0.kind == .bloodPressure && $0.source == source }
    }
}
