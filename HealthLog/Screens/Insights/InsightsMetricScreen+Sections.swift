import SwiftUI

/// Section blocks + target-band helpers backing `InsightsMetricScreen` — the
/// header, description, 30-day status card, correlation, Letzte-Messung,
/// sleep-hypnogram row, chart block, range delta and the target-item plumbing,
/// moved verbatim out of `InsightsMetricScreen.swift` so the screen file stays
/// under SwiftLint's `file_length` ceiling (pure code movement, no behavior
/// change). Members the screen file references flip from `private` to
/// internal; helpers used only here stay `private`.
extension InsightsMetricScreen {
    // MARK: - Header (#33 — mirrors InsightsScreen.insightsHeader)

    /// In-content per-metric header that mirrors the Übersicht header pattern
    /// EXACTLY: the metric title left-aligned, the two EQUAL-sized trailing
    /// circles (gear when an editable target band exists, then the `✦` Coach
    /// action), with the description rendered BELOW in the parent `VStack`.
    ///
    /// Both circles are the SAME `InsightsHeaderActionCircle` primitive — the
    /// monochrome, STATIC glass circle (the operator wanted the Coach to carry
    /// the same subtle static shimmer as the gear, "ohne dass sich das bewegt",
    /// not the moving brand-gradient coin). The Coach circle uses the `sparkles`
    /// SF Symbol; gear + Coach therefore share diameter AND treatment, so the
    /// per-metric + Übersicht headers can't drift apart.
    var metricHeader: some View {
        // DRIFT-2 — route through the canonical `InsightsPageHeader` so the
        // metric page shares ONE header primitive with the Mood / Medications /
        // Workouts pages (and the overview). The description renders BELOW via the
        // sibling `descriptionSlot`, so the subtitle slot stays nil here.
        InsightsPageHeader(
            LocalizedStringKey(kind.displayName),
            accessibilityIdentifierSuffix: kind.rawValue
        ) {
            // Gear — the shared equal-sized glass circle. Shown ONLY when this
            // metric carries an editable target band (no dead button).
            if canEditTargetBand {
                InsightsHeaderActionCircle(
                    systemImage: "slider.horizontal.3",
                    accessibilityLabelText: String(localized: "Adjust target range"),
                    accessibilityIdentifier: "insights.metric.targetEdit.\(kind.rawValue)"
                ) {
                    presentTargetEditor = true
                }
            }

            // `✦` Coach — the SAME monochrome, STATIC glass circle as the gear,
            // sitting INLINE to the RIGHT of the edit (gear) button. v0152 C4
            // (operator-confirmed): the inline coach button appears on EVERY
            // Insights metric page and ALWAYS opens the canonical `AskCoachSheet`,
            // which routes correctly per user (`prefersServerArm`): an
            // External-AI-selected user reaches the EXTERNAL web/server coach (never
            // silently on-device, never minting an on-device consent receipt — the
            // sheet surfaces the consent CTA when a server grant is still pending,
            // C3 `831665ec`); an on-device chooser keeps the on-device arm. It is
            // therefore shown unconditionally — the SHEET decides the arm, not this
            // button, so there is no longer a `.none`-mode hide or an on-device
            // assistant-insight fallback branch here.
            InsightsHeaderActionCircle(
                systemImage: "sparkles",
                accessibilityLabelText: String(localized: "Ask the coach"),
                accessibilityIdentifier: "insights.metric.coach.\(kind.rawValue)"
            ) {
                presentAskCoach = true
            }
            .hlPressable()
        }
    }

    // MARK: - Description slot (static web copy — self-suppresses)

    /// Renders the static web explainer paragraph for this metric. W2 ships only
    /// the slot: when `insights.metric.<rawvalue>.description` is absent or empty
    /// (the W5 copy hasn't landed), the slot renders nothing. We detect "key
    /// absent" by comparing the resolved string back to the key — a missing
    /// catalog entry resolves to the key verbatim.
    @ViewBuilder
    var descriptionSlot: some View {
        let resolved = descriptionText
        if let resolved, !resolved.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text(resolved)
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("insights.metric.description.\(kind.rawValue)")
                // A360-1 M2 — discreet "Learn more" pointer to the metric's
                // public /learn guide (mirrors the server's LearnMoreLink on the
                // Vitals / Glucose / metric detail). Self-suppresses for any
                // `MetricKind` the registry doesn't map (fail-closed).
                HLLearnMoreLink(concept: kind.rawValue)
            }
        } else {
            // Even when there's no static explainer copy yet, still surface the
            // learn pointer for the mapped metrics so the guide is reachable.
            HLLearnMoreLink(concept: kind.rawValue)
        }
    }

    private var descriptionText: String? {
        // I-0 Item 4 — prefer the ported web explainer body
        // (`insights.subPage.explainer.<slug>Body`, the canonical "Grundlage /
        // Was ist das?" copy) so the intro reads identically to the web sub-page.
        // It maps `MetricKind` → web slug (which differs from `rawValue`). Falls
        // back to the legacy `insights.metric.<rawvalue>.description` key for the
        // few kinds the web has no explainer for (`bodyFat`, `steps`).
        if let explainer = InsightsExplainer.resolve(for: kind) {
            return explainer.body
        }
        let key = "insights.metric.\(kind.rawValue).description"
        let resolved = String(localized: String.LocalizationValue(key))
        // No catalog entry → `String(localized:)` echoes the key back; treat
        // that (and an empty placeholder) as "no copy yet" → suppress.
        //
        // INVARIANT (W22-audit Finding #7): a `insights.metric.<rawvalue>.description`
        // key MUST carry real plain copy (no `%@` arguments) in BOTH EN+DE, or
        // omit the key entirely. The echo test below detects an absent key; the
        // `!resolved.isEmpty` guard in `descriptionSlot` catches an empty value.
        // Adding a key with an argument placeholder would break the echo test —
        // when wiring a new metric's description, add a plain string only.
        return resolved == key ? nil : resolved
    }

    // MARK: - 30 Tage Durchschnitt status card (C4 — ONE canonical card)

    /// v0.14.3 C4 — the **ONE canonical "30 Tage Durchschnitt" status card** for
    /// EVERY metric. Replaces the old `kind == .bloodPressure` fork (rich
    /// `BPStatusCard` for BP vs thin `InsightsPrimaryTile` for everything else)
    /// with a single `InsightsMetricStatusCard` driven by a pure descriptor.
    ///
    /// A **"30 Tage Durchschnitt" section heading** (C1) sits above the card; the
    /// in-card avg hint was removed (C2 — redundant under the heading). The card
    /// self-suppresses entirely when the descriptor carries no signal, so the
    /// heading only renders when there IS a card beneath it — a sparse metric
    /// reads as a clean heading + chart, no empty section, no empty chip.
    @ViewBuilder
    var statusBlock: some View {
        let descriptor = statusDescriptor
        if descriptor.hasAnyContent {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("30-day average", flush: true)
                InsightsMetricStatusCard(descriptor: descriptor)
                    // v0.14.1 D — the canonical 30-day card is the tile the
                    // operator long-presses to pin to Home.
                    .pinToHomeContextMenu(kind: kind, container: appContainer)
            }
        }
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
            target: targetItem,
            latestValue: store.latestPoint?.value,
            // v0.14.4 D1 — the same in-range chart values the detail chart draws
            // (`displaySeries` → `recentInRange` fallback), so the card's
            // target-less Verlauf matches the line below for non-targeted kinds.
            sparklineValues: store.chartPoints.map(\.value)
        )
    }

    // MARK: - BP derived context — pulse pressure + MAP (web v1.18.6 parity)

    /// Blood-pressure-only calm caption deriving **pulse pressure** and **mean
    /// arterial pressure** from the latest reading — the iOS mirror of the web
    /// v1.18.6 BP-detail "free derived context" line. Pure arithmetic on the
    /// systolic/diastolic the app already has (`latestPoint.value` /
    /// `latestPoint.secondary`); not a measurement, never written back.
    ///
    /// Self-suppresses for every non-BP metric and whenever the latest reading
    /// is missing or physiologically inverted (`BPDerivedReadout.derive` → nil),
    /// matching the web guard.
    @ViewBuilder
    var bpDerivedBlock: some View {
        if kind == .bloodPressure,
           let latest = store.latestPoint,
           let readout = BPDerivedReadout.derive(
               systolic: latest.value,
               diastolic: latest.secondary
           )
        {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text(String(
                    format: String(localized: "insights.bp.derived.pulsePressure"),
                    readout.pulsePressure
                ))
                Text(String(
                    format: String(localized: "insights.bp.derived.meanArterialPressure"),
                    readout.meanArterialPressure
                ))
                // UI-Standard R17 (U1) — Zuschreibung, kein Hinweis: dass
                // Pulsdruck und MAP aus der letzten Messung ABGELEITET und
                // nicht gemessen sind, ist eine Tatsache über die zwei Zahlen
                // darüber. Der „nicht als Diagnose"-Schwanz ist gefallen, und
                // mit ihm das Ack-Gate — eine Zuschreibung unterdrückt sich
                // nicht selbst.
                Text(String(localized: "insights.bp.derived.caveat"))
                    .foregroundStyle(HLText.tertiary)
            }
            // I1 — match the canonical metric-page explainer style (intro
            // `descriptionSlot` + Einschätzung `AssessmentBody` both use `.hlBody`).
            // The Pulsdruck/MAP caption previously rode `.hlSubhead`, a smaller
            // ramp that read as a different size/weight next to the prose.
            .font(.hlBody)
            .foregroundStyle(HLText.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Labelled stats row (I4 — BP systolic/diastolic)

    /// A `StatsRow` with a small caption above it, so the BP page can stack a
    /// labelled systolic row over a labelled diastolic row. Caption rides the
    /// canonical section-header ramp (`.hlCaption` semibold / `HLText.secondary`).
    /// `internal` (not `private`) so the call site in the main file's `scrollBody`
    /// can reach it across the file_length split.
    func labelledStatsRow(
        title: String,
        stats: SeriesStats?,
        median: Double?,
        units: UnitPreferences
    ) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(title)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
            // A360-5 C-1 — BP stats (both systolic + diastolic rows) convert to
            // the user's chosen unit; the label flips kg→lb / mmHg→kPa.
            StatsRow(
                stats: stats,
                median: median,
                unit: store.displayUnit(units: units),
                kind: kind,
                units: units
            )
        }
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

    /// **A360 H2 (v0156)** — the per-metric Coach circle hands off this page's
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

    @ViewBuilder
    var correlationBlock: some View {
        let pairs = correlationPairs
        if !pairs.isEmpty, backend.canShowCloudInsights, let digest = insightsStore.digest {
            // v0.14.3 D3 — the bottom "correlation ≠ causation" disclaimer was
            // removed (declutter); the per-metric block no longer opts in.
            // A360 H2 — each correlation card carries an "Ask the coach about
            // this" link that opens the canonical AskCoachSheet pre-scoped to both
            // metrics in the pair (same sheet the per-page coach circle opens; it
            // self-gates the arm / placeholder per user).
            let panel = CorrelationsPanel(
                digest: digest,
                pairs: pairs,
                showsDisclaimer: false,
                onAskCoach: { pair in
                    coachSeedOverride = pair.coachSeed
                    coachScopeOverride = pair.coachLaunchScope
                    presentAskCoach = true
                }
            )
            if panel.hasAnyCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    // v0.14.3 D2 — the right-aligned "How your metrics relate …"
                    // subtext was removed (declutter).
                    // v0.14.3 D4 — `flush: true` drops the header's `HLSpace.xs`
                    // inset so its leading edge sits flush with the unpadded
                    // correlation prose below — matching the Einschätzung /
                    // Letzte-Messung left edge (symmetry).
                    InsightsSectionHeader("Relationships", flush: true)
                    panel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            }
        }
    }

    // MARK: - Letzte Messung (I-1 B — dedicated latest-reading card)

    /// The dedicated **"Letzte Messung"** block — a section heading above the
    /// EXISTING `HeroStrip` (the operator's "the existing last-measurement tile":
    /// the latest value + unit + delta chip on one line, the weekday+day+time
    /// below it, and the server 7/30/90-day up/down trend slopes). v0.14.1 §5
    /// retired the bespoke `InsightsLastMeasurementCard` the reconcile agent built
    /// (the wrong card) — the canonical template reuses the HeroStrip tile and
    /// adds ONLY a "Letzte Messung" heading above it. Self-suppresses with no
    /// latest point so a fresh metric reads as a clean heading + chart.
    @ViewBuilder
    var lastMeasurementBlock: some View {
        if store.latestPoint != nil {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("Last measurement", flush: true)
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
    /// MOST-RECENT night by passing NO date (v0.14.3 E1) — the old
    /// `store.latestPoint?.at` day-key was a sleep-SAMPLE instant in the device
    /// tz that missed the server's wake-day/server-tz night key (→ empty/422 →
    /// "konnte nicht geladen werden"). With no date the server returns the latest
    /// reconstructed night directly. Pushed via the SAME `NavigationLink` pattern
    /// `DrillDownRow` uses (no new navigation system).
    @ViewBuilder
    var sleepHypnogramRow: some View {
        if kind == .sleep {
            NavigationLink {
                SleepHypnogramScreen()
            } label: {
                HLCard {
                    HStack(spacing: HLSpace.md) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.hlHeadline)
                            .foregroundStyle(HLText.primary)
                        VStack(alignment: .leading, spacing: HLSpace.xxs) {
                            Text("sleep.hypnogram.entry.title")
                                .font(.hlHeadline)
                                .foregroundStyle(HLText.primary)
                            Text("sleep.hypnogram.entry.subtitle")
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                        }
                        Spacer()
                        HLDisclosureChevron()
                    }
                }
            }
            .hlPressable() // QOL-AUDIT H1: press feedback
            .accessibilityIdentifier("insights.metric.sleep.hypnogram")
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
            SleepInsightsBlock()
        }
    }

    // MARK: - Intraday pulse block (P7 — pulse-only)

    /// The day curve — one local day's 10-minute mean pulse with the personal
    /// resting reference and a backwards day navigator. Mirrors the web pulse
    /// page, which renders `<IntradayPulseChart>` DIRECTLY under the main chart
    /// (`W/src/app/insights/pulse/page.tsx:163-166`), so the page reads
    /// "the range → this day".
    ///
    /// Double-gated on purpose: pulse-only (every other metric page never
    /// constructs the block and therefore never fires the read) AND
    /// `canShowCloudInsights`, because the day curve is pure server compute —
    /// in standalone / no-server there is nothing to ask for, so no round-trip
    /// and no empty shell. The block owns its own load + states from there.
    @ViewBuilder
    var intradayPulseBlock: some View {
        if IntradayPulseBlock.isAvailable(for: kind, canShowCloudInsights: backend.canShowCloudInsights) {
            IntradayPulseBlock()
        }
    }

    // MARK: - Same-time baseline (CU-30 — cumulative metrics only)

    /// "Wie sonst um diese Zeit" — today's running total against the operator's
    /// own typical standing at the SAME hour of day. Only the four cumulative
    /// types the server baselines construct it (steps / active energy /
    /// walking+running distance / flights), so no other metric page fires the
    /// read; and it is pure server compute, so it stays absent in standalone /
    /// no-server. Sits directly under the range chart, where the page narrows
    /// from "the range" to "today so far".
    @ViewBuilder
    var sameTimeBaselineBlock: some View {
        if let type = SameTimeBaselineBlock.supportedType(
            for: kind,
            canShowCloudInsights: backend.canShowCloudInsights
        ) {
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
        if kind == .pulse, backend.canShowCloudInsights, ecgStore.hasRecordings {
            NavigationLink {
                InsightsEcgPage()
            } label: {
                HLCard {
                    HStack(spacing: HLSpace.md) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.hlHeadline)
                            .foregroundStyle(HLText.primary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: HLSpace.xxs) {
                            Text("insights.ecg.crossLink.title")
                                .font(.hlHeadline)
                                .foregroundStyle(HLText.primary)
                            Text(ecgCrossLinkSubtitle)
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        HLDisclosureChevron()
                    }
                }
            }
            .hlPressable()
            .accessibilityIdentifier("insights.metric.pulse.ecgCrossLink")
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
        // v0.14.1 §5 — the `HeroStrip` moved UP into the canonical "Letzte
        // Messung" block (`lastMeasurementBlock`, position 4), so the chart block
        // is the chart alone. No duplicate hero.
        VStack(alignment: .leading, spacing: HLSpace.lg) {
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
                onTapChart: { presentFullscreenChart = true }
            )
        }
    }

    // MARK: - Period-over-period delta (W5-3, self-suppresses)

    /// W5-3 — "vs prior <range>" caption from the already-loaded series (no new
    /// server contract). Self-suppresses when `MetricRangeDelta.resolve` finds no
    /// coherent prior window. Target-band metrics pass `.neutral` (web rule).
    @ViewBuilder
    var rangeDeltaSlot: some View {
        if let points = store.displaySeries?.points, !points.isEmpty {
            MetricRangeDelta(
                points: points,
                polarity: targetItem?.range != nil ? .neutral : kind.descriptor.trendPolarity,
                range: store.range
            )
        }
    }

    // MARK: - Target item (drives the header gear + range-delta polarity)

    var targetItem: InsightsTargetsResponseDTO.TargetItem? {
        guard let type = MetricChartMath.targetType(for: kind) else { return nil }
        return insightsTargetsStore.target(forType: type)
    }

    // MARK: - Target-band edit (header gear, W22-W22 #2)

    /// The editable threshold metrics behind this metric's target type (empty →
    /// no editable band, e.g. derived mood/compliance/BMI targets).
    var editableTargetMetrics: [ThresholdMetric] {
        guard let item = targetItem else { return [] }
        return InsightsTargetBandEditorSheet.editableMetrics(forTargetType: item.type)
    }

    /// #32 — current measured reference value(s) (30-day average) for the
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
