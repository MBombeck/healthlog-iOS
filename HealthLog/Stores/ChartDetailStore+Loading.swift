import Foundation
import Observation

/// `ChartDetailStore` loading pipeline (SWR fan-out + pre-load hook + series
/// assembly). Extracted from `ChartDetailStore.swift` (file_length discipline —
/// pure move, no behaviour change).
@MainActor
extension ChartDetailStore {
    // MARK: - Loading

    /// **W1-2:** the two `measurementsRepo` fan-out fetches below
    /// (`series` + `recent(kind:)`) route through the SWR-wrapped paths
    /// the repo exposes since W1-1. Warm cache hits return in ≤ a few ms;
    /// `isLoading` stays true only long enough for the spinner to flash
    /// (≤ 50 ms on a warm tap). On cold cache the full `task.value`
    /// await drives the skeleton path as before.
    ///
    /// **v0.11 W56 (#56 / #55) — non-blocking pre-load.** The HK daily-stats
    /// refresh (`preLoadHook`, wired only for cumulative kinds like active
    /// energy / steps) used to be `await`ed INLINE at the very top of
    /// `load()`, BEFORE the SWR series fan-out. That made every cumulative
    /// chart wait on a HealthKit aggregate round-trip + server POST before it
    /// could paint a single point — the operator-reported "opening active
    /// energy takes extremely long". It also made a range change look frozen
    /// (#55): the chart held the previous range's `series` until the HK block
    /// AND the new fetch both finished.
    ///
    /// The fan-out now runs FIRST (cache-first, instant on a warm cache), so
    /// the chart paints immediately from whatever data is already available.
    /// The pre-load hook runs CONCURRENTLY and, when it completes, the series
    /// is revalidated so today's cumulative day-total still becomes correct —
    /// just never blocking the first frame. `isLoading` stays true across both
    /// passes so the view can dim / skeleton the chart during a reload instead
    /// of showing a stale-but-static graph.
    public func load() async {
        loadTask?.cancel()
        let currentRange = range
        let currentKind = kind
        let localeTag = resolveLocale()
        // PB1 H1 — consult the consent gate ON THE MAIN ACTOR before the
        // task body so the Befunde fetch never even gets queued when consent
        // is missing. Setting `findingsConsentClosed` early lets the UI
        // render the CTA on first paint rather than after a flicker.
        let consentOpen: Bool = consentGate.map { $0() } ?? true
        findingsConsentClosed = !consentOpen
        if !consentOpen {
            // Clear stale findings — a user who declined after previously
            // consenting should not still see the old prose dangling.
            findings = nil
        }
        let hook = preLoadHook
        let task = Task { [measurementsRepo, insightsRepo] in
            isLoading = true
            error = nil
            defer { isLoading = false }
            // First paint: fan out IMMEDIATELY (cache-first via SWR) — the
            // chart must never wait on HealthKit to show something.
            await self.runFanOut(
                currentRange: currentRange,
                currentKind: currentKind,
                localeTag: localeTag,
                consentOpen: consentOpen,
                measurementsRepo: measurementsRepo,
                insightsRepo: insightsRepo,
                forceSeriesRevalidate: false
            )
            // Cumulative correctness (#56): run the HK daily-stats refresh
            // CONCURRENTLY/AFTER the first paint, then revalidate ONLY the
            // series so today's day-total catches up. The pre-load hook
            // invalidated the series cache key on its server POST, so the
            // forced revalidate below picks up the fresh day-row.
            if let hook {
                await hook()
                if Task.isCancelled { return }
                await self.revalidateSeriesAfterPreload(
                    currentRange: currentRange,
                    currentKind: currentKind,
                    measurementsRepo: measurementsRepo
                )
            }
        }
        loadTask = task
        await task.value
    }

    /// v0.11 W56 — series-only revalidate fired after the non-blocking
    /// pre-load hook completes (cumulative kinds). Re-reads the series with a
    /// forced revalidation so today's freshly-POSTed HK day-total replaces the
    /// stale snapshot the first paint may have shown. Best-effort: a failure
    /// keeps the already-painted series (the hook is decoration, not a gate).
    /// Does NOT touch `dataState` / `recentInRange` / findings — those were
    /// already resolved by the first-paint fan-out.
    private func revalidateSeriesAfterPreload(
        currentRange: Range,
        currentKind: MetricKind,
        measurementsRepo: MeasurementsRepository
    ) async {
        guard Self.kindSupportsSeries(currentKind) else { return }
        do {
            let raw = try await measurementsRepo.series(
                kind: currentKind,
                days: currentRange.rawValue,
                forceRevalidate: true
            )
            if Task.isCancelled { return }
            // v0.12 W8-6 — bucket + LTTB downsample over ~1.5k points off-main
            // so the ~200ms tap-to-detail budget isn't burned on the main
            // thread. `makeSeries` is `nonisolated static` + pure; `raw` and the
            // `MeasurementSeries` result are `Sendable`.
            let rangeDays = currentRange.rawValue
            series = await Task.detached(priority: .userInitiated) {
                Self.makeSeries(from: raw, rangeDays: rangeDays)
            }.value
        } catch {
            let detail = LogSanitizer.redact(String(describing: error))
            HLLog.api.warning(
                "ChartDetail: post-preload series revalidate failed for \(currentKind.rawValue, privacy: .public): \(detail)"
            )
        }
    }

    /// v0.11 W56 — the series + recent + findings + summary fan-out, extracted
    /// from `load()` so the pre-load hook can run OFF the first-paint path.
    /// Behaviour is byte-for-byte the prior `load()` body; only the inline
    /// `preLoadHook` await was lifted out (it now runs after this completes).
    /// `forceSeriesRevalidate` is reserved for the post-preload pass — the
    /// first paint passes `false` so it serves the SWR cache instantly.
    private func runFanOut(
        currentRange: Range,
        currentKind: MetricKind,
        localeTag: String,
        consentOpen: Bool,
        measurementsRepo: MeasurementsRepository,
        insightsRepo: MetricInsightsRepository,
        forceSeriesRevalidate: Bool
    ) async {
        // v0.14 DATA — GUARANTEE `dataState` settles on EVERY exit path. The
        // cancellation early-returns below (`if Task.isCancelled { return }`)
        // run BEFORE the recent-page `derive`, so on rapid re-entry (period
        // control churn, pager settle, tab-return) the task is cancelled in
        // that window and `dataState` stayed `.unknown` → `ChartCard` spun a
        // `ProgressView` forever (operator-reported floors spinner). A
        // `defer`-settle flips any still-pending `.unknown`/`.loading` to
        // `.empty(.noData)` no matter how the body returns; the success paths
        // below resolve it to `.ready`/`.empty` first, so this only fires when
        // an early-return / cancellation left it unresolved.
        if case .unknown = dataState { dataState = .loading }
        defer { collapseDataStateOnLoadFailure() }
        // v0.14 DATA — BMI is DERIVED (no stored series / no `BODY_MASS_INDEX`
        // wire row), so the generic series + recent paths always read empty and
        // the page showed "no data / no chart". Compute the BMI series
        // client-side from the weight series + the profile height (web parity:
        // BMI = weight_kg / height_m²) so BMI shows a value AND a chart.
        if currentKind == .bmi {
            await runBMIFanOut(currentRange: currentRange, measurementsRepo: measurementsRepo)
            return
        }
        do {
            // QC-2 reconcile: short-circuit kinds the server's series
            // endpoint doesn't support (`.bodyTemperature` returns 422)
            // before issuing the network call. Mirrors `DashboardStore`'s
            // `kindSupportsSeries` gate so the chart-detail surface
            // doesn't lit up the API logs with spurious 422s; the
            // SourcesChipStrip + dataState still derive cleanly from
            // the `recent(kind:)` page below.
            let supportsSeries = Self.kindSupportsSeries(currentKind)
            async let seriesAsync: MeasurementSeries? = supportsSeries
                ? try await measurementsRepo.series(
                    kind: currentKind,
                    days: currentRange.rawValue,
                    forceRevalidate: forceSeriesRevalidate
                )
                : nil
            // Concurrent: pull a measurements page for the same kind so
            // the SourcesChipStrip can render real per-source counts.
            // `recent(kind:)` fetches all kinds and filters client-side
            // (server filter isn't wired yet) — a 400-row page is
            // sufficient for ≤1y of weekly readings.
            //
            // v0.7.0 W-STEPS Layer 4 — for the `.all` range we ask for a
            // wide page (`limit: 2000`) so the cumulative-series routing
            // (Layer 3) widens to the full ~10y day-row history instead
            // of capping at the legacy ~1y window. Non-cumulative kinds
            // ignore the larger limit beyond what the server page holds.
            let recentLimit = currentRange == .all ? 2000 : 400
            async let recentAsync = measurementsRepo.recent(kind: currentKind, limit: recentLimit)

            let raw = try await seriesAsync
            if Task.isCancelled { return }
            // v0.12 W8-6 — off-main downsample (see `revalidateSeriesAfterPreload`).
            let rangeDays = currentRange.rawValue
            series = await Task.detached(priority: .userInitiated) {
                Self.makeSeries(from: raw, rangeDays: rangeDays)
            }.value
            // 14-01 (A2) — the measurements page is awaited HERE, with the
            // series, and no longer behind the two best-effort insight
            // roundtrips it does not depend on.
            //
            // The operator's A2 is "Zahlenwerte kommen deutlich später als ihre
            // Grafik". `ChartCard` short-circuits on `series` alone, so the
            // chart paints the moment the line above returns; but the value
            // furniture that sits ABOVE it — the Min/Ø/Max/Median strip (gated
            // on `dataState.hasValue`) and the headline's raw-latest refinement
            // (`latestRawMeasurement`) — settled only after findings AND
            // summary had returned. Two requests later, above the chart,
            // pushing it down.
            //
            // Both fetches were ALREADY in flight concurrently (`async let`
            // above), so this changes the order of the awaits and nothing else:
            // the request count is identical, the page is the same page, and
            // findings/summary keep refining the header afterwards exactly as
            // before. What they may no longer do is be what first creates the
            // value block.
            do {
                let recent = try await recentAsync
                applyRecentPage(recent, currentRange: currentRange)
            } catch {
                applyRecentPageFailure(error, currentKind: currentKind)
            }
            // Findings are best-effort + gated — a failed insights call
            // must not hide the chart, and a closed consent gate skips
            // the call entirely (no LLM round-trip can leak past consent).
            if consentOpen {
                do {
                    findings = try await insightsRepo.fetch(metric: currentKind, locale: localeTag)
                } catch {
                    let detail = LogSanitizer.redact(String(describing: error))
                    HLLog.api.warning("MetricInsights fetch failed for \(currentKind.rawValue, privacy: .public): \(detail)")
                    findings = nil
                }
            }
            // v0.7.0 W-API-RENDER — best-effort per-metric summary
            // (slopes + last-year average) for the HeroStrip trend chips
            // + "vor 1 Jahr" delta. Extracted to keep `load()` under the
            // cyclomatic-complexity ceiling; a failure never hides the
            // chart (it's caught + logged like the findings fetch).
            if Task.isCancelled { return }
            await loadMetricSummary(kind: currentKind, repo: insightsRepo)
        } catch let err as HLError {
            if !Task.isCancelled {
                error = err
                // **V052-A1 N2 fix.** Series fetch threw and we never
                // reached the recent-page derivation. Don't leave
                // `dataState` stuck on `.unknown`/`.loading` — the
                // ErrorBanner overlay surfaces the error and the screen
                // body collapses to the empty-state path until the
                // user retries. Without this, HeroStrip + ChartCard
                // both spin forever while the banner is shown.
                collapseDataStateOnLoadFailure()
            }
        } catch {
            if !Task.isCancelled {
                self.error = .unknown(String(describing: error))
                collapseDataStateOnLoadFailure()
            }
        }
    }

    /// 14-01 (A2) — the measurements page's own derivation, lifted verbatim out
    /// of ``runFanOut(currentRange:currentKind:localeTag:consentOpen:measurementsRepo:insightsRepo:forceSeriesRevalidate:)``
    /// so the page can be awaited beside the series instead of behind the two
    /// insight roundtrips. Same inputs, same assignments, same order — only the
    /// call site moved.
    ///
    /// Source counts + unified `MetricDataState` are both derived from the SAME
    /// `recent(kind:)` page, which is what guarantees the chart-detail
    /// subtitle/drill-down/empty-predicate agrees with what the drill-down
    /// `MeasurementListScreen` would actually show.
    private func applyRecentPage(_ recent: [Measurement], currentRange: Range) {
        let cutoff = Date.now.addingTimeInterval(-Double(currentRange.rawValue) * 86400)
        sourceCountsForRange = Self.computeSourceCounts(measurements: recent, since: cutoff)
        let inRange = recent
            .filter { $0.recordedAt >= cutoff }
            .filter { sourceFilter == nil || $0.source == sourceFilter }
        recentInRange = inRange
        // N4 — true latest raw reading for the source filter, range-
        // independent (drives the HeroStrip "Letzte Messung").
        // #33 — skip malformed 0-systolic/0-diastolic BP rows so the
        // HeroStrip never shows "0/77 mmHg"; falls back to the most
        // recent VALID reading (nil ⇒ honest empty state). Non-BP kinds
        // are always displayable, so behaviour is unchanged for them.
        latestRawMeasurement = recent
            .filter { sourceFilter == nil || $0.source == sourceFilter }
            .filter(\.isDisplayableLatest)
            .max { $0.recordedAt < $1.recordedAt }
        dataState = MetricDataState.derive(
            allSamples: recent,
            inRange: inRange,
            sourceFilterApplied: sourceFilter != nil
        )
    }

    /// 14-01 (A2) — the measurements page's failure arm, likewise lifted
    /// verbatim. A failed page with a good series still resolves `dataState`
    /// from the series points; neither half available collapses to
    /// `.empty(.noData)` rather than a stuck spinner.
    private func applyRecentPageFailure(_ error: Error, currentKind: MetricKind) {
        let detail = LogSanitizer.redact(String(describing: error))
        HLLog.api.warning("recent(kind:) fetch failed for SourcesChipStrip: \(detail)")
        sourceCountsForRange = []
        // DASHBOARD-CHARTS-BUG-FIX (2026-05-16): when the recent-
        // page fan-out fails but the series request succeeded,
        // we used to leave `dataState` at `.unknown/.loading`
        // which made the screen render as two spinners forever
        // (HeroStrip + ChartCard both hard-gated on dataState).
        // The UI now short-circuits on `series` directly, but we
        // ALSO surface a synthetic `.ready` from the series
        // points so the dataState-keyed branches (stats row +
        // drill-down subtitle) come up correctly when the
        // recent-fan-out is the only path that broke.
        if let series, !series.points.isEmpty {
            let kindRaw = currentKind.rawValue
            HLLog.api.notice(
                "ChartDetail: dataState synthesized from series-points for \(kindRaw, privacy: .public)"
            )
            let synthetic = Self.measurementsFromSeriesPoints(
                series.points,
                kind: currentKind
            )
            recentInRange = synthetic
            // N4 — recent-page fan-out failed; best-effort latest raw
            // from the synthetic series-derived rows. #33 — same
            // displayable-latest guard so a synthetic BP row with a
            // 0 component can't surface as the latest value either.
            latestRawMeasurement = synthetic
                .filter(\.isDisplayableLatest)
                .max { $0.recordedAt < $1.recordedAt }
            dataState = MetricDataState.derive(
                allSamples: synthetic,
                inRange: synthetic,
                sourceFilterApplied: sourceFilter != nil
            )
        } else {
            // **V052-A1 N2 fix.** Neither path has data:
            // - `series` returned `nil` (kind unsupported) or an
            //   empty `points` array (server confirmed no rows);
            // - `recent(kind:)` threw (network blip, auth race,
            //   server 5xx).
            //
            // Pre-fix we promoted `.unknown` → `.loading` which
            // pinned HeroStrip + ChartCard on infinite spinners
            // while the screen's body copy already said "Noch
            // keine Befunde" (operator screenshot symptom).
            //
            // The empty `series` itself is positive evidence that
            // there is nothing to render — collapse to
            // `.empty(.noData)` so HeroStrip's `.empty` arm + the
            // ChartCard's `InsufficientDataCard` paint instead of
            // a stuck `ProgressView`.
            let kindRaw = currentKind.rawValue
            HLLog.api.notice(
                "ChartDetail: dataState collapsed to .empty(.noData) for \(kindRaw, privacy: .public) — series + recent both unavailable"
            )
            recentInRange = []
            latestRawMeasurement = nil
            dataState = .empty(reason: .noData)
        }
    }

    /// v0.14 DATA — derived-BMI fan-out. BMI has no server series (it's computed
    /// from weight + height, web-parity), so the generic path always read empty.
    /// This fetches the weight series + the profile height and projects each
    /// weight point to BMI = weight_kg / (height_m)². The resulting series feeds
    /// `chartPoints` (chart) AND a synthetic `recentInRange` so `dataState`
    /// resolves to `.ready`/`.empty` and the HeroStrip + chart both paint.
    private func runBMIFanOut(
        currentRange: Range,
        measurementsRepo: MeasurementsRepository
    ) async {
        let heightCm = heightCmProvider?()
        do {
            let weight = try await measurementsRepo.series(
                kind: .weight,
                days: currentRange.rawValue,
                forceRevalidate: false
            )
            if Task.isCancelled { return }
            guard let heightCm, heightCm > 0, !weight.points.isEmpty else {
                // No height or no weight history → genuinely no BMI to chart.
                series = nil
                recentInRange = []
                latestRawMeasurement = nil
                dataState = .empty(reason: .noData)
                return
            }
            let heightM = heightCm / 100.0
            let bmiPoints: [SeriesPoint] = weight.points.map { point in
                SeriesPoint(
                    id: point.id,
                    at: point.at,
                    value: point.value / (heightM * heightM),
                    secondary: nil
                )
            }
            let values = bmiPoints.map(\.value)
            let mean = values.reduce(0, +) / Double(max(values.count, 1))
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(values.count, 1))
            let stats = SeriesStats(
                mean: mean,
                min: values.min() ?? 0,
                max: values.max() ?? 0,
                stdDev: variance.squareRoot(),
                count: values.count
            )
            let rangeDays = currentRange.rawValue
            series = await Task.detached(priority: .userInitiated) {
                Self.makeSeries(
                    from: MeasurementSeries(kind: .bmi, points: bmiPoints, stats: stats),
                    rangeDays: rangeDays
                )
            }.value
            let synthetic = Self.measurementsFromSeriesPoints(bmiPoints, kind: .bmi)
            let cutoff = Date.now.addingTimeInterval(-Double(currentRange.rawValue) * 86400)
            let inRange = synthetic.filter { $0.recordedAt >= cutoff }
            recentInRange = inRange
            // v0.14.6 N4 (H-1) — BMI is derived (no raw rows), but the HeroStrip
            // "Letzte Messung" must still be range-independent: use the latest
            // projected BMI point, not `displaySeries.points.last` (a midnight
            // bucket-avg on Month/Year). Without this BMI kept the pre-N4 jump.
            latestRawMeasurement = synthetic.max { $0.recordedAt < $1.recordedAt }
            sourceCountsForRange = []
            dataState = MetricDataState.derive(
                allSamples: synthetic,
                inRange: inRange,
                sourceFilterApplied: false
            )
        } catch {
            if !Task.isCancelled {
                let detail = LogSanitizer.redact(String(describing: error))
                HLLog.api.warning("ChartDetail: BMI weight-series fetch failed: \(detail)")
                latestRawMeasurement = nil
                collapseDataStateOnLoadFailure()
            }
        }
    }

    /// v0.7.0 W-API-RENDER — best-effort fetch of the per-metric summary
    /// (slopes + last-year average) feeding the HeroStrip trend decoration.
    /// Extracted from `load()` so the latter stays under the swiftlint
    /// cyclomatic-complexity ceiling. A failure leaves `metricSummary` nil
    /// (hero renders without chips) and is logged, never surfaced as an error.
    private func loadMetricSummary(kind: MetricKind, repo: MetricInsightsRepository) async {
        do {
            metricSummary = try await repo.summary(metric: kind)
        } catch {
            let detail = LogSanitizer.redact(String(describing: error))
            HLLog.api.warning("MetricSummary fetch failed for \(kind.rawValue, privacy: .public): \(detail)")
            metricSummary = nil
        }
    }

    /// **V052-A1 N2 fix.** Collapses a still-pending `dataState` to
    /// `.empty(.noData)` so the chart-detail surface paints its empty-state
    /// path instead of a stuck `ProgressView` when the outer fetch chain
    /// throws before any per-pass derivation could run. Preserves an
    /// already-resolved `.ready` / `.empty` state from a prior load so the
    /// next failed reload doesn't regress what the user already saw.
    private func collapseDataStateOnLoadFailure() {
        switch dataState {
        case .unknown, .loading:
            recentInRange = []
            dataState = .empty(reason: .noData)
        case .ready, .empty:
            break
        }
    }

    /// Synthesize lightweight `Measurement` rows from `SeriesPoint`s so the
    /// store can derive a useful `MetricDataState` when the recent-page
    /// fan-out failed but `/api/measurements/series` succeeded. The synthetic
    /// rows carry the point's `at` + scalar value + a manual-source attribution
    /// (we don't know the real source from the series payload); they're never
    /// persisted, only used as the input to `MetricDataState.derive`. Pure +
    /// `nonisolated` so unit tests can pin the mapping.
    public nonisolated static func measurementsFromSeriesPoints(
        _ points: [SeriesPoint],
        kind: MetricKind
    ) -> [Measurement] {
        points.map { point in
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
                source: .manual
            )
        }
    }

    /// QC-2 reconcile helper — downsamples the raw series tuple from the
    /// server when the kind supports it, or returns `nil` so the chart card
    /// renders its "no series" empty-state when the gate short-circuited.
    /// Extracted from `load()` so the latter stays under the cyclomatic ceiling.
    ///
    /// **Two-stage downsampling (v0.7.1 W-CHARTS-LTTB):** `SeriesDownsampler`
    /// first collapses very long windows into calendar buckets (the legacy
    /// perf gate), then `LTTB.downsampleSeries` caps the *plotted* mark count
    /// at `LTTB.seriesPlotThreshold` while preserving peaks/troughs the
    /// calendar-mean stage would smear. LTTB only selects existing points, so
    /// survivors keep `id`/`at`/`secondary` verbatim. The server-computed
    /// `stats` ride through full-resolution — never derived from the reduced
    /// point set — so HeroStrip min/max/mean stay honest.
    private nonisolated static func makeSeries(
        from raw: MeasurementSeries?,
        rangeDays: Int
    ) -> MeasurementSeries? {
        guard let raw else { return nil }
        let bucketed = SeriesDownsampler.downsampleIfNeeded(raw.points, rangeDays: rangeDays)
        let plotted = LTTB.downsampleSeries(bucketed)
        // W-B187 (#29) — preserve the server-resolved unit through downsampling.
        return MeasurementSeries(kind: raw.kind, points: plotted, stats: raw.stats, unit: raw.unit)
    }

    /// QC-2 reconcile: matches `DashboardStore.kindSupportsSeries` —
    /// `true` when the server's `/api/measurements/series` endpoint
    /// supports the kind. `bodyTemperature` is HK-write-only and the
    /// server returns 422 for it (canonical list lives in
    /// `MeasurementsRepository.seriesKindKey` /
    /// `TrendsOverlayStore.availableMetrics`).
    public nonisolated static func kindSupportsSeries(_ kind: MetricKind) -> Bool {
        switch kind {
        case .bodyTemperature, .walkingSpeed, .walkingAsymmetry, .walkingStepLength, .walkingDoubleSupport,
             .walkingSteadiness,
             .respiratoryRate, .audioExposureEnvironment, .audioExposureHeadphone, .bmi,
             // v0.8.3 W-D — server persists the rows but the series endpoint
             // doesn't accept them yet; detail reads off the list page + HK cache.
             .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight,
             // v0.11 W21 — server/Withings-sourced web-parity kinds; the series
             // endpoint doesn't accept them, so detail reads off the list page.
             .fatFreeMass, .leanBodyMass, .muscleMass, .skinTemperature,
             .pulseWaveVelocity, .vascularAge, .visceralFat, .walkingHeartRate,
             .fatMass,
             // v0.13.1 IC — v1.10.0 additive signals: the series endpoint
             // doesn't accept them, so detail reads off the list page + HK cache.
             .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
             .breathingDisturbances, .cardioRecovery, .wristTemperature,
             // v0.14.6 — v1.12.8 WHOOP-native types: no series endpoint; detail
             // reads off the list page. v0.14.1 W-B189 — v1.17.1 source-fixed
             // signals (#23) join the same no-series bucket.
             .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount, .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation,
             // v0158 — v1.25 clinical types: the server `surfaces.detailPage ==
             // false`, so there is no series endpoint; detail reads off the list
             // page (manual rows for pain / grip / waist).
             .painNRS, .gripStrength, .waistCircumference, .waistToHeight,
             // Build 3 / item 3.3 — the 21 read-only types the list decoder
             // used to drop. The `/api/measurements/series` kind enum does not
             // carry any of them, so detail reads off the list page.
             .phq9Score, .gad7Score, .who5Score, .sciScore,
             .recoveryScore, .stressScore, .strainScore, .hrvRMSSD,
             .dayStrain, .workoutStrain, .sleepPerformance, .sleepEfficiency,
             .sleepConsistency, .sleepNeed, .energyExpenditureKJ, .resilience,
             .irregularRhythmNotification, .highHeartRateEvent, .lowHeartRateEvent,
             .walkingSteadinessEvent, .breathingDisturbanceEvent,
             // Build 7 / item 7.3 — mood is not a `Measurement`; no series
             // endpoint. The tile renders from the summary snapshot.
             .mood:
            false
        case .weight, .bloodPressure, .pulse, .glucose, .bodyFat, .spo2, .bodyWater, .boneMass, .sleep, .steps,
             .restingHeartRate, .hrv, .vo2Max:
            true
        }
    }

    /// Pure helper — `nonisolated` so unit tests can pin the bucketing without
    /// spinning up the live store. Filters by date, groups by source, sorts
    /// by count desc with stable secondary sort on `source.rawValue`.
    public nonisolated static func computeSourceCounts(
        measurements: [Measurement],
        since cutoff: Date
    ) -> [SourceCount] {
        let inRange = measurements.filter { $0.recordedAt >= cutoff }
        let grouped = Dictionary(grouping: inRange, by: \.source)
        return grouped
            .map { source, items -> SourceCount in
                let latest = items.map(\.recordedAt).max()
                return SourceCount(source: source, count: items.count, latest: latest)
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.source.rawValue < rhs.source.rawValue
            }
    }
}
