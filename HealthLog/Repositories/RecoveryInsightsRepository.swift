import Foundation

/// Builds the Insights **Recovery** family from `GET /api/analytics?slice=summaries`,
/// the same per-`MeasurementType` summaries the web recovery page reads
/// (`src/components/insights/recovery/recovery-section.tsx`).
///
/// **Server-authoritative, no client recompute.** Each item carries the
/// server's `latest` and `avg30` unchanged; strain, load and energy are never
/// derived on-device. The empty reason is the server's `recoveryEmpty`.
///
/// **1.4 B3 — the 30-day gate.** A type is part of the family only when the
/// server reports an `avg30` for it, which it does exactly when the type has a
/// reading in the last 30 days. Older values (Alex's cardio recovery from
/// 2024) therefore never appear as if they were current. The same rule decides
/// the HRV measure: SDNN without a current reading and RMSSD with one means the
/// HRV page shows RMSSD.
///
/// **Cache strategy:** SWR under the Berlin-day-anchored `.insightsRecovery`
/// key (five-minute freshness, see `CacheKey`). Pull-to-refresh revalidates.
///
/// **Outcomes.** A built family (possibly empty, then carrying the server's
/// reason) on success; `nil` when the slice is gated or absent (`403`, `404`,
/// `422`), which the page shows as its calm empty state; a thrown error for a
/// transport failure with nothing cached, which the page shows as a retry face
/// instead of claiming there is no data.
public actor RecoveryInsightsRepository {
    private let api: APIClientProtocol
    private let swr: SWRCoordinator?

    public init(api: APIClientProtocol, swr: SWRCoordinator? = nil) {
        self.api = api
        self.swr = swr
    }

    /// Fetches and builds the recovery family. See the type doc for the three
    /// outcomes.
    public func fetch(forceRevalidate: Bool = false) async throws -> RecoveryInsightsDTO? {
        let api = api
        @Sendable func networkFetch() async throws -> RecoveryInsightsDTO {
            let req: APIRequest<RecoverySummariesEnvelope> = .get(
                "/api/analytics",
                query: [("slice", "summaries")]
            )
            let envelope = try await api.send(req)
            return Self.buildFamily(from: envelope.summaries, recoveryEmpty: envelope.recoveryEmpty)
        }
        do {
            if let swr {
                return try await swr.fetchCachingFirst(
                    .insightsRecovery(day: BerlinDayKey.string()),
                    decoding: RecoveryInsightsDTO.self,
                    forceRevalidate: forceRevalidate,
                    fetch: networkFetch
                )
            }
            return try await networkFetch()
        } catch let HLError.server(status, _, _) where status == 403 || status == 404 || status == 422 {
            // Analytics gated off / route absent / rejected → calm empty state.
            return nil
        }
    }

    /// Drops the cached recovery payload (logout cache-wipe).
    public func invalidateCache() async {
        await swr?.invalidate([.insightsRecovery(day: BerlinDayKey.string())])
    }

    // MARK: - Family builder

    /// The recovery-family types in page order: the recovery score first (the
    /// number Alex means by "Erholung"), then the web's own order of the
    /// device-native signals — recharge, strain and load, daily heart and
    /// energy (`recovery-section.tsx`). Cardio recovery is not a member: it
    /// has its own Insights page, like on the web.
    static let familyOrder: [MetricKind] = [
        .recoveryScore,
        .ansCharge, .dayStrain, .workoutStrain, .cardioLoad,
        .averageHeartRate, .maxHeartRate, .energyExpenditureKJ
    ]

    /// Pure: the family from the summaries map. A type is a member only when
    /// the server summarised a reading in the last 30 days (`avg30`) and has a
    /// `latest`; both values pass through unchanged. `recoveryEmpty` rides
    /// along as sent.
    nonisolated static func buildFamily(
        from summaries: [String: RecoverySummariesEnvelope.Stat],
        recoveryEmpty: String? = nil
    ) -> RecoveryInsightsDTO {
        let items = familyOrder.compactMap { kind -> RecoveryInsightsDTO.Item? in
            guard let key = kind.availabilitySummaryKey,
                  let stat = summaries[key],
                  let latest = stat.latest, latest.isFinite,
                  let average = stat.avg30, average.isFinite else { return nil }
            return RecoveryInsightsDTO.Item(id: key, latest: latest, average30: average)
        }
        return RecoveryInsightsDTO(
            items: items,
            emptyReason: recoveryEmpty,
            hrvShowsRMSSD: hrvShowsRMSSD(in: summaries)
        )
    }

    /// SDNN without a reading in the last 30 days, RMSSD with one. 1.4 B4:
    /// also an account that never had SDNN at all but has RMSSD, so the HRV
    /// page an RMSSD-only wearable opens (see `liveAvailableKinds`) never
    /// stands on an empty SDNN series.
    nonisolated static func hrvShowsRMSSD(in summaries: [String: RecoverySummariesEnvelope.Stat]) -> Bool {
        guard let sdnnKey = MetricKind.hrv.availabilitySummaryKey,
              let rmssdKey = MetricKind.hrvRMSSD.availabilitySummaryKey else { return false }
        let sdnn = summaries[sdnnKey]
        let rmssd = summaries[rmssdKey]
        guard sdnn?.avg30 == nil else { return false }
        if rmssd?.avg30 != nil { return true }
        return (sdnn?.count ?? 0) == 0 && (rmssd?.count ?? 0) > 0
    }
}

/// Decode-only mirror of the `/api/analytics?slice=summaries` payload the
/// recovery builder reads (`AnalyticsSummariesSlice` in the server's OpenAPI).
/// The built ``RecoveryInsightsDTO`` (not this raw envelope) is what
/// round-trips the SWR cache.
public struct RecoverySummariesEnvelope: Decodable, Sendable {
    public let summaries: [String: Stat]
    /// Why the recovery page has nothing to chart (server v1.43.7), `nil` when
    /// there is something to chart. A server older than v1.43.7 sends no field
    /// at all; that reads as ``unreportedReason``, the page's general note.
    public let recoveryEmpty: String?

    /// The reason assumed when the server does not report one.
    public static let unreportedReason = "general"

    public init(summaries: [String: Stat], recoveryEmpty: String? = nil) {
        self.summaries = summaries
        self.recoveryEmpty = recoveryEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case summaries, recoveryEmpty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summaries = try container.decode([String: Stat].self, forKey: .summaries)
        // `null` is the server saying "something to chart"; a value this build
        // cannot read is treated the same way rather than failing the slice.
        if container.contains(.recoveryEmpty) {
            recoveryEmpty = try? container.decodeIfPresent(String.self, forKey: .recoveryEmpty)
        } else {
            recoveryEmpty = Self.unreportedReason
        }
    }

    /// One per-type summary from the slice. Only the fields the family needs
    /// are read; the slice's many others are ignored.
    public struct Stat: Decodable, Sendable {
        public let count: Int?
        public let latest: Double?
        public let mean: Double?
        /// Mean over the last 30 days, `null` when the window has no reading.
        public let avg30: Double?

        public init(count: Int?, latest: Double?, mean: Double?, avg30: Double? = nil) {
            self.count = count
            self.latest = latest
            self.mean = mean
            self.avg30 = avg30
        }
    }
}
