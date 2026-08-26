import Foundation

/// b241 — tile-state fallbacks that don't come from the `/api/measurements`
/// wide-page fan-out. Two data sources the fan-out structurally can't cover:
///
/// - **Mood** (`Fix 2`) — mood is a `MoodEntry` served only by
///   `/api/mood-entries` (`MoodStore`), never a `Measurement`, so it never
///   appears in `recentAll(limit:)`. Its tile state is derived from the
///   `MoodStore` snapshot instead.
/// - **No-series kinds** (`Fix 3`, e.g. `.bmi`) — kinds whose `/series`
///   endpoint the server rejects (`kindSupportsSeries == false`) so they can't
///   use the series fallback, but that DO have stored rows reachable via the
///   kind-scoped `/api/measurements?type=<MeasurementType>` list page. When the
///   wide page misses them (a HK power-user's recent rows are dominated by
///   steps/HR), a targeted `recent(kind:)` read re-hydrates the tile to `.ready`.
///
/// Split out of `DashboardStore+MetricStates.swift` under the PROJECT_GUIDE.md
/// file-length discipline — pure addition, same module, same actor.
extension DashboardStore {
    /// b241 Fix 2 — derive the `.mood` tile state from the `MoodStore` snapshot.
    /// Mood entries carry a 1–5 score + timestamp; we project them into
    /// lightweight `.scalar` `Measurement` rows purely so the tile can consume
    /// the SAME `MetricDataState.ready(latest:samples:)` shape every other tile
    /// uses. Non-empty ⇒ `.ready` (newest entry as `latest`); empty ⇒
    /// `.empty(.noData)` (the honest "log your first mood" first-time copy).
    ///
    /// **b-mood-sparkline — coarse (per-day) samples.** An operator with 483
    /// mood rows saw a jagged, over-detailed sparkline while every other tile
    /// renders a coarse (server-bucketed, ~daily) curve. The universal sparkline
    /// hydration (`DashboardStore+MetricStates.hydrateSparkline`) projects one
    /// point per `samples` row, and `.mood` has no `/series` endpoint, so the
    /// summary sparkline is thin (`summaryHasEmptySparkline(.mood) == true`) and
    /// hydration filled it from all 483 raw rows. We now collapse the entries to
    /// **one point per calendar day (arithmetic mean of that day's scores)** via
    /// the shared `SeriesDownsampler.aggregate(_:by: .day)` daily-mean bucketer —
    /// the same machinery the chart screens use — so the mood sparkline matches
    /// the coarse cadence of the other tiles.
    ///
    /// **b-mood-smooth — a 3-day moving average ON TOP of the day-means.** Day
    /// means alone did not calm the curve: mood is a **1–5 integer** scale, so a
    /// run of 5 / 2 / 4 / 1 stays a zig-zag where weight moves in tenths. The
    /// other tiles look smooth because their DATA is smooth, not because they are
    /// drawn differently (`HLSparkline` already interpolates `.catmullRom` for
    /// every tile). So the mood series gets one extra display-only pass — see
    /// ``smoothed(_:window:)`` for the window rationale.
    ///
    /// `latest` stays the true newest **raw** entry's score (neither the day-mean
    /// nor the moving average), matching how every other tile's `.ready` `latest`
    /// is the most recent real reading (`MetricDataState.derive` picks
    /// `max(by: recordedAt)` of the raw rows) — the tile headline must show the
    /// last mood the operator logged. A smoothed headline would be an invention.
    ///
    /// Pure + `nonisolated` so the unit suite can pin the contract without the
    /// actor. The projected rows are display-only (they never round-trip to the
    /// server) — mood writes still flow exclusively through `MoodStore`.
    nonisolated static func moodTileState(entries: [MoodEntry]) -> MetricDataState {
        guard let newest = entries.max(by: { $0.recordedAt < $1.recordedAt }) else {
            return .empty(reason: .noData)
        }
        // `latest` = the true newest raw entry (real reading, not a day-mean).
        let latest = Measurement(
            id: newest.id,
            kind: .mood,
            recordedAt: newest.recordedAt,
            value: .scalar(Double(newest.score)),
            source: .manual
        )
        // `samples` = per-day means, then a 3-day moving average, so the hydrated
        // sparkline reads as a trend instead of a per-day zig-zag. Display-only:
        // these rows never round-trip to the server, export, or storage.
        return .ready(
            latest: latest,
            samples: smoothed(dailyMeanMoodSamples(from: entries), window: moodSparklineSmoothingWindow)
        )
    }

    /// b-mood-smooth — the mood sparkline's moving-average window, in **days**
    /// (the `samples` slice is already one point per calendar day).
    ///
    /// **Why 3 and not 7.** The dashboard tile shows a ~60 pt line over the tile's
    /// range and, for a person who logs mood a few times a week, that can be as
    /// few as 5–10 day-points. A 7-day window over 8 points averages nearly the
    /// whole series into every point — the curve collapses to a near-flat line and
    /// the tile stops saying anything. A 3-day centred window halves the amplitude
    /// of a single outlier day while keeping the direction and the turning points,
    /// which is exactly the "Wellenbewegung" the other tiles show.
    ///
    /// The 7-day window is not absent from the product — it is the *promoted*
    /// layer of `MoodTrendChart` on the Mood Insights page, where there is a full
    /// axis, a date scale, AND the raw daily line underneath it to fall back on.
    /// A tile sparkline has none of those, so it gets the gentler window.
    nonisolated static let moodSparklineSmoothingWindow = 3

    /// b-mood-smooth — centred moving average over an ascending, one-point-per-day
    /// series. Pure and display-only: `id` and `recordedAt` are preserved (so
    /// SwiftUI Charts keeps animating instead of re-mounting) and only the value
    /// is replaced by the mean of the point and its `window / 2` neighbours on
    /// each side, clamped at the ends.
    ///
    /// **Centred, not trailing**, because a trailing average visibly lags the data
    /// by half the window — on a tile with no x-axis that just reads as a wrong
    /// curve. **Skipped below 3 points**, because a 3-wide window over 2 points
    /// averages both into the same value and draws a flat line, which would erase
    /// signal rather than calm it.
    nonisolated static func smoothed(_ samples: [Measurement], window: Int) -> [Measurement] {
        guard window > 1, samples.count > 2 else { return samples }
        let radius = window / 2
        let calendar = Calendar.current
        return samples.map { sample in
            let sampleDay = calendar.startOfDay(for: sample.recordedAt)
            let neighbours = samples.filter { candidate in
                let candidateDay = calendar.startOfDay(for: candidate.recordedAt)
                let distance = calendar.dateComponents([.day], from: sampleDay, to: candidateDay).day ?? 0
                return abs(distance) <= radius
            }
            let mean = neighbours.map(\.primaryValue).reduce(0, +) / Double(neighbours.count)
            return Measurement(
                id: sample.id,
                kind: sample.kind,
                recordedAt: sample.recordedAt,
                value: .scalar(mean),
                source: sample.source
            )
        }
    }

    /// Resolves the dashboard's literal direction indicator from the bounded
    /// series that is already visible in the tile. Server-provided directions
    /// stay authoritative. Only the three explicitly requested dashboard kinds
    /// opt into client derivation; clinical and polarity-aware metrics keep
    /// `.unknown` rather than silently acquiring new semantics.
    nonisolated static func dashboardTrend(
        server: TrendIndicator,
        kind: MetricKind,
        visibleValues: [Double]
    ) -> TrendIndicator {
        guard server == .unknown else { return server }
        guard [.weight, .steps, .sleep].contains(kind),
              visibleValues.count >= 2,
              visibleValues.allSatisfy(\.isFinite),
              let first = visibleValues.first,
              let last = visibleValues.last else { return .unknown }
        if last > first { return .up }
        if last < first { return .down }
        return .flat
    }

    /// b-mood-sparkline — collapse raw mood entries to one `.scalar`
    /// `Measurement` per calendar day, valued at that day's mean score, by
    /// reusing the shared `SeriesDownsampler` daily-mean bucketer (so mood
    /// matches the chart screens' downsampling exactly instead of inventing a new
    /// scheme). Bucket start-of-day + arithmetic mean live in `SeriesDownsampler`;
    /// this only bridges `MoodEntry` ⇄ `SeriesPoint` ⇄ `Measurement`.
    private nonisolated static func dailyMeanMoodSamples(from entries: [MoodEntry]) -> [Measurement] {
        let points = entries.map { entry in
            SeriesPoint(id: entry.id, at: entry.recordedAt, value: Double(entry.score), secondary: nil)
        }
        return SeriesDownsampler.aggregate(points, by: .day).map { point in
            Measurement(
                id: point.id,
                kind: .mood,
                recordedAt: point.at,
                value: .scalar(point.value),
                source: .manual
            )
        }
    }

    /// b241 Fix 3 — no-series kinds that get a kind-scoped `?type=` fallback when
    /// the wide page yields `.empty`. Kept as an explicit, auditable set (not a
    /// blanket "every no-series kind") so the fallback fan-out stays bounded and
    /// only fires for kinds with a real stored `MeasurementType` page worth a
    /// second round-trip. `.bmi` resolves to `?type=BODY_MASS_INDEX` via
    /// `MetricKind.availabilitySummaryKey` (the `recent(kind:)` kind-scoped arm).
    static let kindScopedTileFallbackKinds: Set<MetricKind> = [.bmi]

    /// b241 Fix 3 — kind-scoped `?type=` fan-out. Modeled on
    /// `fanOutSeriesFallback` but reads the kind's own list page
    /// (`recent(kind:, limit:)` → `/api/measurements?type=<MeasurementType>`)
    /// rather than `/series`, because the server rejects these kinds' series
    /// query. Bounded-parallel (same `seriesFallbackConcurrency` cap); writes
    /// into `staging` so the caller applies one atomic commit. A failed/empty
    /// read leaves the wide-page-derived state intact.
    func fanOutKindScopedFallback(
        kinds: [MetricKind],
        measurementsRepo: MeasurementsRepository,
        rangeDays: Int,
        now: Date,
        sessionLease: AuthenticatedSessionLease,
        staging: inout [MetricKind: MetricDataState]
    ) async {
        guard !kinds.isEmpty else { return }
        let cap = Self.seriesFallbackConcurrency
        let results = await withTaskGroup(
            of: KindScopedFallbackResult?.self,
            returning: [MetricKind: KindScopedFallbackResult].self
        ) { group in
            var iterator = kinds.makeIterator()
            var inFlight = 0
            func addNext() {
                guard let kind = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    await Self.deriveKindScopedFallback(
                        kind: kind,
                        measurementsRepo: measurementsRepo,
                        rangeDays: rangeDays,
                        now: now,
                        sessionLease: sessionLease
                    )
                }
            }
            for _ in 0 ..< cap {
                addNext()
            }
            var collected: [MetricKind: KindScopedFallbackResult] = [:]
            while inFlight > 0 {
                if let produced = await group.next(), let result = produced {
                    collected[result.kind] = result
                }
                inFlight -= 1
                addNext()
            }
            return collected
        }
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        // Apply in the original `kinds` order so logging + any summary mutation
        // sequence stays stable + reproducible on device (mirrors the series path).
        for kind in kinds {
            guard let result = results[kind] else { continue }
            switch result.derived {
            case .ready:
                // MetricKind raw value is an enum case — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.api.notice(
                    "Dashboard tile state synthesized from kind-scoped fallback for \(kind.rawValue, privacy: .public)"
                )
                staging[kind] = result.derived
            case .empty(.outsideRange):
                // The kind has rows, just none in the queried window — still
                // better than `.empty(.noData)` (the UI can render the real
                // "Letzte Messung vor X Tagen" timestamp). Hydrate the sparkline
                // from the full set when the summary shipped a thin one.
                staging[kind] = result.derived
                if summaryHasEmptySparkline(for: kind), !result.measurements.isEmpty {
                    hydrateSparkline(for: kind, from: result.measurements)
                }
            default:
                break
            }
        }
    }

    /// b241 Fix 3 — pure (nonisolated) per-kind list-page fetch + state
    /// derivation, run inside the bounded task group. Returns `nil` on fetch
    /// failure or an empty page so the caller leaves the wide-page-derived state
    /// intact (identical contract to `deriveSeriesFallback`).
    private nonisolated static func deriveKindScopedFallback(
        kind: MetricKind,
        measurementsRepo: MeasurementsRepository,
        rangeDays: Int,
        now: Date,
        sessionLease: AuthenticatedSessionLease
    ) async -> KindScopedFallbackResult? {
        let rows: [Measurement]
        do {
            try sessionLease.requireCurrent()
            rows = try await measurementsRepo.recent(kind: kind, limit: 400)
            try sessionLease.requireCurrent()
        } catch {
            guard sessionLease.isCurrent else { return nil }
            let detail = LogSanitizer.redact(String(describing: error))
            HLLog.api
                .warning(
                    "Dashboard kind-scoped fallback failed for \(kind.rawValue, privacy: .private): \(detail, privacy: .private)"
                )
            return nil
        }
        guard !rows.isEmpty else { return nil }
        let cutoff = now.addingTimeInterval(-Double(rangeDays) * 86400)
        let inRange = rows.filter { $0.recordedAt >= cutoff }
        let derived = MetricDataState.derive(
            allSamples: rows,
            inRange: inRange,
            sourceFilterApplied: false
        )
        return KindScopedFallbackResult(kind: kind, derived: derived, measurements: rows)
    }
}

/// b241 Fix 3 — one kind-scoped fallback task's output. `Sendable` so it crosses
/// the task-group boundary; the caller applies the `staging` write on the main
/// actor in deterministic `kinds` order after the group settles. Mirrors the
/// `SeriesFallbackResult` shape in `DashboardStore+MetricStates.swift`.
private struct KindScopedFallbackResult {
    let kind: MetricKind
    let derived: MetricDataState
    let measurements: [Measurement]
}
