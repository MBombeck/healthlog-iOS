import SwiftUI

/// v0.6.1.1 (handbook drift D-013 close) — tile grid for the Ziele-
/// Metric surface on the Insights tab. Composes a small number of
/// `InsightsTargetTile` instances out of the `InsightsTargetsStore`
/// targets array, pairing the two Mood metrics (`MOOD_SCORE` +
/// `MOOD_STABILITY`) into a half-width row per operator instruction
/// ("Mood + Mood-Stabilität in einer Kachel die jeweils nur halb breit
/// ist").
///
/// **Sparkline source:** `DashboardStore.summary.metrics` already
/// carries a 7-day sparkline per `MetricKind` (server-aggregated daily
/// rollups). We map the API target type strings to a `MetricKind` lookup
/// and pull the sparkline from there. When the dashboard summary has
/// not landed yet, the tile renders the value + range badge but the
/// sparkline collapses to the empty branch.
///
/// **Order:** matches handbook §3.4 — Gewicht / Ruhepuls full-width,
/// Mood + Mood-Stabilität half-width pair, Steps + Compliance
/// full-width. The order locks behind `fixedOrder` so a future server
/// payload reshuffle doesn't accidentally re-order the visual rhythm.
struct InsightsTargetTileGrid: View {
    let targets: [InsightsTargetsResponseDTO.TargetItem]
    let dashboardMetrics: [DashboardMetric]
    /// v0.8.0 W10 — server-first tile order + visibility (was `@AppStorage`).
    /// The layout's tile-id slugs map to the iOS catalogue types via
    /// `InsightsLayoutTileId`; the store is the authority on order + hide.
    let layout: InsightsLayout
    /// v0.8.1 WB — iOS-local intra-mood-pair order (`MOOD_SCORE` /
    /// `MOOD_STABILITY`). Both halves share the `stimmung` server slug, so the
    /// left/right order of the pair is a device-local UI-pref.
    let moodHalfOrder: [String]
    /// v0.8.2 W1a (B1) — opens the native customise path from the empty-state
    /// escape hatch when every tile is hidden but the operator still has
    /// targets with data.
    let onAddTiles: () -> Void
    /// v0.10.0 W-Insights (R2 Phase B) — true when the on-device assistant is
    /// configured (feature-flag on). Drives whether the `✦` AI affordance
    /// renders in metric-shaped tiles. Defaults `false` so previews + non-AI
    /// builds stay pure data.
    var aiConfigured: Bool = false
    /// v0.10.0 — fired by a tile's `✦` with the metric kind to explain; the
    /// parent presents `MetricAIExplainerSheet`. nil → no `✦` (kept decoupled
    /// so the grid never owns sheet state — the screen does).
    var onAIExplainer: ((MetricKind) -> Void)?

    /// v0.6.1.10 Y9-B — needed so each tile's tap-row builds a
    /// `ChartDetailStore` and pushes `ChartDetailScreen` on the parent
    /// `NavigationStack`. Forwarded from `InsightsScreen` which already
    /// reads `@Environment(\.appContainer)`. When unavailable (Preview),
    /// the tile renders as a plain non-tappable card.
    @Environment(\.appContainer) private var appContainer

    /// Server target-type → fallback display order, used only when the
    /// layout carries no opinion (fresh install before the GET lands).
    /// BLOOD_PRESSURE and BMI are excluded from this grid — they keep their
    /// dedicated `BPStatusCard` / `BMICard` full-width hero cards.
    private static let fixedOrder: [String: Int] = [
        "WEIGHT": 0,
        "PULSE": 1, // pulse may not be a target; we still show resting HR via RESTING_HR if available
        "RESTING_HR": 1,
        "MOOD_SCORE": 2,
        "MOOD_STABILITY": 3,
        "ACTIVITY_STEPS": 4,
        "MEDICATION_COMPLIANCE": 5
    ]

    /// Pairing rule — these two render as half-width tiles side-by-side
    /// in one HStack row. Other metrics keep the full-width column.
    /// `nonisolated` so the pure `span(forType:)` helper can read it from a
    /// nonisolated context (the layout-math unit tests).
    private nonisolated static let moodPair: Set<String> = ["MOOD_SCORE", "MOOD_STABILITY"]

    var body: some View {
        // v0.8.1 WB — ONE span-aware grid holds every visible tile: the mood
        // halves render `.half` (side-by-side), the rest `.full`. Visibility
        // still comes from the server-first layout (the `stimmung` slug gates
        // both mood halves) AND the auto-hide-empty data gate.
        let visibleItems = orderedVisibleItems

        if visibleItems.isEmpty {
            // B1 (v0.8.2 W1a) — distinguish "empty because every tile is
            // hidden" (operator-recoverable trap) from "empty because no
            // target carries data" (humane silence). When there ARE targets
            // with data but the layout hid them all, show the escape-hatch
            // card so the operator can re-add tiles without finding a tile to
            // long-press. Otherwise render nothing (no shouting).
            if hasHiddenItemsWithData {
                TileGridEmptyState(onAddTiles: onAddTiles)
            }
        } else {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                // Section header to anchor the grid in the screen rhythm.
                InsightsSectionHeader("Your targets")

                // v0.8.7 W-NATIVE-REORDER — native static span-aware layout.
                // The custom UICollectionView jiggle-reorder engine is gone
                // (it broke four times; the home-screen jiggle is not a public
                // Apple API). The mood pair (`MOOD_SCORE`/`MOOD_STABILITY`)
                // renders as two `.half` tiles side-by-side in an `HStack`;
                // every other target is `.full` (whole row). Reorder / add /
                // remove now lives in the native `SettingsInsightsCustomization
                // Screen` (List + .onMove + visibility toggles).
                ForEach(Array(packedRows(visibleItems).enumerated()), id: \.offset) { _, row in
                    if row.count == 2 {
                        HStack(spacing: HLSpace.md) {
                            ForEach(row, id: \.type) { target in
                                tile(for: target, compact: true)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    } else if let target = row.first {
                        tile(for: target, compact: Self.moodPair.contains(target.type))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// v0.8.7 W-NATIVE-REORDER — packs the ordered visible items into rows for
    /// the native static layout: consecutive `.half` items pair into a
    /// two-tile row, every `.full` item is its own row. Reuses the existing
    /// span classification (`span(forType:)`) so the packing matches the
    /// behaviour the `TileFlowLayoutTests` already pin.
    private func packedRows(
        _ items: [InsightsTargetsResponseDTO.TargetItem]
    ) -> [[InsightsTargetsResponseDTO.TargetItem]] {
        var rows: [[InsightsTargetsResponseDTO.TargetItem]] = []
        var pendingHalf: InsightsTargetsResponseDTO.TargetItem?
        for item in items {
            if Self.span(forType: item.type) == .half {
                if let pending = pendingHalf {
                    rows.append([pending, item])
                    pendingHalf = nil
                } else {
                    pendingHalf = item
                }
            } else {
                if let pending = pendingHalf {
                    rows.append([pending])
                    pendingHalf = nil
                }
                rows.append([item])
            }
        }
        if let pending = pendingHalf { rows.append([pending]) }
        return rows
    }

    /// v0.8.1 WB — column span per catalogue type. Mood halves are `.half`
    /// (side-by-side); every other target is `.full` (whole row).
    ///
    /// `nonisolated` so the pure span math is callable from the synchronous,
    /// nonisolated `TileFlowLayoutTests` context (adding the `onAddTiles`
    /// closure stored property nudged the View's main-actor inference onto its
    /// statics; pinning this pure helper nonisolated keeps the test call legal).
    nonisolated static func span(forType type: String) -> TileSpan {
        moodPair.contains(type) ? .half : .full
    }

    /// v0.8.0 W10 — a catalogue type is visible when its mapped server-layout
    /// tile is visible. Types the layout doesn't track (no server slug) fall
    /// through to visible so a forward-compat tile still renders.
    private func isTypeVisible(_ type: String) -> Bool {
        guard let slug = InsightsLayoutTileId.serverId(forCatalogueType: type) else { return true }
        guard let tile = layout.tiles.first(where: { $0.id == slug }) else { return true }
        return tile.visible
    }

    /// v0.6.1.10 Y9-D1 — single data-presence gate. A tile is considered
    /// "without data" when the API target carries no `current` value AND
    /// no historical 30-day average. Either signal counts as enough
    /// content to keep the tile in the grid.
    static func hasData(_ target: InsightsTargetsResponseDTO.TargetItem) -> Bool {
        target.current != nil || target.average30 != nil
    }

    /// v0.8.1 WB — the single flat ordered + visible item array driving the
    /// span-aware grid. ALL tiles (mood halves + full-width targets) live here,
    /// projected onto the server-first layout order. When the layout positions
    /// the `stimmung` slug, the two mood halves expand inline at that slot in
    /// the iOS-local `moodHalfOrder` (left/right). Visibility = layout-visible
    /// AND has-data. Targets the layout doesn't position fall to the tail in
    /// the canonical `fixedOrder` so a fresh install still renders sensibly.
    private var orderedVisibleItems: [InsightsTargetsResponseDTO.TargetItem] {
        let candidates = targets.filter { Self.fixedOrder[$0.type] != nil }
        let byType: [String: InsightsTargetsResponseDTO.TargetItem] = Dictionary(
            candidates.map { ($0.type, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var ordered: [InsightsTargetsResponseDTO.TargetItem] = []
        var placed: Set<String> = []

        func appendMoodHalves() {
            for type in moodHalfTypesInOrder where !placed.contains(type) {
                if let target = byType[type] { ordered.append(target) }
                placed.insert(type)
            }
        }

        for tile in layout.orderedTiles {
            if tile.id == InsightsLayoutTileId.mood {
                appendMoodHalves()
                continue
            }
            for (type, target) in byType
                where InsightsLayoutTileId.serverId(forCatalogueType: type) == tile.id
                && !Self.moodPair.contains(type)
                && !placed.contains(type)
            {
                ordered.append(target)
                placed.insert(type)
            }
        }
        // Mood halves not positioned by the layout yet → still surface them.
        if !placed.contains("MOOD_SCORE") || !placed.contains("MOOD_STABILITY") {
            appendMoodHalves()
        }
        // Candidates the layout doesn't position yet → canonical tail order.
        let leftovers = candidates
            .filter { !placed.contains($0.type) }
            .sorted { lhs, rhs in
                let lhsOrder = Self.fixedOrder[lhs.type] ?? 100
                let rhsOrder = Self.fixedOrder[rhs.type] ?? 100
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.type < rhs.type
            }
        let resolved = (ordered + leftovers)
            .filter { isTypeVisible($0.type) }
        // A3 (v0.8.3) — keep the mood pair ATOMIC through the has-data filter.
        // Root cause of "half tiles gone": the per-item `hasData` filter could
        // drop ONE mood half (e.g. MOOD_SCORE has a reading, MOOD_STABILITY
        // doesn't) and leave a LONE `.half` — which packs as a half tile with
        // an empty column beside it and reads as "no half pair". Worse, if the
        // store delivered only one mood target the pair never rendered side by
        // side. Treat the pair as one unit: when EITHER half has data and the
        // `stimmung` slug is visible, keep BOTH (the dataless half shows "—"),
        // so the half-width pair always renders as designed.
        return Self.keepingMoodPairAtomic(resolved)
    }

    /// A3 — applies the has-data filter while keeping the mood pair atomic: if
    /// either mood half survives the has-data gate, both halves stay (so the
    /// side-by-side `.half` layout never collapses to a lone half / vanishes).
    /// Every non-mood tile keeps the plain per-item has-data gate.
    private static func keepingMoodPairAtomic(
        _ items: [InsightsTargetsResponseDTO.TargetItem]
    ) -> [InsightsTargetsResponseDTO.TargetItem] {
        let moodHasData = items.contains { moodPair.contains($0.type) && hasData($0) }
        return items.filter { item in
            if moodPair.contains(item.type) { return moodHasData }
            return hasData(item)
        }
    }

    /// B1 (v0.8.2 W1a) — true when the grid would be empty ONLY because the
    /// operator hid every tile (not because no target has data). Drives the
    /// empty-state escape hatch: a candidate that carries data but resolves to
    /// hidden via the layout means the operator can recover by re-adding it.
    private var hasHiddenItemsWithData: Bool {
        targets.contains { target in
            Self.fixedOrder[target.type] != nil
                && Self.hasData(target)
                && !isTypeVisible(target.type)
        }
    }

    /// The two mood half types in their iOS-local left/right order — the
    /// operator's persisted `moodHalfOrder`, falling back to score-then-
    /// stability when unset / incomplete.
    private var moodHalfTypesInOrder: [String] {
        let known: Set = ["MOOD_SCORE", "MOOD_STABILITY"]
        let persisted = moodHalfOrder.filter { known.contains($0) }
        let missing = ["MOOD_SCORE", "MOOD_STABILITY"].filter { !persisted.contains($0) }
        return persisted + missing
    }

    @ViewBuilder
    private func tile(
        for target: InsightsTargetsResponseDTO.TargetItem,
        compact: Bool
    ) -> some View {
        let tileView = InsightsTargetTile(
            iconSystemName: icon(for: target.type),
            title: LocalizedStringKey(label(for: target.type)),
            titleText: InsightsTileDisplay.localizedTitle(forCatalogueType: target.type),
            valueText: valueText(for: target),
            unitText: compact ? nil : unitText(for: target),
            sparkline: sparkline(for: target.type),
            trend: InsightsTargetTile.Trend.resolve(
                apiTrend: target.trend,
                lowerIsBetter: lowerIsBetter(for: target.type)
            ),
            inTargetState: InsightsTargetTile.InTargetState.resolve(
                consistency7d: target.consistency7d,
                insufficient: target.insufficientData,
                hasRange: target.range != nil
            ),
            supportLine: compact ? nil : supportLine(for: target),
            range: compact ? nil : rangeBand(for: target),
            compact: compact,
            onAIExplainer: aiExplainerHandler(for: target.type)
        )

        // v0.6.1.10 Y9-B — tiles whose API type maps to a `MetricKind`
        // wrap in a NavigationLink that pushes `ChartDetailScreen` onto
        // the parent stack.
        //
        // v0.6.2.9 Y10.8-C5/C6/C7 — Mood / Stability / Compliance now
        // push their own auxiliary chart-detail destinations
        // (`InsightsAuxChartDetailScreen.swift`) so every tile in the
        // grid reacts to a tap, not just the metric-shaped ones.
        if let kind = Self.kindForChartDetail(target.type), let container = appContainer {
            NavigationLink {
                // W1 Fix 3 — single AppContainer factory. The Insights tile
                // grid previously omitted `liveTodayStepsProvider`, so a
                // `.steps` chart opened from here showed the frozen server
                // snapshot for today's bar; the factory wires it consistently.
                // W36/#22 — chart-detail cutover: target tiles drill into the
                // web-mirror per-metric screen (bottom-period control), matching
                // the tab + every other Insights chart entry point.
                InsightsMetricScreen(
                    kind: kind,
                    store: container.makeChartDetailStore(kind: kind)
                )
            } label: {
                tileView
            }
            .hlPressable() // QOL-AUDIT H1: press feedback
            .accessibilityIdentifier("insights.tile.\(target.type)")
            .accessibilityHint(Text(String(localized: "Double-tap to open detail view")))
        } else if Self.hasAuxDestination(target.type) {
            NavigationLink {
                auxDestination(for: target.type)
            } label: {
                tileView
            }
            .hlPressable() // QOL-AUDIT H1: press feedback
            .accessibilityIdentifier("insights.tile.\(target.type)")
            .accessibilityHint(Text(String(localized: "Double-tap to open detail view")))
        } else {
            tileView
                .accessibilityIdentifier("insights.tile.\(target.type)")
        }
    }

    /// v0.6.2.9 Y10.8-C5/C6/C7 — server target-type → auxiliary
    /// chart-detail destination. Returns `true` for the three tile
    /// types that don't map onto a `MetricKind` but still deserve a
    /// chart-detail-style drill-in: Stimmung, Stabilität, Compliance.
    static func hasAuxDestination(_ type: String) -> Bool {
        switch type {
        case "MOOD_SCORE", "MOOD_STABILITY", "MEDICATION_COMPLIANCE": true
        default: false
        }
    }

    /// Routes the Mood / Stability / Compliance tile-tap to the
    /// matching auxiliary screen. Pre-condition: `hasAuxDestination`
    /// already returned `true` for the same type.
    @ViewBuilder
    private func auxDestination(for type: String) -> some View {
        switch type {
        case "MOOD_SCORE":
            InsightsAuxMoodDetailScreen()
        case "MOOD_STABILITY":
            InsightsAuxMoodStabilityDetailScreen()
        case "MEDICATION_COMPLIANCE":
            InsightsAuxComplianceDetailScreen()
        default:
            // Unreachable — `hasAuxDestination` gates this branch.
            EmptyView()
        }
    }

    /// v0.6.1.10 Y9-B — server target-type → `MetricKind` so a tap on a
    /// Ziele-Metric tile can push `ChartDetailScreen` with the matching
    /// metric. Mirrors `InsightsScreen.tileGridCoveredKinds` exactly so
    /// the long-tail "Weitere Werte" block stays in sync. Types without
    /// a `ChartDetailScreen` counterpart (`MOOD_SCORE`, `MOOD_STABILITY`,
    /// `MEDICATION_COMPLIANCE`) return `nil` — those tiles stay
    /// non-tappable for now.
    ///
    /// `nonisolated` (v0.10.0) so the pure `aiExplainerKind(...)` gate +
    /// its unit tests can call it from a synchronous nonisolated context.
    nonisolated static func kindForChartDetail(_ type: String) -> MetricKind? {
        switch type {
        case "WEIGHT": .weight
        case "PULSE": .pulse
        case "RESTING_HR": .restingHeartRate
        case "ACTIVITY_STEPS": .steps
        case "BODY_FAT": .bodyFat
        case "SLEEP_DURATION": .sleep
        default: nil
        }
    }

    // MARK: - Per-type formatting

    /// Sparkline lookup — maps the server target-type string to a
    /// `MetricKind` so we can read the 7-day daily-bucket array from the
    /// dashboard summary. For metrics that don't have a `MetricKind`
    /// counterpart (`MOOD_SCORE`, `MOOD_STABILITY`, `MEDICATION_COMPLIANCE`),
    /// we fall back to an empty array and the sparkline row collapses to
    /// the `HLSparkline` empty-hairline branch.
    private func sparkline(for type: String) -> [Double] {
        let kind: MetricKind? = switch type {
        case "WEIGHT": .weight
        case "RESTING_HR": .restingHeartRate
        case "PULSE": .pulse
        case "ACTIVITY_STEPS": .steps
        case "BODY_FAT": .bodyFat
        default: nil
        }
        guard let kind, let metric = dashboardMetrics.first(where: { $0.kind == kind }) else {
            return []
        }
        return metric.sparkline
    }

    /// v0.10.0 W-Insights (R2 §3.1) — build the BP-style normalcy band for a
    /// ranged target. Returns `nil` when no range is configured or the window
    /// is insufficient (no in-band claim possible), so the tile omits the band
    /// exactly like BP does when `targets == nil`. The in-range percentage is
    /// derived from the server's `daysInRange30d / daysLogged30d` tally — the
    /// same density signal the context line already surfaces.
    private func rangeBand(for target: InsightsTargetsResponseDTO.TargetItem) -> RangeBand? {
        Self.rangeBand(
            range: target.range,
            insufficient: target.insufficientData,
            daysInRange30d: target.daysInRange30d,
            daysLogged30d: target.daysLogged30d,
            unit: target.unit,
            type: target.type
        )
    }

    /// Pure helper — `nonisolated static` so the pct math + band gating is
    /// unit-testable without instantiating the grid.
    nonisolated static func rangeBand(
        range: InsightsTargetsResponseDTO.TargetItem.Range?,
        insufficient: Bool,
        daysInRange30d: Int,
        daysLogged30d: Int,
        unit: String,
        type: String
    ) -> RangeBand? {
        guard let range, !insufficient, daysLogged30d > 0 else { return nil }
        let inRange = max(0, min(daysInRange30d, daysLogged30d))
        let pct = Int((Double(inRange) / Double(daysLogged30d) * 100).rounded())
        let decimals = switch type {
        case "ACTIVITY_STEPS", "PULSE", "RESTING_HR", "MEDICATION_COMPLIANCE": 0
        default: 1
        }
        let lower = range.min.formatted(.number.precision(.fractionLength(0 ... decimals)))
        let upper = range.max.formatted(.number.precision(.fractionLength(0 ... decimals)))
        return RangeBand(
            lowerLabel: lower,
            upperLabel: upper,
            unit: unit.isEmpty ? nil : unit,
            pctInRange: pct
        )
    }

    /// v0.10.0 W-Insights (R2 Phase B) — per-tile `✦` handler. Returns a
    /// closure ONLY for metric-shaped tiles (those that map onto a
    /// `MetricKind`, so the on-device `TrendObservationsService` has a series
    /// to read) AND only when the assistant is configured + the parent wired a
    /// presenter. Aux tiles (Mood / Stability / Compliance) and a missing
    /// presenter → nil → no `✦`, pure data.
    private func aiExplainerHandler(for type: String) -> (() -> Void)? {
        guard let kind = Self.aiExplainerKind(for: type, aiConfigured: aiConfigured),
              let onAIExplainer else { return nil }
        return { onAIExplainer(kind) }
    }

    /// Pure gate — `nonisolated static` so the `✦`-eligibility contract is
    /// unit-testable. Returns the metric kind to explain ONLY for
    /// metric-shaped tiles when the assistant is configured; aux tiles (Mood /
    /// Stability / Compliance) and an unconfigured assistant → nil (no `✦`).
    nonisolated static func aiExplainerKind(for type: String, aiConfigured: Bool) -> MetricKind? {
        guard aiConfigured else { return nil }
        return kindForChartDetail(type)
    }

    private func icon(for type: String) -> String {
        InsightsTileDisplay.systemImage(forCatalogueType: type)
    }

    private func label(for type: String) -> String {
        InsightsTileDisplay.title(forCatalogueType: type)
    }

    /// Lower-is-better polarity drives the trend-chip colour. Weight +
    /// Ruhepuls + Mood-Stabilität (closer to 0 deviation is better, but
    /// the API delivers a stability % where higher is better — careful)
    /// — review: WEIGHT, RESTING_HR are lower-is-better; MOOD_SCORE,
    /// MOOD_STABILITY, ACTIVITY_STEPS, MEDICATION_COMPLIANCE are
    /// higher-is-better.
    private func lowerIsBetter(for type: String) -> Bool {
        switch type {
        case "WEIGHT", "RESTING_HR", "PULSE": true
        case "MOOD_SCORE", "MOOD_STABILITY", "ACTIVITY_STEPS", "MEDICATION_COMPLIANCE": false
        case "SLEEP_DURATION",
             "BODY_FAT": false // weight loss frames body fat as "lower better" too, but server already encodes polarity via the trend
        // marker on its end
        default: false
        }
    }

    private func valueText(for target: InsightsTargetsResponseDTO.TargetItem) -> String {
        guard let current = target.current else { return "—" }
        let decimals = switch target.type {
        case "ACTIVITY_STEPS", "PULSE", "RESTING_HR", "MEDICATION_COMPLIANCE": 0
        case "MOOD_SCORE", "MOOD_STABILITY": 1
        default: 1
        }
        // v0.7.1 M-2 — `Double.formatted(.number…)` instead of allocating a
        // `NumberFormatter` per tile per render (the idiom the rest of the
        // chart code uses). 0…`decimals` fraction digits, grouping only for
        // step counts, current locale — behaviour-identical to the former
        // NumberFormatter config.
        return formatDecimal(current, maxFractionDigits: decimals, grouped: target.type == "ACTIVITY_STEPS")
    }

    /// Locale-aware decimal formatter shared by `valueText` / `supportLine`.
    /// Value-type `FormatStyle` — no per-render allocation, no shared mutable
    /// `NumberFormatter` state. Minimum 0 fraction digits, up to
    /// `maxFractionDigits`, optional grouping separators.
    private func formatDecimal(_ value: Double, maxFractionDigits: Int, grouped: Bool) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(0 ... maxFractionDigits))
                .grouping(grouped ? .automatic : .never)
        )
    }

    private func unitText(for target: InsightsTargetsResponseDTO.TargetItem) -> String? {
        // Hide units for metrics where the support line carries
        // the context anyway (Mood scores).
        switch target.type {
        case "MOOD_SCORE", "MOOD_STABILITY": nil
        default: target.unit.isEmpty ? nil : target.unit
        }
    }

    private func supportLine(for target: InsightsTargetsResponseDTO.TargetItem) -> String? {
        // v0.7.0 W-API-RENDER — the server already computes a 30-day
        // in-range / logged tally (`daysInRange30d` / `daysLogged30d`) that
        // the UI silently dropped. When the target carries a range we now
        // lead the support line with "23 von 30 Tagen im Zielbereich" so the
        // operator reads adherence-density, not just the 30-day average.
        // Without a range there is no in-band claim to make, so we fall back
        // to the average-only line as before.
        let inRangeLine = daysInRangeLine(for: target)

        guard let avg = target.average30 else { return inRangeLine }
        let avgText = formatDecimal(avg, maxFractionDigits: 1, grouped: target.type == "ACTIVITY_STEPS")
        let unit = target.unit
        let avgLine = unit.isEmpty
            ? String(localized: "30-day avg \(avgText)")
            : String(localized: "30-day avg \(avgText) \(unit)")

        guard let inRangeLine else { return avgLine }
        // Both signals fit on one caption line — separated by the middle dot
        // already used elsewhere in the digest copy.
        return "\(inRangeLine) · \(avgLine)"
    }

    /// v0.7.0 W-API-RENDER — "23 von 30 Tagen im Zielbereich" from the
    /// server's `daysInRange30d`. Returns `nil` when the target has no range
    /// configured (no in-band claim is possible) or when nothing was logged
    /// in the window (avoids a misleading "0 von 30").
    private func daysInRangeLine(for target: InsightsTargetsResponseDTO.TargetItem) -> String? {
        Self.daysInRangeLine(
            hasRange: target.range != nil,
            insufficient: target.insufficientData,
            daysInRange30d: target.daysInRange30d,
            daysLogged30d: target.daysLogged30d
        )
    }

    /// Pure helper — `nonisolated static` so the "X von 30 Tagen" gating +
    /// clamping can be unit-tested without instantiating the grid. Returns
    /// `nil` (no line) when there's no range, the window is insufficient, or
    /// nothing was logged. The in-range count is clamped to 0…30 so a
    /// malformed server payload can never render "31 von 30".
    nonisolated static func daysInRangeLine(
        hasRange: Bool,
        insufficient: Bool,
        daysInRange30d: Int,
        daysLogged30d: Int
    ) -> String? {
        guard hasRange, !insufficient else { return nil }
        guard daysLogged30d > 0 else { return nil }
        let inRange = max(0, min(daysInRange30d, 30))
        return String(localized: "\(inRange) of 30 days in range")
    }
}
