import Foundation

/// v0.14.10 BP-PAIR FIX (W-INSIGHTSDATA Bug 1) — the paired kind-scoped recent
/// page for `.bloodPressure`.
///
/// Blood pressure is TWO wire rows (SYS + DIA) merged on exact `measuredAt` by
/// `MeasurementAggregator.mergeBloodPressure`. The generic kind-scoped routing
/// (v0.14 DATA, commit `f5204b4f`) queried `?type=BLOOD_PRESSURE_SYS` (BP's
/// `availabilitySummaryKey`), so the page carried ONLY systolic rows and every
/// merged Measurement came back `.bloodPressure(systolic: s, diastolic: 0)` —
/// the operator-reported "Letzte Messung 124/0" on the Insights BP page and
/// the drill-down rows. (The chart stayed correct because it reads
/// `/api/measurements/series?kind=bloodPressure`, which carries both
/// components.)
extension MeasurementsRepository {
    /// Pulls the `BLOOD_PRESSURE_SYS` **and** `BLOOD_PRESSURE_DIA` type pages
    /// concurrently and merges them, so every row carries BOTH components
    /// ("124/82", never "124/0"). SWR-cached under the synthetic
    /// `BLOOD_PRESSURE_PAIR` type key (a NEW key, deliberately — any stale
    /// sys-only page cached under `BLOOD_PRESSURE_SYS` by the broken routing
    /// must not be served back). A failure on either page falls back to the
    /// global recent page (which always carried complete pairs), so BP can
    /// never regress to worse than pre-v0.14-DATA behaviour.
    /// v0.14.8 W3 (v1.15.13 adoption) — `sourceEq` narrows BOTH type pages to
    /// one ingest source server-side (management-list filter); the cache key
    /// carries a `:src:` suffix so filtered pages never collide.
    func recentBloodPressurePairScoped(
        limit: Int,
        sourceEq: MeasurementSource? = nil
    ) async throws -> [Measurement] {
        let fetch: @Sendable () async throws -> [Measurement] = { [api] in
            func page(_ typeKey: String) async throws -> MeasurementListWireResponse {
                var query: [(String, String)] = [("limit", String(limit)), ("type", typeKey)]
                if let sourceEq { query.append(("sourceEq", sourceEq.wire.rawValue)) }
                let req: APIRequest<MeasurementListWireResponse> = .get(
                    "/api/measurements",
                    query: query
                )
                return try await api.send(req)
            }
            async let sys = page("BLOOD_PRESSURE_SYS")
            async let dia = page("BLOOD_PRESSURE_DIA")
            let wires = try await sys.measurements + dia.measurements
            return MeasurementAggregator.mergeBloodPressure(wires)
        }
        var cacheType = "BLOOD_PRESSURE_PAIR"
        if let sourceEq { cacheType += ":src:\(sourceEq.wire.rawValue)" }
        let rows: [Measurement]
        do {
            if let swr {
                rows = try await swr.fetchCachingFirst(
                    .measurementsRecentKind(type: cacheType, limit: limit),
                    decoding: [Measurement].self,
                    fetch: fetch
                )
            } else {
                rows = try await fetch()
            }
        } catch {
            // Defensive: a server that doesn't honour `type=` (older deploy)
            // must not blank the page — fall back to the global page, whose
            // wire rows always include both BP halves.
            let all = try await recent(limit: limit)
            return all.filter { $0.kind == .bloodPressure && (sourceEq == nil || $0.source == sourceEq) }
        }
        return rows.filter { $0.kind == .bloodPressure }
    }
}
