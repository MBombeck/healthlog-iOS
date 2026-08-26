import SwiftUI

/// W52 (v0.11 overview rework) — the **Vitals at a glance** block on the
/// Insights overview, the iOS twin of the web `VitalsDashboard`
/// (`src/components/insights/derived/vitals-dashboard.tsx`).
///
/// **Why this exists:** the web overview renders a dedicated vital-signs
/// summary section — the key vitals at a glance, each with its latest value +
/// trend. The iOS overview folded vitals into the generic `InsightsTargetTile
/// Grid` (which is driven by the user's CONFIGURED *targets*, not by the vital
/// SIGNS), so a vital the user tracks but hasn't set a target for never
/// surfaced at a glance. This block closes that gap: it reads the same
/// `DashboardSummary.metrics` the dashboard tiles already read (NO new server
/// contract) and renders one compact tile per available vital sign.
///
/// **Web parity contract (`SECTION_VITALS`):** the web charts resting HR / HRV
/// / respiratory rate / SpO₂ / body temperature / blood glucose / weight. This
/// block mirrors that set in the same order, dropping any vital the user has no
/// reading for. Each tile = the metric icon + label, the latest value + unit
/// (big mono), the monochrome `TrendChip` (direction-only, polarity-aware), and
/// an inline `HLSparkline` of the server's daily-rollup series — exactly the
/// grammar of the web `SparklineDeltaTile`.
///
/// **What iOS does NOT mirror (deferred — documented in the W52 report):** the
/// web tiles also carry DERIVED re-frames (personal-typical-range band,
/// cardio-fitness age, vascular-age delta, HRV balance band, BMI category).
/// Those read the web-only `/api/insights/derived` route, which iOS does not
/// consume. Fabricating a "typical range" client-side would be dishonest, so
/// the iOS tile surfaces the honest latest-value + trend + series only. BMI
/// already has its own dedicated overview card.
///
/// **On-device ((A) — survives standalone):** the dashboard summary is part of
/// the W2 read-union, so this block renders in BOTH the paired and standalone
/// paths. It is pure data — no AI gate, no glass, monochrome.
///
/// **Self-suppression:** when no vital sign carries a value the whole section
/// renders NOTHING (no header, no shell, no apologetic empty card) — matching
/// the web's per-tile data-availability gate collapsing the section.
struct InsightsVitalsDashboard: View {
    /// The dashboard summary metrics (kind / latestValue / unit / trend /
    /// sparkline). Sourced from `DashboardStore.summary?.metrics` at the call
    /// site — the same array the dashboard tiles + target grid already read, so
    /// this block costs no extra round-trip.
    let metrics: [DashboardMetric]
    /// W5-1 (v0.12 W5a) — kinds already rendered by the `InsightsTargetTileGrid`
    /// (the operator's configured *targets*). The overview must show each metric
    /// EXACTLY ONCE: a vital that already lives as a target tile (e.g. weight,
    /// resting-HR) is dropped from this Vitals block so the two surfaces never
    /// double-render the same graphic. Defaults to empty (previews / non-grid
    /// hosts render every vital). The target grid is the canonical home for a
    /// metric the user configured a target for; the Vitals block carries the
    /// rest (HRV / SpO₂ / temp / respiratory / glucose) at-a-glance.
    var excludedKinds: Set<MetricKind> = []
    /// Tap handler — pushes that vital's `InsightsMetricScreen` chart detail.
    /// nil → tiles render but aren't tappable (preview).
    let onSelect: ((MetricKind) -> Void)?
    /// v0.14.1 D — the app container, threaded so each at-a-glance vital tile can
    /// re-attach the "pin to home" long-press affordance the v0.14 redesign
    /// dropped. `nil` (previews / tests) → the modifier is a no-op.
    var container: AppContainer?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Web `SECTION_VITALS` order, mapped onto the iOS `MetricKind` enum.
    /// `nonisolated` so the pure resolver can read it off the main actor in
    /// unit tests.
    private nonisolated static let vitalOrder: [MetricKind] = [
        .restingHeartRate,
        .hrv,
        .respiratoryRate,
        .spo2,
        .bodyTemperature,
        .glucose,
        .weight
    ]

    var body: some View {
        let tiles = Self.tiles(from: metrics, excluding: excludedKinds)
        // Self-suppress: no vital with a value → render nothing (calm doctrine).
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // One canonical header (sentence-case, monochrome) — matches the
                // web `insights.derived.vitals.sectionTitle` h2.
                InsightsSectionHeader(
                    "Vitals",
                    subtitle: "Your latest readings at a glance"
                )
                VStack(spacing: HLSpace.sm) {
                    ForEach(tiles) { tile in
                        card(for: tile)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(reduceMotion ? .identity : .opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("insights.vitals")
        }
    }

    // MARK: - Tile chrome

    @ViewBuilder
    private func card(for tile: VitalTile) -> some View {
        let body = HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: tile.symbol)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(tile.title)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Spacer(minLength: HLSpace.sm)
                    TrendChip(trend: tile.trend, polarity: tile.polarity)
                    Text(tile.valueText)
                        .font(.hlHeadline)
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                }
                if tile.series.count >= 2 {
                    // W6b (v0.12 W5a) — conform to the unified tile grammar
                    // (STANDARDS §7). Task #36 — route through the shared
                    // `HLTileMetricChart` (same `MetricChartContent` engine +
                    // inkGraphite ink as the metric's Insights page) so the
                    // Vitals block reads as the same chart material as the
                    // target-grid tiles below it AND the per-metric detail.
                    HLTileMetricChart(kind: tile.kind, values: tile.series)
                        .frame(height: 36)
                }
            }
        }
        if let onSelect {
            Button { onSelect(tile.kind) } label: { body }
                .hlPressable() // QOL-AUDIT H1: press feedback
                // v0.14.1 D — re-attach the pin affordance the redesign dropped:
                // every at-a-glance vital tile is long-press-pinnable to Home.
                .pinToHomeContextMenu(kind: tile.kind, container: container)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(tile.accessibilityLabel))
                .accessibilityHint(Text(String(localized: "Double-tap to open detail view")))
                .accessibilityIdentifier("insights.vital.\(tile.kind.rawValue)")
        } else {
            body
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(tile.accessibilityLabel))
        }
    }

    // MARK: - Pure tile resolution

    /// One resolved vital tile. `nonisolated` so the pure resolver below can be
    /// exercised off the main actor in unit tests.
    nonisolated struct VitalTile: Identifiable {
        let kind: MetricKind
        let title: String
        let symbol: String
        let valueText: String
        let trend: TrendIndicator
        let polarity: MetricKindDescriptor.TrendPolarity
        let series: [Double]
        let accessibilityLabel: String
        var id: String {
            kind.rawValue
        }
    }

    /// Build the ordered, value-bearing vital tiles from the dashboard metric
    /// pool. A vital with no `latestValue` is dropped (web parity: the tile only
    /// renders when the vital has a reading). `nonisolated static` so the
    /// self-suppress gate is unit-testable without instantiating the view.
    nonisolated static func tiles(
        from metrics: [DashboardMetric],
        excluding excludedKinds: Set<MetricKind> = []
    ) -> [VitalTile] {
        let byKind = Dictionary(metrics.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        return vitalOrder.compactMap { kind -> VitalTile? in
            // W5-1 — a vital already shown as a configured-target tile is dropped
            // here so the overview renders the metric exactly once.
            guard !excludedKinds.contains(kind) else { return nil }
            guard let metric = byKind[kind], let latest = metric.latestValue else { return nil }
            let descriptor = kind.descriptor
            let title = String(localized: descriptor.title)
            let unit = metric.unit.isEmpty ? String(localized: descriptor.unitLabel) : metric.unit
            let value = latest.formatted(.number.precision(.fractionLength(0 ... 1)))
            let valueText = unit.isEmpty ? value : "\(value) \(unit)"
            return VitalTile(
                kind: kind,
                title: title,
                symbol: descriptor.sfSymbol,
                valueText: valueText,
                trend: metric.trend,
                polarity: descriptor.trendPolarity,
                series: metric.sparkline,
                accessibilityLabel: "\(title), \(valueText)"
            )
        }
    }
}

// MARK: - W5-5 derived re-frames block

/// W5-5 (v0.12 W5b) — the **derived re-frames** block on the Insights overview,
/// the iOS twin of the web `vitals-dashboard.tsx` derived tiles +
/// `wellness-scores.tsx`. Consumes `GET /api/insights/derived` (via
/// `DerivedInsightsStore`) and surfaces the server-computed wellness scores +
/// age/HRV re-frames, each with the award-tier transparency envelope the web
/// shows: a coverage/confidence chip + a "computed from your last N days,
/// <source> buckets · as of <date>" provenance line + the metric's honesty
/// caveat.
///
/// **HONEST-ONLY (load-bearing).** This block renders ONLY the `status: "ok"`
/// envelopes the server returns — never a band or score fabricated on-device.
/// `insufficient` / 404 / 422 metrics are absent (the store's `presentable`
/// drops them); when nothing is presentable the whole block self-suppresses
/// (`EmptyView`). The earlier `InsightsVitalsDashboard` doc-comment that
/// "fabricating a typical range client-side would be dishonest, so iOS ships
/// latest-value+trend only" is now resolved: the typical range / re-frames are
/// surfaced HONESTLY from the server's own compute, never invented.
///
/// **Server-derived.** Pure server compute, no on-device fallback — the call
/// site gates the block on `BackendAvailability.hasServer` so it hides in
/// standalone / no-server. Monochrome, no glass, reduce-motion-gated.
struct InsightsDerivedBlock: View {
    /// The `status: "ok"` derived envelopes to render, ordered for display
    /// (sourced from `DerivedInsightsStore.presentable`).
    let metrics: [DerivedMetricDTO]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The text-card metrics this block still owns (the non-ring-promoted ones).
    /// The ring/gauge/count IDs are dropped here so the overview shows each
    /// score EXACTLY once. v0.14.9 §2 — every tile-able derived score is now
    /// ring-promoted (Recovery / Stress + Vascular age + HRV balance), so this
    /// set is EMPTY today and the whole "More from your data" lane self-suppresses
    /// (no heading, no card). The block stays as the single-source-of-truth dedup
    /// partner + a safety-net for any FUTURE unpromoted derived metric: the
    /// promoted set is owned by `InsightsScoreCardsBlock` (the block that actually
    /// renders the rings), so no ID can appear twice or vanish.
    private var textMetrics: [DerivedMetricDTO] {
        metrics.filter { !InsightsScoreCardsBlock.ringPromotedIDs.contains($0.metric) }
    }

    var body: some View {
        if !textMetrics.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader(
                    "More from your data",
                    subtitle: "Computed from your own data — with the inputs and method shown"
                )
                VStack(spacing: HLSpace.sm) {
                    ForEach(textMetrics, id: \.metric) { metric in
                        card(for: metric)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(reduceMotion ? .identity : .opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("insights.derived")
        }
    }

    // MARK: - Derived metric card

    @ViewBuilder
    private func card(for metric: DerivedMetricDTO) -> some View {
        let title = Self.title(for: metric.metric)
        let headline = Self.headline(for: metric)
        let caveat = Self.caveat(for: metric)
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack(spacing: HLSpace.sm) {
                    Text(title)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    Spacer(minLength: HLSpace.sm)
                    if let confidence = metric.confidence {
                        // Award-tier transparency: the confidence band chip
                        // (mono, label-only — no colored pill).
                        Text(Self.bandLabel(confidence.band))
                            .font(.hlCaption.weight(.semibold))
                            .foregroundStyle(HLText.secondary)
                            .accessibilityLabel(
                                Text("Confidence \(Self.bandLabel(confidence.band))")
                            )
                    }
                }
                if let headline {
                    Text(headline)
                        .font(.hlBody.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(HLText.primary)
                }
                // Whoop/Oura-tier "vs your baseline" trend — the server-computed
                // `trendDelta` for the wellness scores. Server-returned only;
                // self-suppresses when absent (no prior window). Monochrome.
                if let trend = Self.trendLine(for: metric) {
                    Text(trend)
                        .font(.hlCaption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(HLText.secondary)
                }
                // Provenance line — the "from your last N days · <source> data ·
                // as of <date>" transparency chip (web `ProvenanceExplainer`).
                Text(Self.provenanceLine(for: metric.provenance))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                // Coverage nudge — only when an input is still missing.
                if !metric.coverage.missing.isEmpty {
                    Text("Track these to sharpen this: \(Self.inputList(metric.coverage.missing))")
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
                if let caveat {
                    Text(caveat)
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pure resolvers (nonisolated for unit tests)

    /// Localized display title per derived metric id (web parity copy).
    nonisolated static func title(for metric: String) -> String {
        switch metric {
        // v0.14.1 §4 — clearer, "wertig" wellness names. "Readiness"/"Strain"
        // were unclear (operator feedback); renamed to plain "daily condition /
        // daily load". EN+DE in Localizable.xcstrings.
        case "READINESS": String(localized: "Daily condition")
        case "SLEEP_SCORE": String(localized: "Sleep score")
        case "RECOVERY_SCORE": String(localized: "Recovery")
        case "STRESS_SCORE": String(localized: "Stress")
        case "STRAIN_SCORE": String(localized: "Daily load")
        case "FITNESS_AGE": String(localized: "Cardio fitness")
        case "VASCULAR_AGE_DELTA": String(localized: "Vascular age")
        case "HRV_BALANCE": String(localized: "HRV balance")
        default: metric
        }
    }

    /// The headline value for a metric — a 0–100 score for composites, the
    /// re-frame sentence for the age/HRV metrics. HONEST-ONLY: returns `nil`
    /// (no headline rendered) when the server value carries no presentable
    /// field — never a fabricated number.
    nonisolated static func headline(for metric: DerivedMetricDTO) -> String? {
        guard let value = metric.value else { return nil }
        switch metric.metric {
        case "READINESS", "SLEEP_SCORE", "RECOVERY_SCORE", "STRESS_SCORE", "STRAIN_SCORE":
            return value.score.map { "\(Int($0.rounded())) / 100" }
        case "FITNESS_AGE":
            return fitnessHeadline(value.fitnessAgeDeltaYears)
        case "VASCULAR_AGE_DELTA":
            return vascularHeadline(value.deltaYears)
        case "HRV_BALANCE":
            return hrvHeadline(value.band)
        default:
            return value.score.map { "\(Int($0.rounded())) / 100" }
        }
    }

    /// The "vs your baseline" trend line for the wellness scores — the server's
    /// `trendDelta` (latest score minus the trailing-window mean). HONEST-ONLY:
    /// only the three persisted wellness scores carry it, and only when the
    /// server returned a non-nil delta; everything else / a `nil` delta yields
    /// no line (never a fabricated trend).
    nonisolated static func trendLine(for metric: DerivedMetricDTO) -> String? {
        switch metric.metric {
        case "RECOVERY_SCORE", "STRESS_SCORE", "STRAIN_SCORE":
            break
        default:
            return nil
        }
        guard let delta = metric.value?.trendDelta, let mag = Int(safeServer: abs(delta)) else { return nil }
        if mag == 0 {
            return String(localized: "Level with your recent baseline")
        }
        return delta > 0
            ? String(localized: "+\(mag) vs your recent baseline")
            : String(localized: "−\(mag) vs your recent baseline")
    }

    /// FITNESS_AGE re-frame sentence (web `vitals.fitness*` copy).
    nonisolated static func fitnessHeadline(_ years: Double?) -> String {
        guard let years, years != 0, let mag = Int(safeServer: abs(years)) else {
            return String(localized: "Cardio fitness typical for your age")
        }
        return years < 0
            ? String(localized: "Cardio fitness of someone ~\(mag) yr younger")
            : String(localized: "Cardio fitness ~\(mag) yr above your age")
    }

    /// VASCULAR_AGE_DELTA re-frame sentence (web `vitals.vascular*` copy).
    nonisolated static func vascularHeadline(_ years: Double?) -> String {
        guard let years, years != 0, let mag = Int(safeServer: abs(years)) else {
            return String(localized: "In line with your age")
        }
        return years < 0
            ? String(localized: "\(mag) yr below your age")
            : String(localized: "\(mag) yr above your age")
    }

    /// HRV_BALANCE band sentence (web `vitals.hrvBand.*` copy).
    nonisolated static func hrvHeadline(_ band: String?) -> String? {
        switch band {
        case "balanced": String(localized: "Balanced for you")
        case "unbalanced": String(localized: "Above your usual range")
        case "low": String(localized: "Below your usual range")
        default: nil
        }
    }

    /// **W-B187 #29 — provenance-aware honesty caveat.**
    ///
    /// RECOVERY_SCORE flips between a WHOOP-native recovery and the computed HRV
    /// proxy server-side (v1.17 W2b). The static `caveat(for:)` copy hardcodes the
    /// computed-proxy framing, which is WRONG once the server resolves a
    /// WHOOP-native value. This overload reads the server-resolved source from the
    /// envelope and returns the honest caveat for that source; every other metric
    /// delegates unchanged to the string-keyed resolver.
    nonisolated static func caveat(for dto: DerivedMetricDTO) -> String? {
        guard dto.metric == "RECOVERY_SCORE" else { return caveat(for: dto.metric) }
        if WellnessScorePresentation.isWhoopNativeRecovery(dto) {
            return String(localized: "From your WHOOP recovery — descriptive, not a clinical recovery measure.")
        }
        return caveat(for: dto.metric)
    }

    /// The honesty caveat per metric (web `*.caveat` copy). `nil` for metrics
    /// the web does not caveat. RECOVERY_SCORE here is the COMPUTED-proxy framing;
    /// the provenance-aware ``caveat(for:)-(DerivedMetricDTO)`` overload swaps in
    /// the WHOOP-native wording when the server resolved a WHOOP recovery.
    nonisolated static func caveat(for metric: String) -> String? {
        switch metric {
        case "READINESS": String(localized: "A wellness proxy, not a recovery or clinical score.")
        case "RECOVERY_SCORE": String(localized: "A descriptive wellness proxy, not a training-grade or clinical recovery measure.")
        case "STRESS_SCORE": String(
                localized: "An HRV-derived proxy, NOT an EDA / galvanic-skin stress measurement — your watch has no EDA sensor. Descriptive, not clinical."
            )
        case "STRAIN_SCORE": String(localized: "A descriptive activity-load proxy, not a clinical or training-grade load measure.")
        // GH-Standard R4 — die vier Geschwister oben grenzen jeweils gegen
        // eine KONKURRIERENDE Kategorie ab (WHOOP-Recovery, trainingsreife
        // Last, EDA-Sensorik) und korrigieren damit eine sonst unkorrigierbare
        // Erwartung. Hier gab es keine solche Kategorie — "beschreibend, keine
        // klinische Gefaessbewertung" war die allgemeine Formel, die seit
        // v0.19.0 einmalig beim Start bestaetigt wird
        // (`disclaimer.ack.intro.body`) und nicht auf jeder Flaeche wiederholt
        // gehoert. Was bleibt, ist die Herkunft — und die ist hier die
        // eigentliche Auskunft: die Zahl kommt vom Geraet, nicht von uns.
        case "VASCULAR_AGE_DELTA": String(
                localized: "Your device's own estimate — HealthLog only re-frames it, it does not compute it."
            )
        default: nil
        }
    }

    /// **W-B187 #29 — provenance-aware "Was ist Erholung?" explainer.**
    ///
    /// The static `whatIs(for:)` recovery copy describes the COMPUTED proxy
    /// ("read mainly from your heart-rate variability"). When the server resolves
    /// a WHOOP-native recovery, that description is wrong; this overload reads the
    /// server-resolved source and returns the matching explainer. Every other
    /// metric delegates unchanged to the string-keyed resolver.
    nonisolated static func whatIs(for dto: DerivedMetricDTO) -> String? {
        guard dto.metric == "RECOVERY_SCORE" else { return whatIs(for: dto.metric) }
        if WellnessScorePresentation.isWhoopNativeRecovery(dto) {
            return String(
                localized: "How well your body has bounced back, taken straight from your WHOOP recovery."
            )
        }
        return whatIs(for: dto.metric)
    }

    /// v0.14.1 §6 — "Was ist [Metrik]?" explainer body: WHAT the metric IS
    /// (plain-language definition), NOT how it's computed. Replaces the boring
    /// "Server-computed from your own data" line on the score-detail sheet. EN+DE
    /// in Localizable.xcstrings. `nil` → the sheet omits the explainer body and
    /// falls back to the existing caveat. RECOVERY_SCORE here is the
    /// COMPUTED-proxy framing; the provenance-aware
    /// ``whatIs(for:)-(DerivedMetricDTO)`` overload swaps in the WHOOP-native
    /// wording when the server resolved a WHOOP recovery.
    nonisolated static func whatIs(for metric: String) -> String? {
        switch metric {
        case "READINESS": String(localized: "How ready your body looks for the day, blended from your resting heart rate, HRV and sleep.")
        case "SLEEP_SCORE": String(localized: "A single 0–100 read on last night's sleep — its length, depth and how settled it was.")
        case "RECOVERY_SCORE": String(
                localized: "How well your body has bounced back, read mainly from your heart-rate variability versus your own baseline."
            )
        case "STRESS_SCORE": String(
                localized: "An HRV-derived read of physiological load — how taxed your nervous system looks compared with your calm baseline."
            )
        case "STRAIN_SCORE": String(
                localized: "How much physical load you put on your body today, from your activity and elevated heart rate."
            )
        case "FITNESS_AGE": String(localized: "What your cardio fitness (VO₂max) suggests your body's age is, compared with your real age.")
        case "VASCULAR_AGE_DELTA": String(
                localized: "What your blood-pressure pattern suggests your arteries' age is, compared with your real age."
            )
        case "HRV_BALANCE": String(localized: "Whether your heart-rate variability is sitting in, above or below your own usual range.")
        default: nil
        }
    }

    /// "Was ist [Metrik]?" heading for the explainer — pairs the localized metric
    /// title into a question. EN+DE.
    nonisolated static func whatIsTitle(for metric: String) -> String {
        String(localized: "What is \(title(for: metric))?")
    }

    /// Localized confidence-band label (`high/medium/low/draft`).
    nonisolated static func bandLabel(_ band: String) -> String {
        switch band {
        case "high": String(localized: "High confidence")
        case "medium": String(localized: "Medium confidence")
        case "low": String(localized: "Low confidence")
        case "draft": String(localized: "Provisional")
        default: band
        }
    }

    /// The provenance transparency line: "From your last N days · <source> data".
    nonisolated static func provenanceLine(for provenance: DerivedMetricDTO.Provenance) -> String {
        let source = Self.sourceLabel(provenance.source)
        return String(localized: "From your last \(provenance.windowDays) days · \(source) data")
    }

    /// Human granularity label for the provenance `source`.
    nonisolated static func sourceLabel(_ source: String) -> String {
        switch source {
        case "DAY": String(localized: "daily")
        case "WEEK": String(localized: "weekly")
        case "MONTH": String(localized: "monthly")
        case "YEAR": String(localized: "yearly")
        case "live": String(localized: "live")
        default: source.lowercased()
        }
    }

    /// Comma-joins missing-input identifiers for the coverage nudge.
    nonisolated static func inputList(_ inputs: [String]) -> String {
        inputs.joined(separator: ", ")
    }
}
