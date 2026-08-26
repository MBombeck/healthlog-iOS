import Foundation

/// AUD-7 H2 — one bounded-parallel series-fallback task's output. `Sendable`
/// so it crosses the task-group boundary; the caller applies the `staging`
/// write + sparkline hydration on the main actor in deterministic `kinds`
/// order after the group settles.
private struct SeriesFallbackResult {
    let kind: MetricKind
    let derived: MetricDataState
    let measurements: [Measurement]
}

// MARK: - Per-metric MetricDataState machinery

/// W-FILELEN — the PA4 unified-data-source per-kind `MetricDataState` pipeline
/// (tile-completeness synthesis, wide-page derive + series fallback, the sticky
/// state machine, sparkline hydration, the post-settle policy tick) lifted
/// verbatim out of `DashboardStore.swift` into this same-module extension to keep
/// that file under the 600-line `file_length` swiftlint budget. Pure move, no
/// behaviour change. The store's stored state these methods write uses
/// `internal(set)` for exactly this reason.
extension DashboardStore {
    /// **V052-R3 A-H1.** Test-only seam — drives the post-settle tick
    /// without sleeping through wall-clock 1.6s in the unit suite. The
    /// production path schedules a `Task.sleep` that ends up calling this
    /// same method on the main actor.
    func recomputePolicyForTesting() {
        recomputePolicy()
    }

    /// Bumps `policyTick` so any observer reading `policyTick` (the
    /// dashboard view's `orderedMetrics` derivation) re-evaluates the
    /// `DashboardEmptyTilePolicy.shouldAutoHide` predicate. Pure state
    /// mutation — no side effects on summary / states / settled.
    func recomputePolicy() {
        policyTick &+= 1
    }

    /// **V052-R3 A-H1.** Schedules the post-settle policy tick.
    /// Idempotent: if a tick is already scheduled and not yet fired, this
    /// call is a no-op. The 1.6s delay is one frame past the
    /// `DashboardEmptyTilePolicy.loadingTimeoutSeconds = 1.5s` grace so
    /// the next render observes `now - settled >= 1.5s`.
    func schedulePolicyTickAfterSettle(at settled: Date, sessionLease: AuthenticatedSessionLease) {
        // Guard: only schedule once per settle. Subsequent settle events
        // arriving inside the grace window get absorbed — the already-
        // scheduled task will fire the tick after the original delay.
        if let existing = scheduledPolicyTickAt,
           settled.timeIntervalSince(existing) < DashboardEmptyTilePolicy.loadingTimeoutSeconds
        {
            return
        }
        scheduledPolicyTickAt = settled
        policyTickTask?.cancel()
        policyTickTask = Task { @MainActor [weak self] in
            // 1.6s — 100 ms past the 1.5s grace. The extra frame avoids a
            // race where the render observes `now == settled + 1.5s` and
            // the `>=` comparison falls just short due to clock jitter.
            do {
                try await Task.sleep(for: .seconds(1.6))
                try sessionLease.requireCurrent()
            } catch {
                return
            }
            guard let self, authenticatedEffectIsCurrent(sessionLease) else { return }
            recomputePolicy()
        }
    }

    /// Terminal cleanup drain seam consumed by the composition boundary.
    func awaitAuthenticatedSessionQuiescence() async {
        let task = policyTickTask
        policyTickTask = nil
        task?.cancel()
        await task?.value
    }

    /// DASHBOARD-TILE-COMPLETENESS — synthesise placeholder `DashboardMetric`s
    /// for every layout entry with `tileVisible: true` that is missing from
    /// `summary.metrics`. Solves the operator-reported "großes Nichts" for
    /// BP / Puls / Schlaf where the server's `/api/dashboard/summary`
    /// fast-path skips the kind but the chart-detail's `/api/measurements/series`
    /// has real data.
    ///
    /// The placeholders carry `latestValue: nil` + empty sparkline — they
    /// land as `.empty(.noData)` in `metricStates`, which triggers the
    /// existing series-fallback (Bug-Fix-2) and hydrates the tile to
    /// `.ready` once the per-kind series request resolves. The end result
    /// is the dashboard renders every tile-visible layout entry by default,
    /// with the chart-detail's data, regardless of server summary coverage.
    ///
    /// **No-op when:** `summary == nil`, layout is empty, or no layout
    /// entries are missing from the summary. Idempotent — calling twice
    /// with the same inputs produces the same output.
    public func synthesiseMissingTiles(layout: DashboardWidgetLayout) {
        guard let current = summary else { return }
        let existingKinds: Set<MetricKind> = Set(current.metrics.map(\.kind))
        let synthesised: [DashboardMetric] = layout.widgets.compactMap { widget -> DashboardMetric? in
            guard widget.effectiveTileVisible,
                  let kind = DashboardWidgetId.metricKind(forId: widget.id),
                  !existingKinds.contains(kind) else { return nil }
            return Self.placeholder(for: kind, order: widget.order)
        }
        guard !synthesised.isEmpty else { return }
        let merged = current.metrics + synthesised
        summary = DashboardSummary(
            greeting: current.greeting,
            compliance: current.compliance,
            highlightInsight: current.highlightInsight,
            metrics: merged,
            lastUpdated: current.lastUpdated
        )
        // Pure tile count — operator-grade, no user data.
        // swiftlint:disable:next hllog_public_privacy_interpolation
        HLLog.ui.notice(
            "Dashboard synthesised \(synthesised.count, privacy: .public) placeholder tiles from layout"
        )
    }

    /// Build a placeholder `DashboardMetric` for a kind missing from the
    /// server summary. `latestValue` + `sparkline` deliberately empty so the
    /// tile renders the empty-state until the series-fallback hydrates it.
    /// The descriptor supplies title + unit so the placeholder reads
    /// identical to a server-emitted tile while it's hydrating.
    static func placeholder(for kind: MetricKind, order: Int) -> DashboardMetric {
        let descriptor = kind.descriptor
        return DashboardMetric(
            id: "synth-\(kind.rawValue)-\(order)",
            kind: kind,
            title: String(localized: descriptor.title),
            latestValue: nil,
            secondaryValue: nil,
            unit: String(localized: descriptor.unitLabel),
            trend: .unknown,
            sparkline: [],
            updatedAt: nil
        )
    }

    /// **V053-D3 sticky reset.** Explicit pull-to-refresh entry point —
    /// clears `metricStates` + `fanOutSettledAt` so the next
    /// `refreshMetricStates` call re-derives every kind from scratch. Sticky
    /// transitions (`.ready` never demotes mid-session) intentionally make
    /// scenePhase + cold-launch reloads stable; pull-to-refresh is the one
    /// user-triggered event that explicitly invalidates the prior verdicts.
    public func resetMetricStatesForRefresh() {
        metricStates = [:]
        fanOutSettledAt = nil
        scheduledPolicyTickAt = nil
    }

    /// Refresh per-metric `MetricDataState` against the shared measurements
    /// repository. The dashboard view calls this after `summary` resolves
    /// so the tiles can re-derive empty-vs-ready from the SAME endpoint
    /// the chart-detail screen consumes (PA4 §"Recommended unified data-
    /// source pattern").
    ///
    /// **F1 (PB5 review) — single wide fetch, derive locally.** The
    /// previous fan-out fired N parallel `/api/measurements?limit=400`
    /// requests (one per `MetricKind`, up to 11) — each returning the
    /// SAME page filtered client-side. `MeasurementsRepository.recent()`
    /// does not pipe through SWR today, so every call was a real network
    /// round-trip. Now we fetch once via `recentAll` and run the pure
    /// `MeasurementsRepository.deriveState` over the in-memory slice per
    /// kind. One round-trip instead of N; per-kind derivation is pure.
    ///
    /// **DASHBOARD-BUG-FIX-2 — per-kind series-endpoint fallback.** For
    /// high-volume HK users (~40 measurements/day from Apple Watch),
    /// `recentAll(limit: 400)` returns roughly the last 10 days dominated
    /// by one or two HK-streamed kinds (Steps, Pulse-every-few-seconds).
    /// Manual + lower-frequency kinds (BP, Glucose, Weight) get pushed
    /// outside the 400-row window even though they were recorded recently
    /// — and the derived state ends up `.empty(.outsideRange)` or
    /// `.empty(.noData)`. The chart-detail screen reads from
    /// `/api/measurements/series` per-kind and renders correctly,
    /// producing the operator-reported "Tile leer, Detail voll" regression.
    ///
    /// Fallback path: for every kind that resolved to `.empty` from the
    /// wide page, fire `series(kind:, days: rangeDays)` (the SAME endpoint
    /// ChartDetail uses). If the series has points, synthesize a `.ready`
    /// state from the series tail. Series-unsupported kinds
    /// (`.bodyTemperature` server-side) keep their `recentAll`-derived
    /// state. The fallback is best-effort — a failed series request
    /// leaves the wide-page-derived state intact.
    ///
    /// `rangeDays` mirrors the chart-detail default (`.month` = 30) so
    /// "what the tile shows" matches "what the detail shows" when the
    /// user taps in.
    ///
    /// **V053-D3 sticky state machine.** Both passes now compute into a
    /// local staging dictionary and publish a SINGLE atomic update at the
    /// end. Mid-fan-out intermediate states (e.g. wide-page sets
    /// `.empty(.outsideRange)`, series-fallback then promotes to `.ready`)
    /// are not visible to the view — eliminating the operator-reported
    /// flicker where tiles flashed `.loading → .empty → .ready` while
    /// the fan-out was still in progress.
    ///
    /// In addition, monotonic transitions are enforced via
    /// `commitStates(...)`: once a tile is `.ready` it never demotes back
    /// to `.loading` / `.empty` in the same session. Pull-to-refresh is the
    /// only path that explicitly invalidates prior verdicts — see
    /// `resetMetricStatesForRefresh()`.
    public func refreshMetricStates(
        kinds: [MetricKind],
        measurementsRepo: MeasurementsRepository,
        moodEntries: [MoodEntry] = [],
        rangeDays: Int = 30,
        now: Date = .now
    ) async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        let allSamples: [Measurement]
        do {
            try sessionLease.requireCurrent()
            allSamples = try await measurementsRepo.recentAll(limit: 400)
            try sessionLease.requireCurrent()
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            // A failed fetch must not blank existing tile states — keep
            // whatever is already in `metricStates`. The summary endpoint's
            // `latestValue` remains the fallback display until the next
            // refresh attempt succeeds.
            //
            // **V052-A1 N1 fix:** still mark fan-out as settled so
            // `DashboardEmptyTilePolicy.shouldAutoHide` can apply its
            // loading-too-long fallback to tiles whose state stayed
            // `.unknown`/`.loading` because `recentAll()` never landed.
            // Without this signal those tiles would stick on an em-dash
            // forever after a network or auth failure.
            let detail = LogSanitizer.redact(String(describing: error))
            HLLog.api.warning("Dashboard recentAll() failed: \(detail, privacy: .public)")
            // W-TILEHOTFIX (v0.6.2) — set-once anchor mirrors the happy path.
            // See the happy-path comment for the operator-walkthrough context.
            if fanOutSettledAt == nil {
                fanOutSettledAt = now
                schedulePolicyTickAfterSettle(at: now, sessionLease: sessionLease)
            }
            return
        }
        // V053-D3 sticky pattern: stage everything locally; commit atomic.
        var staging: [MetricKind: MetricDataState] = [:]
        // First pass: derive from the wide page (into staging only).
        var emptyKinds: [MetricKind] = []
        // b241 Fix 3 — no-series kinds (`.bmi`) whose wide-page derivation came
        // back `.empty` but that have stored rows on the kind-scoped `?type=`
        // page; retried via `recent(kind:)` (see `fanOutKindScopedFallback`).
        var scopedFallbackKinds: [MetricKind] = []
        for kind in kinds {
            // b241 Fix 2 — mood is a `MoodEntry`, not a `Measurement`; it never
            // appears in the `/api/measurements` wide page (the fan-out always
            // derived `.empty(.noData)` even with 483 rows in `MoodStore`).
            // Derive the mood tile state from the MoodStore snapshot instead.
            if kind == .mood {
                staging[kind] = Self.moodTileState(entries: moodEntries)
                continue
            }
            let state = MeasurementsRepository.deriveState(
                allSamples: allSamples,
                kind: kind,
                rangeDays: rangeDays,
                now: now
            )
            staging[kind] = state
            if case .empty = state {
                if Self.kindSupportsSeries(kind) {
                    emptyKinds.append(kind)
                } else if Self.kindScopedTileFallbackKinds.contains(kind) {
                    scopedFallbackKinds.append(kind)
                }
            }
        }
        // Second pass: per-kind series fallback into staging. Empty-kinds
        // that resolve via series get upgraded inside `staging`; the wide-
        // page-set state is the fallback if series throws / empties.
        await fanOutSeriesFallback(
            kinds: emptyKinds,
            measurementsRepo: measurementsRepo,
            rangeDays: rangeDays,
            now: now,
            sessionLease: sessionLease,
            staging: &staging
        )
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        // b241 Fix 3 — third pass: kind-scoped `?type=` fallback for no-series
        // kinds (`.bmi`, whose `/series` the server rejects with 422). Re-reads
        // the kind's own `/api/measurements?type=BODY_MASS_INDEX` page and derives
        // `.ready` from the stored rows the wide page missed.
        await fanOutKindScopedFallback(
            kinds: scopedFallbackKinds,
            measurementsRepo: measurementsRepo,
            rangeDays: rangeDays,
            now: now,
            sessionLease: sessionLease,
            staging: &staging
        )
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        // ATOMIC COMMIT — single observable update for all kinds. Sticky
        // transitions enforced inside `commitStates`.
        commitStates(staging)
        // Universal sparkline hydration: for every kind that landed `.ready`
        // (whether via wide page or series fallback), if the summary's
        // sparkline for that kind is empty (synthesized placeholder or
        // server omission), hydrate it from the resolved samples so the
        // tile renders a chart even when the server skipped it.
        for (kind, state) in metricStates {
            guard case let .ready(_, samples) = state,
                  kind == .mood || summaryHasEmptySparkline(for: kind) else { continue }
            hydrateSparkline(for: kind, from: samples)
        }
        // **W-TILEHOTFIX (v0.6.2) — set-once `fanOutSettledAt`.** Operator
        // on v0.6.1.28 build 68: "wenn ich von einer anderen Karte komme,
        // immer Kurzkacheln dargestellt werden, die danach weg sind." Every
        // `.task` re-fire on nav-pop / tab-return rewrote `fanOutSettledAt`
        // = now, which re-opened `DashboardEmptyTilePolicy`'s 1.6s grace —
        // synth-placeholder tiles that were correctly hidden popped back
        // visible until the next policy tick fired. Set-once keeps the
        // already-settled hide decisions settled. Pull-to-refresh remains
        // the explicit user-driven re-open (clears anchor to nil).
        if fanOutSettledAt == nil {
            fanOutSettledAt = now
            schedulePolicyTickAfterSettle(at: now, sessionLease: sessionLease)
        }
    }

    /// **V053-D3 sticky commit.** Merges staged state into `metricStates`
    /// using `shouldAcceptTransition` (monotonic per-kind). V0.5.4-BF-1
    /// adds forensic trail via `HLLog.ui` — every accept + reject emits a
    /// debug line in `subsystem == "dev.healthlog.app"` so the operator
    /// can grep `Console.app` while reproducing flicker on device.
    func commitStates(_ staging: [MetricKind: MetricDataState]) {
        var next = metricStates
        for (kind, candidate) in staging {
            let current = next[kind] ?? .unknown
            if Self.shouldAcceptTransition(from: current, to: candidate) {
                next[kind] = candidate
                // V0.5.4-BF-1 forensic trail — grep `category == "ui"` in
                // Console.app while reproducing flicker on device.
                HLLog.ui
                    .debug(
                        "Dashboard sticky-commit \(kind.rawValue, privacy: .public): \(Self.stateTag(current), privacy: .public) → \(Self.stateTag(candidate), privacy: .public)"
                    )
            } else {
                HLLog.ui
                    .debug(
                        "Dashboard sticky-reject \(kind.rawValue, privacy: .public): keep \(Self.stateTag(current), privacy: .public), reject \(Self.stateTag(candidate), privacy: .public)"
                    )
            }
        }
        metricStates = next
    }

    /// Pure predicate for `commitStates` — exposed `internal` so the unit
    /// suite can pin the sticky-transition contract without round-tripping
    /// through `refreshMetricStates`.
    nonisolated static func shouldAcceptTransition(
        from current: MetricDataState,
        to candidate: MetricDataState
    ) -> Bool {
        switch (current, candidate) {
        // From .unknown / .loading: accept anything (initial resolution).
        case (.unknown, _), (.loading, _):
            true
        // From .ready: only accept another .ready (data update).
        case (.ready, .ready):
            true
        case (.ready, _):
            false
        // From .empty(.outsideRange): accept .ready (upgrade) but NOT
        // .empty(.noData) — outsideRange carries the more useful timestamp.
        case (.empty(.outsideRange), .ready):
            true
        case (.empty(.outsideRange), .empty(.outsideRange)):
            true
        case (.empty(.outsideRange), _):
            false
        // From .empty(.noData) / .empty(.sourceFiltered): accept any upgrade.
        case (.empty, _):
            true
        }
    }

    /// `true` when the metric's `sparkline` has fewer than two points (the
    /// `HLSparkline` rendering threshold — less collapses to a hairline).
    /// **REG-11 (v0.5.6):** pre-fix this was `.isEmpty`, so `sparkline: [124]`
    /// (one daily bucket — realistic for low-frequency manual entry) skipped
    /// hydration and rendered as "no chart" while detail showed the chart.
    func summaryHasEmptySparkline(for kind: MetricKind) -> Bool {
        guard let summary else { return false }
        guard let metric = summary.metrics.first(where: { $0.kind == kind }) else { return false }
        return metric.sparkline.count < 2
    }

    /// Per-kind series-endpoint fan-out. Reads the same path the chart-
    /// detail screen consumes (`/api/measurements/series?kind=…&days=…`)
    /// and synthesizes a `.ready` `MetricDataState` from the series points.
    /// Logs an `os_log.notice` for forensic trail whenever the fallback
    /// path activates so the operator's logs reveal a fast-path miss.
    ///
    /// **V053-D3 sticky pattern.** Writes into `staging` rather than the
    /// published `metricStates` so the caller can apply one atomic commit
    /// at the end of the fan-out. Eliminates the operator-reported flicker
    /// where the wide-page-`.empty` intermediate paints the tile before
    /// the series-fallback's `.ready` replaces it.
    ///
    /// **V053-D2 universal sparkline.** Hydrates the summary's sparkline
    /// for the kind even when the series resolves to `.empty(.outsideRange)`
    /// — the user has data, just not in the queried window, and showing
    /// the older points beats showing a missing chart.
    func fanOutSeriesFallback(
        kinds: [MetricKind],
        measurementsRepo: MeasurementsRepository,
        rangeDays: Int,
        now: Date,
        sessionLease: AuthenticatedSessionLease,
        staging: inout [MetricKind: MetricDataState]
    ) async {
        guard !kinds.isEmpty else { return }
        // **AUD-7 H2 — bounded-parallel fan-out.** The fallback previously ran
        // SERIALLY (one `series()` round-trip after another); on a high-volume
        // HealthKit user up to ~11 manual kinds fall through, adding ~300ms+ to
        // the cold dashboard first-paint path against the ≤100ms tile / ≤200ms
        // tap-to-detail budgets. The SWR layer already single-flight-dedups
        // same-key concurrency, so issuing the reads through a bounded
        // (`cap = 4`) sliding-window task group is safe and collapses the
        // latency without raising the network budget. The pure fetch +
        // derivation runs inside the group; the `staging` writes, logging, and
        // sparkline hydration are applied AFTER the group in the original
        // `kinds` order so results + ordering stay deterministic (identical to
        // the serial path — no visible behaviour change).
        let cap = Self.seriesFallbackConcurrency
        let results = await withTaskGroup(
            of: SeriesFallbackResult?.self,
            returning: [MetricKind: SeriesFallbackResult].self
        ) { group in
            var iterator = kinds.makeIterator()
            var inFlight = 0
            func addNext() {
                guard let kind = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    await Self.deriveSeriesFallback(
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
            var collected: [MetricKind: SeriesFallbackResult] = [:]
            while inFlight > 0 {
                // `group.next()` yields `SeriesFallbackResult??` (the task's
                // optional return wrapped in the iterator's optional); flatten
                // both — a `nil` result is a failed/empty kind, skipped.
                if let produced = await group.next(), let result = produced {
                    collected[result.kind] = result
                }
                inFlight -= 1
                addNext()
            }
            return collected
        }
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        // Apply in the original `kinds` order so the forensic-trail logging and
        // any summary mutation sequence are stable + reproducible on device.
        for kind in kinds {
            guard let result = results[kind] else { continue }
            switch result.derived {
            case .ready:
                // MetricKind raw value is an enum case — operator-grade.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.api.notice(
                    "Dashboard tile state synthesized from series fallback for \(kind.rawValue, privacy: .public)"
                )
                staging[kind] = result.derived
            case .empty(.outsideRange):
                // Series carries data but everything is outside the
                // queried window — still better than the wide-page
                // `.empty(.noData)` because the UI can render
                // "Letzte Messung vor X Tagen" with the real timestamp.
                staging[kind] = result.derived
                // V053-D2 universal sparkline: even outsideRange data
                // makes a useful chart. Hydrate from the full series
                // (not just inRange — which is empty here).
                if summaryHasEmptySparkline(for: kind), !result.measurements.isEmpty {
                    hydrateSparkline(for: kind, from: result.measurements)
                }
            default:
                break
            }
        }
    }

    /// AUD-7 H2 — concurrency cap for the series-fallback fan-out. Mirrors
    /// `AppContainer.prefetchFanoutConcurrency` / the compliance fan-out window.
    static let seriesFallbackConcurrency = 4

    /// AUD-7 H2 — pure (nonisolated) per-kind series fetch + state derivation,
    /// run inside the bounded task group. Returns `nil` on fetch failure or an
    /// empty series so the caller leaves the wide-page-derived state intact
    /// (identical to the serial path's `continue`).
    private nonisolated static func deriveSeriesFallback(
        kind: MetricKind,
        measurementsRepo: MeasurementsRepository,
        rangeDays: Int,
        now: Date,
        sessionLease: AuthenticatedSessionLease
    ) async -> SeriesFallbackResult? {
        let series: MeasurementSeries
        do {
            try sessionLease.requireCurrent()
            series = try await measurementsRepo.series(kind: kind, days: rangeDays)
            try sessionLease.requireCurrent()
        } catch {
            guard sessionLease.isCurrent else { return nil }
            let detail = LogSanitizer.redact(String(describing: error))
            HLLog.api.warning("Dashboard series fallback failed for \(kind.rawValue, privacy: .private): \(detail, privacy: .private)")
            return nil
        }
        guard !series.points.isEmpty else { return nil }
        let measurements = ChartDetailStore.measurementsFromSeriesPoints(series.points, kind: kind)
        let cutoff = now.addingTimeInterval(-Double(rangeDays) * 86400)
        let inRange = measurements.filter { $0.recordedAt >= cutoff }
        let derived = MetricDataState.derive(
            allSamples: measurements,
            inRange: inRange,
            sourceFilterApplied: false
        )
        return SeriesFallbackResult(kind: kind, derived: derived, measurements: measurements)
    }

    /// **V051B B2 fix.** Rewrites `summary.metrics[kind].sparkline` with
    /// `primaryComponent`-extracted values from `inRange` measurements (in
    /// chronological order, oldest → newest, matching the existing
    /// summary-emitted sparkline convention). No-op when summary is nil or
    /// the kind isn't present in `summary.metrics` — synthesized placeholder
    /// tiles for layout-visible kinds that the server didn't surface get
    /// hydrated in-place by `synthesiseMissingTiles` first, then this fills
    /// their sparkline. `MeasurementsRepository.deriveState` returns
    /// `inRange` sorted desc-by-`recordedAt`; we reverse to asc so the
    /// sparkline reads left-to-right by time, same as the summary path.
    func hydrateSparkline(for kind: MetricKind, from inRange: [Measurement]) {
        guard let current = summary, !inRange.isEmpty else { return }
        // Route via `MetricSeriesProjection.project(_:kind:)` so BP unpaired-DIA
        // artefacts (systolic == 0) drop out — REG-11.
        let values = MetricSeriesProjection.project(inRange, kind: kind)
        var didReplace = false
        let updatedMetrics: [DashboardMetric] = current.metrics.map { metric in
            guard metric.kind == kind else { return metric }
            didReplace = true
            return DashboardMetric(
                id: metric.id,
                kind: metric.kind,
                title: metric.title,
                latestValue: metric.latestValue,
                secondaryValue: metric.secondaryValue,
                unit: metric.unit,
                trend: metric.trend,
                sparkline: values,
                updatedAt: metric.updatedAt
            )
        }
        guard didReplace else { return }
        summary = DashboardSummary(
            greeting: current.greeting,
            compliance: current.compliance,
            highlightInsight: current.highlightInsight,
            metrics: updatedMetrics,
            lastUpdated: current.lastUpdated
        )
    }

    /// `true` when the server's `/api/measurements/series` endpoint
    /// supports the kind. `bodyTemperature` is HK-write-only and the
    /// server returns 422 for it — see `MeasurementsRepository.seriesKindKey`
    /// + `TrendsOverlayStore.availableMetrics` for the canonical list.
    ///
    /// **v0.5.2 F2** — the three server-backed F2 additions
    /// (`restingHeartRate`, `hrv`, `vo2Max`) route through the series
    /// endpoint once the server's zod schema picks them up. The four
    /// iOS-local F2 additions (`walkingSpeed`, `walkingAsymmetry`,
    /// `walkingStepLength`, `bmi`) stay `false` — tiles render from the
    /// HK-cached sparkline only until the server adds those enum cases.
    static func kindSupportsSeries(_ kind: MetricKind) -> Bool {
        switch kind {
        case .bodyTemperature, .walkingSpeed, .walkingAsymmetry, .walkingStepLength, .walkingDoubleSupport,
             .walkingSteadiness,
             .respiratoryRate, .audioExposureEnvironment, .audioExposureHeadphone, .bmi,
             // v0.8.3 W-D — server persists these rows but `/api/measurements/series`
             // doesn't accept them yet (kindEnum 422); detail renders from the list
             // page + HK cache until the server widens the series schema.
             .activeEnergy, .flightsClimbed, .distanceWalkingRunning, .timeInDaylight,
             // v0.11 W21 — server/Withings-sourced web-parity kinds; series
             // endpoint doesn't accept them, so the tile reads off the list/HK cache.
             .fatFreeMass, .leanBodyMass, .muscleMass, .skinTemperature,
             .pulseWaveVelocity, .vascularAge, .visceralFat, .walkingHeartRate,
             .fatMass,
             // v0.13.1 IC — v1.10.0 additive signals: series endpoint doesn't
             // accept them; tile reads off the list page + HK cache.
             .falls, .sixMinuteWalk, .stairAscentSpeed, .stairDescentSpeed,
             .breathingDisturbances, .cardioRecovery, .wristTemperature,
             // v0.14.6 — v1.12.8 WHOOP-native types: no series endpoint.
             .averageHeartRate, .maxHeartRate, .sleepDisturbanceCount,
             // v0.14.1 W-B189 — v1.17.1 source-fixed signals (#23): no series
             // endpoint; tile reads off the list page + HK cache.
             .ansCharge, .cardioLoad, .sleepScore, .bodyTemperatureDeviation,
             // v0158 — v1.25 clinical types: no series endpoint (server
             // `surfaces.detailPage == false`); tile reads off the list page.
             .painNRS, .gripStrength, .waistCircumference, .waistToHeight,
             // Build 3 / item 3.3 — the 21 read-only decoder catch-up types:
             // no series endpoint; tile reads off the list page.
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
}
