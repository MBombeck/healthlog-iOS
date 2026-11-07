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

    // MARK: - MIRROR (1.5, #152, server #1272) — the server's own answer

    /// Rows per page of the v3 history walk, and the most pages one kind may
    /// take (200 000 rows), so a server that ignored `offset` cannot loop.
    private static var mirrorHistoryPageSize: Int {
        1000
    }

    private static var mirrorHistoryMaxPages: Int {
        200
    }

    /// The full history of `kind` that the server marks for Apple Health
    /// (`appleHealthMirror=true`, server 1.46.0 or later), paged with `offset`,
    /// uncached like the per-source walk. BP pages both halves and merges them.
    ///
    /// Only for a server known to be 1.46.0 or later: an older one ignores the
    /// filter and returns every source of the type, Apple Health rows included.
    /// The caller still runs every row through the mirror's own decision, so
    /// even then nothing from Apple Health is written back.
    func historyForMirrorBackfill(kind: MetricKind) async throws -> [Measurement] {
        if standalone?.isActive == true { return [] }
        let typeKeys: [String]
        if kind == .bloodPressure {
            typeKeys = ["BLOOD_PRESSURE_SYS", "BLOOD_PRESSURE_DIA"]
        } else if let key = kind.availabilitySummaryKey {
            typeKeys = [key]
        } else {
            return []
        }
        var wires: [MeasurementWireDTO] = []
        for typeKey in typeKeys {
            wires += try await mirrorHistoryPages(typeKey: typeKey)
        }
        return MeasurementAggregator.mergeBloodPressure(wires).filter { $0.kind == kind }
    }

    private func mirrorHistoryPages(typeKey: String) async throws -> [MeasurementWireDTO] {
        let pageSize = Self.mirrorHistoryPageSize
        var rows: [MeasurementWireDTO] = []
        var offset = 0
        for _ in 0 ..< Self.mirrorHistoryMaxPages {
            try Task.checkCancellation()
            let request: APIRequest<MeasurementListWireResponse> = .get(
                "/api/measurements",
                query: [
                    ("appleHealthMirror", "true"),
                    ("type", typeKey),
                    ("limit", String(pageSize)),
                    ("offset", String(offset))
                ]
            )
            let page = try await api.send(request)
            rows += page.measurements
            // The server's page size, not the decoded count: a row the tolerant
            // decoder dropped still took a slot.
            let served = page.meta?.limit ?? page.measurements.count
            offset += max(1, served)
            if page.measurements.isEmpty { break }
            if let total = page.meta?.total, offset >= total { break }
            if page.meta?.total == nil, page.measurements.count < pageSize { break }
        }
        return rows
    }

    /// **MIRROR (1.5, public #28)** — the one request of the background mirror:
    /// the rows the server marks for Apple Health, measured since `since`,
    /// newest first, at most `limit`. Uncached; `[]` in standalone.
    ///
    /// A blood-pressure half whose partner fell outside the page is dropped
    /// rather than written as a reading with a zero half; a later window, or
    /// the measurement list, sees the pair whole.
    func rowsForServerMirror(since: Date, limit: Int) async throws -> [Measurement] {
        if standalone?.isActive == true { return [] }
        let request: APIRequest<MeasurementListWireResponse> = .get(
            "/api/measurements",
            query: [
                ("appleHealthMirror", "true"),
                ("from", ISO8601DateFormatter.plain.string(from: since)),
                ("limit", String(limit))
            ]
        )
        let response = try await api.send(request)
        return MeasurementAggregator.mergeBloodPressure(response.measurements).filter { measurement in
            guard measurement.kind == .bloodPressure else { return true }
            return measurement.bloodPressureDiastolicId != nil
        }
    }
}
