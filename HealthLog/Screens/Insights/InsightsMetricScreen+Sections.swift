import SwiftUI

/// Section blocks + target-band helpers backing `InsightsMetricScreen` — the
/// header with its (i), 30-day status card, correlation, Letzte-Messung,
/// sleep-hypnogram row, chart block, range delta and the target-item plumbing,
/// moved verbatim out of `InsightsMetricScreen.swift` so the screen file stays
/// under SwiftLint's `file_length` ceiling (pure code movement, no behavior
/// change). Members the screen file references flip from `private` to
/// internal; helpers used only here stay `private`.
extension InsightsMetricScreen {
    // MARK: - Header (#33 — mirrors InsightsScreen.insightsHeader)

    /// In-content per-metric header, the same `HLTabHeader` as the overview
    /// and the special pages: the metric title, the actions in one glass group.
    var metricHeader: some View {
        HLTabHeader(
            LocalizedStringResource(String.LocalizationValue(kind.displayName)),
            titleIdentifier: "insights.page.header.title.\(kind.rawValue)",
            actions: metricHeaderActions
        )
    }

    /// The header's one glass group in the fixed order: the (i) with the
    /// explainer and references, the target range when the metric has an
    /// editable band, the coach while its capability is open (the sheet
    /// routes on-device or server itself).
    private var metricHeaderActions: HLTabHeaderActions {
        var items: [HLTabHeaderAction] = [
            .info(
                InsightsMetricInfo.content(for: kind, showsCorrelation: correlationPanel != nil),
                identifier: "insights.metric.info.\(kind.rawValue)"
            )
        ]
        if canEditTargetBand {
            items.append(.settings(
                label: "Adjust target range",
                identifier: "insights.metric.targetEdit.\(kind.rawValue)"
            ) {
                presentTargetEditor = true
            })
        }
        if appContainer.offersCoach {
            items.append(.coach(identifier: "insights.metric.coach.\(kind.rawValue)") {
                presentAskCoach = true
            })
        }
        return HLTabHeaderActions(items)
    }

    // MARK: - 30 Tage Durchschnitt status card (C4 — ONE canonical card)

    /// The **ONE canonical "30 Tage Durchschnitt" status card** for
    /// EVERY metric. Replaces the old `kind == .bloodPressure` fork (rich
    /// `BPStatusCard` for BP vs thin `InsightsPrimaryTile` for everything else)
    /// with a single `InsightsMetricStatusCard` driven by a pure descriptor.
    ///
    /// A **"30 Tage Durchschnitt" section heading** sits above the card; the
    /// in-card avg hint was removed (C2 — redundant under the heading). The card
    /// self-suppresses entirely when the descriptor carries no signal, so the
    /// heading only renders when there IS a card beneath it — a sparse metric
    /// reads as a clean heading + chart, no empty section, no empty chip.
    @ViewBuilder
    var statusBlock: some View {
        let descriptor = statusDescriptor
        if descriptor.hasAnyContent {
            // The assessment of the page: status, the 30-day average as a
            // fact row, the in-range rail. No heading of its own, the card
            // follows the figure it qualifies.
            InsightsMetricStatusCard(descriptor: descriptor)
                // v0.14.1 D — the canonical 30-day card is the tile the
                // operator long-presses to pin to Home.
                .pinToHomeContextMenu(kind: kind, container: appContainer)
        }
    }

    /// Whether the 30-day status card has anything to show.
    var hasStatusCard: Bool {
        statusDescriptor.hasAnyContent
    }

    /// The pure descriptor for the canonical status card, built from the server
    /// digest + this metric's targets row + the latest charted reading. The
    /// builder enforces the honest-only contract (each slot self-suppresses
    /// without server signal) and the per-kind source split (BP digest fields,
    /// BMI WHO classification, generic metrics from the targets payload).
    private var statusDescriptor: InsightsMetricStatusCard.Descriptor {
        InsightsMetricStatusDescriptor.build(
            kind: kind,
            digest: insightsStore.digest,
            target: statusTargetItem,
            latestValue: store.latestPoint?.value,
            // The same in-range chart values the detail chart draws
            // (`displaySeries` → `recentInRange` fallback), so the card's
            // target-less Verlauf matches the line below for non-targeted kinds.
            sparklineValues: store.chartPoints.map(\.value),
            // The headline, its unit and the target band read in the
            // account's unit, with glucose pinned to the series' unit.
            units: store.effectiveUnits(settingsStore.unitPreferences),
            serverAverage30: serverAverage30
        )
    }

    // MARK: - Blood pressure stats (systolic over diastolic)

    /// One row of the blood pressure statistic under its heading, for the
    /// stacked ``HLStatGrid`` (Systolic over Diastolic). The stats convert to
    /// the account's unit; the label flips mmHg to kPa.
    func bloodPressureStatsSection(
        title: String,
        stats: SeriesStats?,
        median: Double?,
        units: UnitPreferences
    ) -> HLStatGrid.Section {
        HLStatGrid.Section(
            title: title,
            cells: StatsRow(
                stats: stats,
                median: median,
                unit: store.displayUnit(units: units),
                kind: kind,
                units: units
            ).cells
        )
    }

    // MARK: - Correlation (I-1 D — relocated cross-metric combo card)

    /// The cross-metric correlation pair(s) this metric OWNS, relocated off the
    /// overview onto the page they concern:
    ///   • Blutdruck → Weight × blood pressure
    ///   • Puls → Mood × heart rate
    ///   • Gewicht → Mood × weight
    /// (Mood × BP and BP × medication-compliance live on the Mood + Medications
    /// special pages respectively.) Renders only when the server digest carries
    /// an ok pairing for this metric — otherwise nothing (no empty card).
    private var correlationPairs: Set<CorrelationPair> {
        switch kind {
        case .bloodPressure: [.weightBp]
        case .pulse: [.moodPulse]
        case .weight: [.moodWeight]
        default: []
        }
    }

    /// The per-metric Coach circle hands off this page's
    /// metric (a localized opener + wire scope so the first server turn narrows the
    /// snapshot). A correlation card overrides both with the pair-specific
    /// seed/scope it set before presenting. `coachScopeSource == nil` (a metric
    /// with no server scope source) falls back to the default all-source snapshot.
    var askCoachSheet: some View {
        AskCoachSheet(
            seed: coachSeedOverride ?? AskCoachSheet.metricSeed(for: kind),
            launchScope: coachScopeOverride ?? kind.coachScopeSource.map { CoachLaunchScope(metric: $0) }
        )
    }

    /// The correlation panel this page shows, `nil` when it owns no pairing
    /// with a signal. The (i) asks too: it explains the card only when it is
    /// on the page.
    var correlationPanel: CorrelationsPanel? {
        let pairs = correlationPairs
        guard !pairs.isEmpty, let digest = insightsStore.digest else { return nil }
        // Each correlation card carries an "Ask the coach about
        // this" link that opens the canonical AskCoachSheet pre-scoped to both
        // metrics in the pair (same sheet the per-page coach circle opens; it
        // self-gates the arm / placeholder per user).
        let panel = CorrelationsPanel(
            digest: digest,
            pairs: pairs,
            onAskCoach: { pair in
                coachSeedOverride = pair.coachSeed
                coachScopeOverride = pair.coachLaunchScope
                presentAskCoach = true
            }
        )
        return panel.hasAnyCard ? panel : nil
    }

    @ViewBuilder
    var correlationBlock: some View {
        if let panel = correlationPanel {
            // 1.0.3 (App Review 1.4.1 / ruling R12) — the panel's own
            // "Associations, not causes." reading instruction and its Sources
            // link now render unconditionally whenever a correlation card does.
            // They used to hang off a `showsDisclaimer` flag that this call site
            // and both others passed `false`, so neither reached a screen; the
            // flag is gone, and there is nothing here to opt into any more.
            Group {
                // The right-aligned "How your metrics relate …"
                // subtext was removed (declutter).
                // `flush: true` drops the header's `HLSpace.xs`
                // inset so its leading edge sits flush with the unpadded
                // correlation prose below — matching the Einschätzung /
                // Letzte-Messung left edge (symmetry).
                HLSectionHeader("Relationships", rank: .area)
                panel
            }
        }
    }

    // MARK: - Letzte Messung (I-1 B — dedicated latest-reading card)

    /// The dedicated **"Letzte Messung"** block — a section heading above the
    /// EXISTING `HeroStrip` (the operator's "the existing last-measurement tile":
    /// the latest value + unit + delta chip on one line, the weekday+day+time
    /// below it, and the server 7/30/90-day up/down trend slopes). v0.14.1 §5
    /// replaces the former bespoke `InsightsLastMeasurementCard`
    /// (the wrong card) — the canonical template reuses the HeroStrip tile and
    /// adds ONLY a "Letzte Messung" heading above it. Self-suppresses with no
    /// latest point so a fresh metric reads as a clean heading + chart.
    @ViewBuilder
    var lastMeasurementBlock: some View {
        if store.latestPoint != nil {
            Group {
                HLSectionHeader("Last measurement", rank: .area)
                // W36/#22 — forward the presenting screen's matched-geometry
                // namespace (Dashboard) so the hero number stays the tile→detail
                // zoom-morph destination; `nil` on the pager/tile surfaces falls
                // through to the `HeroStrip` no-op branch.
                HeroStrip(store: store, matchedNamespace: matchedNamespace)
            }
        }
    }

    // MARK: - Sleep hypnogram entry (#124 — sleep-only)

    /// A tappable row into ``SleepHypnogramScreen`` (stage bands over the night),
    /// shown ONLY on the sleep metric page. Defaults the detail to the server's
    /// MOST-RECENT night by passing NO date — the old
    /// `store.latestPoint?.at` day-key was a sleep-SAMPLE instant in the device
    /// tz that missed the server's wake-day/server-tz night key (→ empty/422 →
    /// "konnte nicht geladen werden"). With no date the server returns the latest
    /// reconstructed night directly. Pushed via the SAME `NavigationLink` pattern
    /// `DrillDownRow` uses (no new navigation system).
    @ViewBuilder
    var sleepHypnogramRow: some View {
        if kind == .sleep {
            HLCard(layout: .rows) {
                HLSettingsActionRow(
                    icon: "chart.bar.xaxis",
                    title: "sleep.hypnogram.entry.title",
                    subtitle: "sleep.hypnogram.entry.subtitle",
                    presents: .push
                ) {
                    SleepHypnogramScreen()
                }
                .accessibilityIdentifier("insights.metric.sleep.hypnogram")
            }
        }
    }

    // MARK: - Sleep derived block (parity 4.7 — sleep-only)

    /// Sleep debt / chronotype / average-per-night + the multi-night stage
    /// composition chart, mirroring the web sleep page's card row and stacked
    /// bar (`W/src/app/insights/sleep/page.tsx:98-147`). Sits directly under
    /// the single-night hypnogram entry so the page reads night → recent
    /// nights → rhythm, i.e. narrowest span first. Self-suppresses for every
    /// other metric; the block owns its own load and empty states.
    @ViewBuilder
    var sleepDerivedBlock: some View {
        if kind == .sleep {
            // The composition chart follows the page's period control.
            SleepInsightsBlock(rangeDays: store.range.rawValue)
        }
    }

    // MARK: - Intraday pulse block (P7 — pulse-only)

    /// The day curve — one local day's 10-minute mean pulse with the personal
    /// resting reference and a backwards day navigator. Mirrors the web pulse
    /// page, which renders `<IntradayPulseChart>` DIRECTLY under the main chart
    /// (`W/src/app/insights/pulse/page.tsx:163-166`), so the page reads
    /// "the range → this day".
    ///
    /// Pulse-only: every other metric page never constructs the block and
    /// therefore never fires the read. The block owns its own load + states
    /// from there.
    @ViewBuilder
    var intradayPulseBlock: some View {
        if IntradayPulseBlock.isAvailable(for: kind) {
            IntradayPulseBlock()
        }
    }

    // MARK: - Same-time baseline (CU-30 — cumulative metrics only)

    /// "Wie sonst um diese Zeit" — today's running total against the operator's
    /// own typical standing at the SAME hour of day. Only the four cumulative
    /// types the server baselines construct it (steps / active energy /
    /// walking+running distance / flights), so no other metric page fires the
    /// read. Sits directly under the range chart, where the page narrows
    /// from "the range" to "today so far".
    @ViewBuilder
    var sameTimeBaselineBlock: some View {
        if let type = SameTimeBaselineBlock.supportedType(for: kind) {
            SameTimeBaselineBlock(type: type)
        }
    }

    // MARK: - ECG cross-link (P8 — pulse-only, data-gated)

    /// The pulse page's pointer to the ECG recordings (web `EcgCrossLink`,
    /// `pulse/page.tsx:182-186`).
    ///
    /// Shows only that recordings EXIST and what the RECORDING DEVICE last
    /// reported — never the curve, never a HealthLog reading. Un-mounts
    /// completely when the operator has no recordings (web
    /// `ecg-cross-link.tsx:27-30`), so the row can never be a dead tap.
    @ViewBuilder
    var ecgCrossLinkRow: some View {
        if kind == .pulse, ecgStore.hasRecordings {
            HLCard(layout: .rows) {
                HLSettingsActionRow(
                    icon: "waveform.path.ecg",
                    title: "insights.ecg.crossLink.title",
                    subtitle: LocalizedStringKey(ecgCrossLinkSubtitle),
                    presents: .push
                ) {
                    // Pushed over the pager, the page has no strip of its own.
                    InsightsEcgPage()
                        .environment(\.insightsInPager, false)
                }
                .accessibilityIdentifier("insights.metric.pulse.ecgCrossLink")
            }
        }
    }

    /// "N recordings on file. Latest device result: X." — the count plus the
    /// device's own last verdict, attributed. Never a summary of the traces.
    private var ecgCrossLinkSubtitle: String {
        let count = ecgStore.recordings.count
        let countLine = count == 1
            ? String(localized: "insights.ecg.crossLink.recordingsOne")
            : String(localized: "insights.ecg.crossLink.recordingsMany \(count)")
        guard let latest = ecgStore.latest, latest.classification != nil else { return countLine }
        let result = EcgPresentation.resultLabel(for: latest.verdict)
        return countLine + " " + String(localized: "insights.ecg.crossLink.latestResult \(result)")
    }

    // MARK: - 4. Chart block (reused primitives)

    var chartBlock: some View {
        // The `HeroStrip` moved UP into the canonical "Letzte
        // Messung" block (`lastMeasurementBlock`, position 4), so the chart block
        // is the chart alone. No duplicate hero.
        VStack(alignment: .leading, spacing: HLLayout.cardGap) {
            ChartCard(
                kind: kind,
                store: store,
                selectedDate: $selectedDate,
                // v0.14 light-mode walk: chart emphasis on refined graphite
                // (`inkGraphite` #2C2C2E light), matching the `HLChartTints.series`
                // default so on-screen chart ink reads softer than near-black text.
                emphasisTint: HLColor.inkGraphite,
                zoomNamespace: fullscreenZoomNamespace,
                zoomSourceID: Self.zoomSourceID,
                onTapChart: { presentFullscreenChart = true },
                // A chosen part of the day replaces the
                // whole-day change line with the part's name.
                rangeDelta: store.activePartOfDay == nil ? rangeDelta : nil,
                headline: coachReadHeadline,
                caption: store.activePartOfDay.map(ChartDetailStore.partOfDayCaption),
                summary: store.activePartOfDay == nil
                    ? MetricPeriodSummary.Model.resolve(store: store, units: settingsStore.unitPreferences)
                    : nil
            )
        }
    }

    // MARK: - Period-over-period delta (W5-3, self-suppresses)

    /// "vs prior <range>" caption from the already-loaded series (no new
    /// server contract), the chart card's one caption line since 1.4 B2.
    /// 1.5 VERDICTS — the series' own `change` with the server's verdict
    /// (`ChartDetailStore.rangeChange`); on a server before v1.43 the own
    /// comparison of the loaded points, neutral. Self-suppresses when there is
    /// nothing to show.
    private var rangeDelta: MetricRangeDelta? {
        guard let change = store.rangeChange else { return nil }
        switch change.basis {
        case .firstToLastDay:
            let units = store.effectiveUnits(settingsStore.unitPreferences)
            return MetricRangeDelta(
                source: .server(
                    delta: store.convertDelta(change.delta, units: units),
                    unit: store.displayUnit(units: units),
                    sentiment: change.sentiment ?? .neutral
                ),
                range: store.range
            )
        case .priorWindow:
            let units = store.effectiveUnits(settingsStore.unitPreferences)
            return MetricRangeDelta(
                source: .priorWindow(
                    delta: store.displayDelta(of: change, units: units),
                    unit: store.displayUnit(of: change, units: units),
                    trend: change.trend ?? .unknown
                ),
                range: store.range
            )
        case .priorHalf:
            guard let points = store.displaySeries?.points, !points.isEmpty else { return nil }
            return MetricRangeDelta(source: .ownComparison(points), range: store.range)
        }
    }

    // MARK: - Target item (drives the header gear + range-delta polarity)

    var targetItem: InsightsTargetsResponseDTO.TargetItem? {
        guard let type = MetricChartMath.targetType(for: kind) else { return nil }
        return insightsTargetsStore.target(forType: type)
    }

    /// The target row whose band the 30-day card may show: the row that
    /// describes THIS page's series (``MetricChartMath/bandTargetType(for:)``).
    /// The resting-pulse band (server type `PULSE`) lands on the resting heart
    /// rate page, never next to raw pulse.
    var statusTargetItem: InsightsTargetsResponseDTO.TargetItem? {
        guard let type = MetricChartMath.bandTargetType(for: kind) else { return nil }
        return insightsTargetsStore.target(forType: type)
    }

    // MARK: - Target-band edit (header gear, W22-W22 #2)

    /// The editable threshold metrics behind this metric's target type (empty →
    /// no editable band, e.g. derived mood/compliance/BMI targets).
    var editableTargetMetrics: [ThresholdMetric] {
        guard let item = targetItem else { return [] }
        return InsightsTargetBandEditorSheet.editableMetrics(forTargetType: item.type)
    }

    /// Current measured reference value(s) (30-day average) for the
    /// target editor's faint "Currently: …" hint, keyed by `metric.rawValue`.
    /// BP fans the systolic + diastolic averages onto their threshold metrics.
    var editorCurrentValues: [String: Double] {
        guard let item = targetItem else { return [:] }
        let diastolic = kind == .bloodPressure ? insightsTargetsStore.response?.bpDiastolic : nil
        var values: [String: Double] = [:]
        for metric in editableTargetMetrics {
            switch metric {
            case .bloodPressureDia:
                if let dia = diastolic?.average30 { values[metric.rawValue] = dia }
            default:
                if let avg = item.average30 { values[metric.rawValue] = avg }
            }
        }
        return values
    }

    /// The header gear shows ONLY when this metric has a target band AND that
    /// band is editable — otherwise the button self-suppresses (no dead button).
    private var canEditTargetBand: Bool {
        targetItem?.range != nil && !editableTargetMetrics.isEmpty
    }
}
