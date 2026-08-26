import Foundation
import Observation

/// `@Observable` wrapper over `PersonalRecordsRepository`. Surfaces the
/// per-user PR list to the chart-detail PR strip + the redesigned
/// `PersonalRecordsScreen` (v0.5.5.6 POLISH-PR).
///
/// **Production state (2026-05-17):** the server route is schema-only;
/// the detection worker that populates rows lands in v1.4.26 / v1.5.
/// `records` returns `[]` for every user today. **v0.5.4-BF7:** until
/// the server worker lights up the list, the store derives a small set
/// of cumulative-kind records (Schritte: best day + longest 10k-streak)
/// from the cached `/api/measurements/series` data so the surface shows
/// something useful instead of the empty state.
///
/// **Merge semantics:** server-shipped records always win their
/// `metricType` bucket. Derived records only surface when no server row
/// for the same `metricType` exists in the response — that way the
/// moment the server worker ships, the same screen lights up with the
/// authoritative rows and the derived rows fall back automatically.
///
/// **v0.5.5.6 POLISH-PR:** the store now also publishes a parallel
/// `enrichedRecords` list (`PersonalRecord` view model) and a
/// `selectedBucket` toggle so the new screen can render the hero, the
/// 2-col grid, the streak rail and the milestones strip without
/// re-deriving the metric-kind / sparkline / bucket per render.
@MainActor
@Observable
public final class PersonalRecordsStore {
    public private(set) var records: [PersonalRecordDTO] = []
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?
    public private(set) var currentMetricType: String?

    /// v0.5.5.6 POLISH-PR — enriched UI-facing records (sparkline +
    /// bucket + delta + impressiveness). Populated alongside `records`
    /// by `load(...)`; the redesigned `PersonalRecordsScreen` reads
    /// this list, the legacy chart-detail PR badge keeps reading the
    /// raw `records` list to preserve v0.5.3 wire contract.
    public private(set) var enrichedRecords: [PersonalRecord] = []

    /// The selected time bucket on the Records screen. Driven by the
    /// segmented picker. v0.14.1 (#139) — defaults to `.week` ("Diese Woche")
    /// so the screen opens on the most-recent, most-relevant window (the
    /// operator's "what did I just achieve" view) instead of the unfiltered
    /// all-time list. Reset to the same default on logout.
    public var selectedBucket: TimeBucket = .week

    private let repo: PersonalRecordsRepository
    /// v0.5.4-BF7 — client-side derivation source. Optional so the
    /// existing test composition (`PersonalRecordsStore(repo:)`) keeps
    /// compiling without a second dependency, and so the
    /// `clearOnLogout`-pathway stays simple. When `nil` the store
    /// behaves exactly like v0.5.3 (server-only).
    private let derivedSource: PersonalRecordsDerivedSource?
    /// v0.5.5.6 POLISH-PR — sparkline-trajectory provider. Optional so
    /// the existing test composition keeps compiling; the redesigned
    /// screen wires the live `PersonalRecordsSparklineProviderLive`
    /// at the composition root. When `nil` the enriched records carry
    /// empty `sparklineValues`.
    private let sparklineProvider: PersonalRecordsSparklineProvider?
    private let clock: @MainActor () -> Date

    /// A2-M4 — appear-revalidation freshness gate (60s TTL).
    @ObservationIgnored private var revalidationGate = RevalidationGate(ttl: 60)

    public init(
        repo: PersonalRecordsRepository,
        derivedSource: PersonalRecordsDerivedSource? = nil,
        sparklineProvider: PersonalRecordsSparklineProvider? = nil,
        clock: @escaping @MainActor () -> Date = Date.init
    ) {
        self.repo = repo
        self.derivedSource = derivedSource
        self.sparklineProvider = sparklineProvider
        self.clock = clock
    }

    /// Loads PRs. `metricType` narrows server-side (e.g. `"VO2_MAX"`).
    public func load(metricType: String? = nil, limit: Int = 100) async {
        currentMetricType = metricType
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let serverRecords = try await repo.list(metricType: metricType, limit: limit)
            let derived = await derivedRecords(filteredBy: metricType, serverRecords: serverRecords)
            records = Self.merge(serverRecords: serverRecords, derived: derived)
            await enrich()
            revalidationGate.markLoaded()
        } catch let err as HLError {
            error = err
            // Even when the server call fails (offline / 401 retry), still
            // surface derived records — they are computed from local cache
            // and give the user a non-empty screen.
            let derived = await derivedRecords(filteredBy: metricType, serverRecords: [])
            if !derived.isEmpty {
                records = derived
                error = nil
                await enrich()
            }
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func refresh() async {
        await load(metricType: currentMetricType)
    }

    /// A2-M4 — appear-revalidation entry point: reload when empty (cold) OR
    /// stale (partial-then-stale), no-op inside the freshness window. Preserves
    /// the current `metricType` filter.
    public func revalidateIfStale() async {
        if records.isEmpty || revalidationGate.isStale() {
            await load(metricType: currentMetricType)
        }
    }

    /// True when the user has at least one PR. UI uses this to gate
    /// the "Persönliche Rekorde" surface visibility.
    public var hasRecords: Bool {
        !records.isEmpty
    }

    public func clearOnLogout() {
        records = []
        enrichedRecords = []
        error = nil
        currentMetricType = nil
        selectedBucket = .week // v0.14.1 (#139) — match the new default
    }

    /// v0.5.5.6 POLISH-PR — hero pick. Returns the most impressive
    /// enriched record according to `impressivenessScore`. `nil` when
    /// the user has no records (the screen renders the empty-state).
    public var heroRecord: PersonalRecord? {
        enrichedRecords.max { $0.impressiveness < $1.impressiveness }
    }

    /// Enriched records filtered to the currently-selected bucket.
    /// Drives the grid below the hero. Order matches `records`.
    public var visibleRecords: [PersonalRecord] {
        enrichedRecords.filter { selectedBucket.includes($0.bucket) }
    }

    /// Streak-class records surfaced by `StreakComputer` (derived rows
    /// with `metricSlot` containing "Serie" / "streak"). The Streak rail
    /// hoists them out of the main grid so the visual rhythm reads as
    /// "Records · Streaks · Milestones" rather than mixing all three.
    public var streakRecords: [PersonalRecord] {
        enrichedRecords.filter { record in
            let slot = (record.base.metricSlot ?? "").lowercased()
            return slot.contains("serie") || slot.contains("streak")
        }
    }

    // MARK: - Enrichment

    /// v0.5.5.6 POLISH-PR — build the enriched view-model list from the
    /// raw `records`, fetching a 30-day sparkline trajectory per record
    /// from `sparklineProvider` when one is wired. The fetch fans out
    /// in parallel so the screen paints quickly even with many records
    /// (each provider call is SWR-cached at the repository layer).
    func enrich() async {
        let now = clock()
        let rawRecords = records
        guard !rawRecords.isEmpty else {
            enrichedRecords = []
            return
        }
        // Pre-classify previous values per metric-type bucket so each
        // enriched row's `previousValue` lines up against the runner-up.
        let runnersUpByType: [String: Double] = Self.previousValuesByType(records: rawRecords)
        let provider = sparklineProvider

        let enriched: [PersonalRecord] = await withTaskGroup(
            of: PersonalRecord.self
        ) { group in
            for record in rawRecords {
                let runnerUp = runnersUpByType[record.metricType]
                let providerSnapshot = provider
                let nowSnapshot = now
                group.addTask {
                    await Self.enrich(
                        record: record,
                        previousValue: runnerUp,
                        provider: providerSnapshot,
                        now: nowSnapshot
                    )
                }
            }
            var out: [PersonalRecord] = []
            for await item in group {
                out.append(item)
            }
            return out
        }
        // Preserve the input order so the screen sections (which iterate
        // `records`) stay 1:1 with the enriched indices.
        let orderMap = Dictionary(uniqueKeysWithValues: rawRecords.enumerated().map { ($1.id, $0) })
        enrichedRecords = enriched.sorted { lhs, rhs in
            (orderMap[lhs.id] ?? Int.max) < (orderMap[rhs.id] ?? Int.max)
        }
    }

    // MARK: - Derived merging

    /// Asks the derived-source for client-computed rows. Skips kinds
    /// already represented in the server response so a future
    /// server-shipped Schritte record wins over the client derivation.
    private func derivedRecords(
        filteredBy metricType: String?,
        serverRecords: [PersonalRecordDTO]
    ) async -> [PersonalRecordDTO] {
        guard let derivedSource else { return [] }
        let serverTypes = Set(serverRecords.map(\.metricType))
        return await derivedSource.derivedRecords(
            metricTypeFilter: metricType,
            excluding: serverTypes
        )
    }

    /// Merge server + derived rows. Server records keep their position;
    /// derived rows append after server rows for the same metric-type
    /// bucket. The screen groups by `metricType` so insertion order
    /// inside the bucket is the only thing that matters here.
    nonisolated static func merge(
        serverRecords: [PersonalRecordDTO],
        derived: [PersonalRecordDTO]
    ) -> [PersonalRecordDTO] {
        serverRecords + derived
    }

    // MARK: - Pure helpers (POLISH-PR)

    /// Pure helper — for each metric-type bucket, the runner-up `value`
    /// becomes the `previousValue` of the bucket's top record. When a
    /// bucket has a single record, the runner-up entry is omitted from
    /// the dictionary so `enrich(...)` flips the chip to "Neuer Rekord!".
    nonisolated static func previousValuesByType(
        records: [PersonalRecordDTO]
    ) -> [String: Double] {
        let grouped = Dictionary(grouping: records, by: \.metricType)
        var out: [String: Double] = [:]
        for (type, list) in grouped {
            let sorted = list.sorted { $0.achievedAt > $1.achievedAt }
            // The "previous" record is the second-most-recent entry.
            if sorted.count >= 2 {
                out[type] = sorted[1].value
            }
        }
        return out
    }

    nonisolated static func enrich(
        record: PersonalRecordDTO,
        previousValue: Double?,
        provider: PersonalRecordsSparklineProvider?,
        now: Date,
        calendar: Calendar = .current
    ) async -> PersonalRecord {
        let kind = MetricTypeKindResolver.kind(forMetricType: record.metricType)
        let bucket = TimeBucket.classify(achievedAt: record.achievedAt, now: now, calendar: calendar)
        let sparklineSnapshot: PersonalRecordsSparklineSnapshot = if let provider, let kind {
            await provider.sparkline(for: kind, endingAt: record.achievedAt)
        } else {
            .empty
        }
        let impressiveness = impressivenessScore(
            record: record,
            bucket: bucket,
            now: now
        )
        return PersonalRecord(
            id: record.id,
            base: record,
            kind: kind,
            sparklineValues: sparklineSnapshot.values,
            peakIndex: sparklineSnapshot.peakIndex,
            previousValue: previousValue,
            bucket: bucket,
            impressiveness: impressiveness
        )
    }

    /// Deterministic 0-1 hero-ranking score. Strategy:
    ///   • A record set in the current week scores higher than a stale
    ///     all-time max (fresh felt impact > historic dominance).
    ///   • Within a bucket, recency matters secondarily so two
    ///     same-bucket records still order deterministically.
    /// Pure, no I/O, fully determined by `record + bucket + now` so
    /// snapshot tests can pin the hero pick.
    nonisolated static func impressivenessScore(
        record: PersonalRecordDTO,
        bucket: TimeBucket,
        now: Date
    ) -> Double {
        let bucketWeight = switch bucket {
        case .week: 0.85
        case .month: 0.70
        case .year: 0.55
        case .allTime: 0.40
        }
        // Sub-bucket nudges so two same-bucket records still order
        // deterministically: more recent record wins inside the bucket.
        let secondsSince = now.timeIntervalSince(record.achievedAt)
        let recencyNudge = max(0.0, 0.15 - min(secondsSince / 86400 / 365, 0.15))
        return min(1.0, bucketWeight + recencyNudge)
    }
}

// MARK: - Derived source seam

/// Pluggable seam for client-computed personal records. The default
/// implementation lives in `PersonalRecordsDerivedSourceLive`
/// (composition root); tests substitute an in-memory fake.
public protocol PersonalRecordsDerivedSource: Sendable {
    func derivedRecords(
        metricTypeFilter: String?,
        excluding serverMetricTypes: Set<String>
    ) async -> [PersonalRecordDTO]
}

// MARK: - Sparkline-provider seam (v0.5.5.6 POLISH-PR)

/// 30-day trajectory snapshot for the `RecordCard` mini-sparkline.
///
/// `values` is in chronological order ending at the record day.
/// `peakIndex` points at the record-day inside `values` (typically the
/// last index for cumulative kinds, but can be earlier for record-class
/// rows that look back at the all-time max). When the provider has no
/// series data (offline, no series-endpoint support for the kind), the
/// snapshot is `.empty` and the card omits the sparkline.
public struct PersonalRecordsSparklineSnapshot: Sendable, Equatable {
    public let values: [Double]
    public let peakIndex: Int?

    public init(values: [Double], peakIndex: Int?) {
        self.values = values
        self.peakIndex = peakIndex
    }

    public static let empty = PersonalRecordsSparklineSnapshot(values: [], peakIndex: nil)
}

/// Pluggable seam for the trajectory provider. Live impl wraps
/// `MeasurementsRepository.series(kind:days:)`; tests substitute an
/// in-memory fake.
public protocol PersonalRecordsSparklineProvider: Sendable {
    func sparkline(
        for kind: MetricKind,
        endingAt: Date
    ) async -> PersonalRecordsSparklineSnapshot
}
