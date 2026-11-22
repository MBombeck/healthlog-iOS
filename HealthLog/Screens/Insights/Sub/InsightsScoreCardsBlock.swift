import SwiftUI

// `WellnessRingPalette` + `WellnessRingShadow` moved to
// `WellnessRingPalette.swift`, and the per-card hide helpers + `HideScoreCardMenu`
// to `InsightsScoreCardsBlock+Visibility.swift`, to keep this file under the
// 600-line file-length budget after the show/hide additions (project
// file-length discipline).

/// **The wellness-score RING CARDS on the Insights overview.**
///
/// Replaced the plain-text "More from your data" rendering for the wellness
/// scores with monochrome `HLScoreRing` cards (the centrepiece of the Insights
/// redesign). Layout, top→bottom:
///
/// - **Bereitschaft / Schlaf-Score / Belastung** — ring score cards (ring +
///   score + short label, tappable → ``WellnessScoreDetailSheet``).
/// - **Cardio-Fitness** — an open-bottom gauge card (VO₂max is a spectrum
///   position, not a 0–100 quality score).
/// - **Signale des Tages** — an HONEST deviation-COUNT card (text/count, never a
///   ring, never AI).
///
/// Since v0.14.9 the re-frame metrics (Vascular age, HRV balance) render as
/// ring tiles here too, so every derived score has exactly one surface (the old
/// text lane was deleted in 1.4 B4). Monochrome, no glass (glass lives only on
/// the detail-sheet hero), reduce-motion-gated.
///
/// **Confidence gate (honest).** A core score whose server envelope is
/// `insufficient` renders a calm "noch nicht genug Daten" card, NOT a fake
/// score. The re-frame / count metrics simply self-suppress when absent.
struct InsightsScoreCardsBlock: View {
    /// The FULL derived metric list (`DerivedInsightsStore.metrics`) — both the
    /// `ok` and `insufficient` arms, so the confidence gate can render the calm
    /// state for a core score that hasn't enough data yet.
    let metrics: [DerivedMetricDTO]
    /// Deep-nav into a contributor's metric Insights page (reuses the overview's
    /// existing `trendChartMetric` push seam). `nil` → rows render non-tappable.
    let onSelectMetric: ((MetricKind) -> Void)?
    /// Deep-nav from the Stimmung contributor into the Mood special
    /// Insights page (mood is not a chartable `MetricKind`). `nil` → non-tappable.
    var onSelectMood: (() -> Void)?
    /// When false, the trailing "Signale des Tages" section is
    /// omitted so the host can render it elsewhere (the Insights overview hoists
    /// it BELOW the Einschätzung text via ``InsightsSignalsOfTheDaySection``).
    var showsSignals: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tile grid is two-up at standard text sizes and ONE column at
    /// an accessibility size, where a half-width tile is narrower than the
    /// number it has to print. Read here (not from a width heuristic) so the
    /// decision follows the setting the user actually changed, and so it agrees
    /// with `HLSettingsRow`, which switches on the same predicate.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// v0.14.11 Task B — read the container so the CYCLE ring tile can hard-gate
    /// on `cycleGate.isCycleTrackingAvailable` and read the shared `cycleStore`.
    /// The env is provided by `InsightsScreen` (this block mounts beneath it).
    @Environment(\.appContainer) private var appContainer
    /// Per-card hide state (local UI-pref). A card the operator hid
    /// (e.g. Recovery / Cardio-fitness with no Apple Watch) is dropped from the
    /// grid; re-enabled from the Insights customisation screen's "Score cards"
    /// toggles. Default empty → every renderable card shows (current behaviour).
    @Environment(WellnessCardVisibilityStore.self) private var cardVisibility
    /// The server-synced ring selection. It drives WHICH
    /// of the three shared ids render here and in what order; see
    /// ``InsightsScoreCardResolution`` for why each card has exactly one owner
    /// and why the web keeps this contract purely to feed iOS.
    ///
    /// OPTIONAL on purpose: the render-verify harnesses + previews mount this
    /// block outside the app's environment, and a non-optional lookup would trap
    /// there. `nil` resolves to "no explicit selection" → the pre-Build-4
    /// behaviour, which is exactly what a fixture render should show.
    @Environment(DashboardLayoutStore.self) private var dashboardLayoutStore: DashboardLayoutStore?
    /// The composite health score, the first card of the grid. Optional for
    /// the same reason as the layout store: render harnesses mount this block
    /// without it, and then the card is simply absent.
    @Environment(HealthScoreStore.self) private var healthScoreStore: HealthScoreStore?
    /// The detail a tapped card opens: a derived score's, or the health
    /// score's. One sheet for both, so every card opens the same way.
    @State private var detail: InsightsScoreCardDetail?
    /// The in-place edit affordance. Before this the
    /// selection was only reachable from Settings → Appearance, so the setting
    /// changed a surface the user could not see it change.
    @State private var showRingPicker = false

    /// The tile style is now the single shipped P9 `prismUniform`
    /// concept (the dev-switchable picker + its `@AppStorage` override were
    /// removed as an App-Store ship blocker). Every tile renders P9 unconditionally.
    private var tileStyle: InsightsTileStyle {
        .prismUniform
    }

    /// The core 0–100 scores rendered as ring cards (ordered). v0.14.8 Item-2 —
    /// RECOVERY_SCORE (Erholung) + STRESS_SCORE are promoted from the "More from
    /// your data" text lane to the SAME canonical `ScoreRingCard` the operator
    /// loves; both carry a `value.score` so they're tile-able.
    nonisolated static let ringScoreOrder = ["READINESS", "SLEEP_SCORE", "STRAIN_SCORE", "RECOVERY_SCORE", "STRESS_SCORE"]

    /// The Cardio-Fitness gauge ID — rendered as the open-bottom gauge card.
    nonisolated static let gaugeID = "FITNESS_AGE"
    /// The vascular-age years-delta ID, promoted from the "More from
    /// your data" text lane into a years-delta ring tile (the SAME shape as
    /// Cardio-Fitness — a delta, not a 0–100 score).
    nonisolated static let vascularID = "VASCULAR_AGE_DELTA"
    /// The HRV-balance band ID, promoted from the text lane into a
    /// band ring tile (no 0–100 score — the server band is positioned on the arc).
    nonisolated static let hrvBalanceID = "HRV_BALANCE"
    /// The "Signale des Tages" deviation-count ID — rendered as the count card.
    nonisolated static let deviationID = "COINCIDENT_DEVIATION"

    // `hideableCardOrder` + `isCardPresent` (the per-card show/hide
    // catalogue) live in `InsightsScoreCardsBlock+Visibility.swift`.

    private var byMetric: [String: DerivedMetricDTO] {
        Dictionary(metrics.map { ($0.metric, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// v0.14.8 Issue-1 — a score DTO is renderable as a ring card ONLY when it
    /// carries a real value (`status == "ok"` AND a non-nil `value`). The old
    /// calm "insufficient" gate (a dark `HLCard` + an empty, tick-marked "—"
    /// ring) read as a broken card to the operator, so a score with no value is
    /// now HIDDEN entirely — consistent with the signals hide-when-empty pattern.
    /// Pure (off-main-actor testable): the same predicate gates `hasAnyContent`
    /// and the grid loop, so neither can disagree.
    nonisolated static func isRenderableScore(_ dto: DerivedMetricDTO?) -> Bool {
        guard let dto else { return false }
        return dto.isOK && dto.value != nil
    }

    /// v0.14.11 Task B — the CYCLE ring tile is HARD-gated exactly like every
    /// other cycle surface: rendered ONLY when the container resolves
    /// `cycleGate.isCycleTrackingAvailable` (women-only + explicit opt-in) AND a
    /// cycle store exists that isn't disabled.
    /// Hidden entirely for men / opt-in-off users. The `CycleScoreRingCard`
    /// itself self-suppresses while still learning (no resolvable phase), so a
    /// cycle-eligible-but-no-prediction user never sees a hollow tile.
    ///
    /// Pure helper (off-main-actor testable) so the gate is unit-tested without a
    /// SwiftUI host — `cycleTileAvailable` is the live read that feeds it.
    nonisolated static func showsCycleTile(isAvailable: Bool, isDisabled: Bool) -> Bool {
        isAvailable && !isDisabled
    }

    private var cycleTileAvailable: Bool {
        guard let store = appContainer?.cycleStore else { return false }
        return Self.showsCycleTile(
            isAvailable: appContainer?.cycleGate.isCycleTrackingAvailable == true,
            isDisabled: store.isDisabled
        )
    }

    private var hasAnyContent: Bool {
        // `tiles` already applies the per-card hide filter AND includes
        // the cycle ring when available, so a non-empty `tiles` covers every
        // rendered ring (incl. the cycle-only user). The signals count is the
        // separate honest "Signals of the day" section, gated on its own value.
        !tiles.isEmpty || byMetric[Self.deviationID]?.value != nil
    }

    /// The most score tiles in one row at standard text sizes. Four on a
    /// wide page; with even columns three never happens, so on the open Duo
    /// no tile lies across the fold. Five only where the page holds five
    /// tiles in one row and that row takes every tile, so five scores never
    /// leave one alone under four. On the phone the 132 pt minimum keeps the
    /// two-up grid it has always had.
    static let maximumTileColumns = 5

    /// The columns the grid may use: ``maximumTileColumns`` at standard text
    /// sizes, one at an accessibility size, where a narrow tile would cut its
    /// own number.
    private var maximumColumns: Int {
        InsightsTileGrid.columnCount(
            standard: Self.maximumTileColumns,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    /// One tile in the grid. An enum so the heterogeneous cards share
    /// ONE ordered list: each gets a stable grid index for the phase-offset glow
    /// breath (Task C), and the cycle ring (Task B) slots in last.
    private enum Tile: Identifiable {
        case health(HealthScore)
        case score(DerivedMetricDTO), fitness(DerivedMetricDTO)
        case vascular(DerivedMetricDTO), hrv(DerivedMetricDTO), cycle

        var id: String {
            switch self {
            case .health: "health"
            case let .score(dto): "score.\(dto.metric)"
            case let .fitness(dto): "fitness.\(dto.metric)"
            case let .vascular(dto): "vascular.\(dto.metric)"
            case let .hrv(dto): "hrv.\(dto.metric)"
            case .cycle: "cycle"
            }
        }

        /// The derived-metric id behind the tile; `nil` for the health score
        /// and the cycle tile.
        var metricID: String? {
            switch self {
            case let .score(dto), let .fitness(dto), let .vascular(dto), let .hrv(dto): dto.metric
            case .health, .cycle: nil
            }
        }
    }

    /// The ordered, visible card ids. Each id has exactly
    /// ONE owner: the server ring selection for the three shared ids, the local
    /// hidden-set for the rest (see ``InsightsScoreCardResolution``).
    private var orderedCardIDs: [String] {
        InsightsScoreCardResolution.visibleOrderedIDs(
            catalogue: Self.hideableCardOrder,
            selection: explicitSelection,
            hidden: cardVisibility.hiddenIDs
        )
    }

    /// The operator's EXPLICIT ring choice, or `nil` when they never picked one
    /// (or the store is absent — previews / render harnesses). See
    /// ``DashboardLayoutStore/hasExplicitScoreRingSelection`` for why the
    /// server DEFAULT must not count as a choice here.
    private var explicitSelection: [ScoreRingID]? {
        guard let store = dashboardLayoutStore, store.hasExplicitScoreRingSelection else { return nil }
        return store.selectedScoreRings
    }

    /// Ordered renderable tiles, following ``orderedCardIDs``, with the
    /// hard-gated cycle tile LAST.
    private var tiles: [Tile] {
        // Each id resolves to its own tile SHAPE (score ring / delta ring /
        // band ring); the data gates below are unchanged — a card with no
        // presentable value never renders regardless of visibility.
        var result: [Tile] = orderedCardIDs.compactMap { id in
            guard let dto = byMetric[id] else { return nil }
            switch id {
            case Self.gaugeID:
                return dto.value != nil ? .fitness(dto) : nil
            case Self.vascularID:
                return Self.isRenderableScore(dto) ? .vascular(dto) : nil
            case Self.hrvBalanceID:
                guard Self.isRenderableScore(dto),
                      WellnessScorePresentation.hrvBalanceValueText(dto) != nil else { return nil }
                return .hrv(dto)
            default:
                return Self.isRenderableScore(dto) ? .score(dto) : nil
            }
        }
        // The health score stands where the hero ring order puts it among
        // the selected rings, first by default. It has no hide toggle, like
        // its ring on Today.
        if let score = healthScoreStore?.score {
            let index = InsightsScoreCardResolution.healthScoreIndex(
                in: result.compactMap(\.metricID),
                heroOrder: dashboardLayoutStore?.heroRingOrder ?? []
            )
            result.insert(.health(score), at: min(index, result.count))
        }
        // The cycle tile has no derived-metric id and is governed by its own
        // hard gate, so it is neither hideable nor selectable — always last.
        if cycleTileAvailable { result.append(.cycle) }
        return result
    }

    /// The hideable derived-metric id for a tile, or `nil` for the cycle
    /// tile (governed by its own hard gate, never operator-hideable here). Drives
    /// the per-tile long-press "Hide card" action.
    private func hideableID(for tile: Tile) -> String? {
        let id: String? = switch tile {
        case .health: nil
        case let .score(dto): dto.metric
        case let .fitness(dto): dto.metric
        case let .vascular(dto): dto.metric
        case let .hrv(dto): dto.metric
        case .cycle: nil
        }
        // A card the SERVER ring selection owns gets no
        // long-press "Hide card": that action writes the local hidden-set, which
        // is no longer consulted for those ids, so the affordance would look
        // like it worked and change nothing. Those cards are edited through the
        // ring picker (the header affordance next to "Your health scores").
        guard let id else { return nil }
        guard explicitSelection != nil else { return id }
        let governed = InsightsScoreCardResolution.selectionGovernedIDs(
            catalogue: Self.hideableCardOrder
        )
        return governed.contains(id) ? nil : id
    }

    @ViewBuilder
    private func tileView(_ tile: Tile, index: Int) -> some View {
        switch tile {
        case let .health(score):
            HealthScoreRingCard(
                score: score,
                style: tileStyle,
                glowPhaseIndex: index
            ) { detail = .healthScore }
        case let .score(dto):
            ScoreRingCard(
                dto: dto,
                style: tileStyle,
                glowPhaseIndex: index
            ) { detail = .derived(dto) }
        case let .fitness(dto):
            FitnessDeltaRingCard(
                dto: dto,
                style: tileStyle,
                glowPhaseIndex: index
            ) { detail = .derived(dto) }
        case let .vascular(dto):
            VascularDeltaRingCard(
                dto: dto,
                style: tileStyle,
                glowPhaseIndex: index
            ) { detail = .derived(dto) }
        case let .hrv(dto):
            HrvBalanceRingCard(
                dto: dto,
                style: tileStyle,
                glowPhaseIndex: index
            ) { detail = .derived(dto) }
        case .cycle:
            // Hard-gated upstream (`cycleTileAvailable`); self-suppresses while learning.
            if let store = appContainer?.cycleStore { CycleScoreRingCard(store: store) }
        }
    }

    var body: some View {
        if hasAnyContent {
            VStack(alignment: .leading, spacing: HLLayout.cardGap) {
                // The ring-selection edit affordance sits ON the surface the
                // setting changes, so the choice is visible where it takes
                // effect.
                HLSectionHeader("Your health scores", rank: .area) {
                    HLIconButton(
                        systemImage: "slider.horizontal.3",
                        label: "Choose which scores to show"
                    ) {
                        showRingPicker = true
                    }
                    .accessibilityIdentifier("insights.scoreCards.edit")
                }
                // Half-width tiles, two per row: bigger ring +
                // number + short label below, NO right-hand text block.
                // Driven off an ORDERED `tiles` list so each tile gets
                // a STABLE grid index for the phase-offset "living light" breath.
                // The tile gap is the dashboard's, so both tabs read as one
                // grid; the column count comes from the width the grid gets.
                HLTileGrid(
                    minimumTileWidth: HLTileGrid.ringTileMinimumWidth,
                    maximumColumns: maximumColumns,
                    evenColumns: true,
                    avoidsLoneTile: true,
                    spansLoneTile: true
                ) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        tileView(tile, index: index)
                            // Long-press a score card to hide it (the
                            // direct "this card is useless to me" affordance; the
                            // customisation screen's "Score cards" toggles bring
                            // it back). Not offered on the cycle tile.
                            .modifier(HideScoreCardMenu(
                                id: hideableID(for: tile),
                                store: cardVisibility
                            ))
                    }
                }
                if showsSignals,
                   let deviation = byMetric[Self.deviationID],
                   let summary = WellnessScorePresentation.deviationSummary(deviation),
                   WellnessScorePresentation.showsSignalsSection(summary)
                {
                    // "Signale des Tages" is its own section: the title is a
                    // heading above the card, the body sentence carries the
                    // count. `showsSignals` lets the overview hoist this BELOW
                    // the Einschätzung (``InsightsSignalsOfTheDaySection``).
                    HLSectionHeader("Signals of the day", rank: .area)
                    SignalsOfTheDayCard(summary: summary)
                }
            }
            .hlContainerGap(HLLayout.cardGap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(reduceMotion ? .identity : .opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("insights.scoreCards")
            .sheet(item: $detail) { detail in
                switch detail {
                case let .derived(dto):
                    WellnessScoreDetailSheet(dto: dto, onSelectMetric: onSelectMetric, onSelectMood: onSelectMood)
                case .healthScore:
                    InsightsHealthScoreSheet()
                }
            }
            .sheet(isPresented: $showRingPicker) {
                // The SAME sheet the Appearance
                // settings row opens (one editor, two entry points), now also
                // carrying the hero ring ORDER incl. the health-score anchor.
                ScoreRingSelectionSheet(
                    initialSelection: dashboardLayoutStore?.selectedScoreRings ?? ScoreRingID.defaultSelection,
                    initialOrder: dashboardLayoutStore?.heroRingOrder ?? []
                ) { chosen, order in
                    guard let store = dashboardLayoutStore else { return }
                    Task { await store.setScoreRings(selected: chosen, heroOrder: order) }
                }
            }
        }
    }
}

// MARK: - The Insights tile-grid width policy

/// **How wide an Insights tile grid is, as a pure function.**
///
/// The score tiles and the recovery tiles were both pinned to two flexible
/// columns. At an accessibility text size a half-width tile is narrower than
/// its own number, so the value either truncates or shrinks below the size the
/// user asked for — the type is bigger and the information is smaller, which is
/// the same defect `HLSettingsRow` had at `.accessibility5`.
///
/// The policy is deliberately a function of ONE boolean and the caller's own
/// standard grid, for three reasons:
///
/// - it is decided by ``SwiftUI/DynamicTypeSize/isAccessibilitySize``, the same
///   predicate `HLSettingsRow` switches on, so two
///   surfaces cannot disagree about where "accessibility size" begins;
/// - it is NOT a width/device heuristic — a grid that reflows on screen width
///   still truncates on a large phone at `.accessibility5`;
/// - it returns the caller's OWN first column rather than building one, so each
///   screen keeps its own spacing token and the fallback can never introduce a
///   gutter the standard grid does not have.
///
/// Pure and `GridItem`-free in its decision, so both halves are testable
/// off-main-actor: the count is the contract, and the rendered consequence (a
/// one-column grid of N tiles is taller than a two-column one) is measured
/// separately in `Phase8InsightsGridTests`.
enum InsightsTileGrid {
    /// The number of columns an Insights tile grid renders.
    static func columnCount(standard: Int, isAccessibilitySize: Bool) -> Int {
        isAccessibilitySize ? min(1, standard) : standard
    }

    /// ``standard`` at standard text sizes; its first column, alone, at an
    /// accessibility one. An empty grid stays empty — the fallback never
    /// invents a column a caller did not declare.
    static func columns(standard: [GridItem], isAccessibilitySize: Bool) -> [GridItem] {
        Array(standard.prefix(columnCount(standard: standard.count, isAccessibilitySize: isAccessibilitySize)))
    }
}

// MARK: - The detail a score card opens

/// What the score grid's one sheet shows.
enum InsightsScoreCardDetail: Identifiable {
    case derived(DerivedMetricDTO)
    case healthScore

    var id: String {
        switch self {
        case let .derived(dto): dto.metric
        case .healthScore: "HEALTH_SCORE"
        }
    }
}

// MARK: - DerivedMetricDTO Identifiable (sheet item)

extension DerivedMetricDTO: Identifiable {
    public var id: String {
        metric
    }
}

// MARK: - Signale des Tages (honest deviation count)

private struct SignalsOfTheDayCard: View {
    let summary: WellnessScorePresentation.DeviationSummary

    var body: some View {
        // The section heading now lives ABOVE this card (call
        // site), so the card carries ONLY the honest sentence + factor list.
        // The in-card icon + title + count "0" were removed.
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text(bodyText)
                    .hlText(.factLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !summary.contributing.isEmpty {
                    Text(factorsText)
                        .hlText(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(bodyText). \(factorsText)"))
        .accessibilityIdentifier("insights.scoreCard.COINCIDENT_DEVIATION")
    }

    private var bodyText: String {
        if summary.fired {
            return String(
                localized: "\(summary.contributingCount) of your vitals are outside their usual range today."
            )
        }
        return String(localized: "Your vitals are all within their usual range today.")
    }

    /// Lists the contributing vitals as POSSIBLE factors — never a named cause,
    /// never a diagnosis (Apple Vitals pattern).
    private var factorsText: String {
        let names = summary.contributing.map(WellnessScorePresentation.vitalLabel).joined(separator: ", ")
        return String(localized: "Possible factors: \(names)")
    }
}

// MARK: - Signale des Tages — standalone overview section

/// "Signale des Tages" as a standalone overview section so it
/// can sit AFTER the Einschätzung text (operator order: Gesundheitswerte →
/// Einschätzung → Signale → Zeitraum → Trends). Reuses the EXACT gating + card +
/// heading the score block uses; self-suppresses when there is no coincident-
/// deviation summary. The score block omits its inline copy via `showsSignals:
/// false` so this never double-renders.
struct InsightsSignalsOfTheDaySection: View {
    /// The full derived metric list (`DerivedInsightsStore.metrics`).
    let metrics: [DerivedMetricDTO]

    private var deviation: DerivedMetricDTO? {
        metrics.first { $0.metric == InsightsScoreCardsBlock.deviationID }
    }

    var body: some View {
        // v0.14.8 Item-3 — hide the WHOLE section (heading + card + spacing) when
        // there are no signals. `deviationSummary` returns non-nil even with
        // `fired == false` (the calm "all within range" sentence), so require a
        // FIRED signal with ≥1 contributing vital — no empty section, no dangling
        // heading, no orphan spacing.
        if let deviation,
           let summary = WellnessScorePresentation.deviationSummary(deviation),
           WellnessScorePresentation.showsSignalsSection(summary)
        {
            Group {
                HLSectionHeader("Signals of the day", rank: .area)
                SignalsOfTheDayCard(summary: summary)
            }
        }
    }
}
