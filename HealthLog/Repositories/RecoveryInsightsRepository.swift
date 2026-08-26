import Foundation

/// Builds the Insights **Recovery** family from `GET /api/analytics?slice=summaries`
/// — the SAME per-`MeasurementType` summaries map the web recovery page reads
/// (`src/components/insights/recovery/recovery-section.tsx`).
///
/// **Why not `/api/insights/recovery`?** v0141 W-DATAPARITY (P1): that route
/// never existed server-side (no `src/app/api/insights/recovery/`), so the old
/// call 404'd → `nil` → the recovery page rendered permanently empty even
/// though the operator has the data (DAY_STRAIN, ENERGY_EXPENDITURE_KJ, …). The
/// real source is the shared analytics summaries slice iOS already consumes for
/// pill availability (`MeasurementsRepository.availableKinds()`), so no server
/// deploy is needed for parity.
///
/// **Server-authoritative, no client recompute.** Each block's value is the
/// server-computed `latest` (or `mean`) reading for that type, rendered
/// verbatim; strain / load are never derived on-device.
///
/// **Per-block data-gate (web parity).** A block is included ONLY when its type
/// carries `count > 0` in the summaries slice AND has a renderable value — the
/// identical per-block gate the web uses (`summaries[TYPE].count > 0`).
/// Crucially the family does NOT require the absent `ANS_CHARGE` / `CARDIO_LOAD`
/// members: an operator with only `DAY_STRAIN` + `ENERGY_EXPENDITURE_KJ` (+ HR)
/// renders exactly those blocks. HONEST-ONLY — no fabricated rows.
///
/// **Cache strategy:** daily SWR under the Berlin-day-anchored
/// `.insightsRecovery(day:)` ladder — the built family is cached (cache-first on
/// disk, single-flighted revalidation), painting cache-first on launch and
/// flipping to a structural miss on day rollover.
///
/// **`nil` arm (graceful).** A `403` (analytics module gated off) / `404` / `422`
/// maps to `nil` so the recovery page shows its honest empty state; any other
/// transport error self-suppresses to `nil` too (SWR still serves a cached
/// payload first when one exists). An empty family (no present recovery type)
/// also returns `nil`.
public actor RecoveryInsightsRepository {
    private let api: APIClientProtocol
    private let swr: SWRCoordinator?

    public init(api: APIClientProtocol, swr: SWRCoordinator? = nil) {
        self.api = api
        self.swr = swr
    }

    /// Fetches + builds the recovery family, or `nil` when nothing is renderable
    /// (empty summaries) or the slice is gated / absent / errored.
    public func fetch() async -> RecoveryInsightsDTO? {
        let api = api
        @Sendable func networkFetch() async throws -> RecoveryInsightsDTO {
            let req: APIRequest<RecoverySummariesEnvelope> = .get(
                "/api/analytics",
                query: [("slice", "summaries")]
            )
            let envelope = try await api.send(req)
            return Self.buildFamily(from: envelope.summaries)
        }
        do {
            let family: RecoveryInsightsDTO = if let swr {
                try await swr.fetchCachingFirst(
                    .insightsRecovery(day: BerlinDayKey.string()),
                    decoding: RecoveryInsightsDTO.self,
                    fetch: networkFetch
                )
            } else {
                try await networkFetch()
            }
            return family.hasContent ? family : nil
        } catch let HLError.server(status, _, _) where status == 403 || status == 404 || status == 422 {
            // Analytics gated off / route absent / rejected → graceful empty.
            return nil
        } catch {
            // Transient transport error → self-suppress; SWR serves a cached
            // payload first when present, and the next refresh retries.
            return nil
        }
    }

    /// Drops the cached recovery payload (logout cache-wipe).
    public func invalidateCache() async {
        await swr?.invalidate([.insightsRecovery(day: BerlinDayKey.string())])
    }

    // MARK: - Family builder

    /// The recovery-family types, in web render order (`recovery-section.tsx`
    /// group order): recharge → strain & load → daily heart & energy. Each maps
    /// to its summaries key via `MetricKind.availabilitySummaryKey` and its
    /// unit / label via the shared `MetricKind` descriptor, so there is no
    /// second source of truth to drift.
    private static let familyOrder: [MetricKind] = [
        .ansCharge, .dayStrain, .workoutStrain, .cardioLoad, .cardioRecovery,
        .averageHeartRate, .maxHeartRate, .energyExpenditureKJ
    ]

    /// Pure: build the `RecoveryInsightsDTO` from the summaries map. A block is
    /// emitted only when its type has `count > 0` AND a renderable value
    /// (`latest ?? mean`). `nonisolated` + pure so the repository tests can pin
    /// the contract without the actor.
    nonisolated static func buildFamily(
        from summaries: [String: RecoverySummariesEnvelope.Stat]
    ) -> RecoveryInsightsDTO {
        var items: [RecoveryInsightsDTO.Item] = []
        for kind in familyOrder {
            guard let key = kind.availabilitySummaryKey,
                  let stat = summaries[key],
                  (stat.count ?? 0) > 0,
                  let value = stat.latest ?? stat.mean else { continue }
            let unit = kind.unit
            items.append(
                RecoveryInsightsDTO.Item(
                    id: key,
                    label: kind.displayName,
                    value: value,
                    unit: unit.isEmpty ? nil : unit
                )
            )
        }
        return RecoveryInsightsDTO(status: items.isEmpty ? "insufficient" : "ok", items: items)
    }
}

/// Decode-only mirror of the `/api/analytics?slice=summaries` payload the
/// recovery builder reads: the per-`MeasurementType` summaries map with the few
/// stat fields the family needs. The built ``RecoveryInsightsDTO`` (not this raw
/// envelope) is what round-trips the SWR cache.
public struct RecoverySummariesEnvelope: Decodable, Sendable {
    public let summaries: [String: Stat]

    public init(summaries: [String: Stat]) {
        self.summaries = summaries
    }

    /// One per-type summary from the slice. Tolerant of the slice's many other
    /// fields (Decodable ignores them); only `count` (the data-gate) and a
    /// representative value (`latest` / `mean`) are read.
    public struct Stat: Decodable, Sendable {
        public let count: Int?
        public let latest: Double?
        public let mean: Double?

        public init(count: Int?, latest: Double?, mean: Double?) {
            self.count = count
            self.latest = latest
            self.mean = mean
        }
    }
}
