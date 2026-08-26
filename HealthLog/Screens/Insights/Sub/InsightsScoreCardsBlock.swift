import SwiftUI

// v0141 — `WellnessRingPalette` + `WellnessRingShadow` moved to
// `WellnessRingPalette.swift`, and the per-card hide helpers + `HideScoreCardMenu`
// to `InsightsScoreCardsBlock+Visibility.swift`, to keep this file under the
// 600-line file-length budget after the show/hide additions (project
// file-length discipline).

/// **I-2 — the wellness-score RING CARDS on the Insights overview.**
///
/// Replaces the plain-text `InsightsDerivedBlock` rendering for the wellness
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
/// The re-frame metrics that aren't ring-promoted in I-2 (Vascular age, HRV
/// balance) keep their existing plain-text treatment via ``InsightsDerivedBlock``
/// — this block self-suppresses them. Monochrome, no glass (glass lives only on
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
    /// v0.14.3 F3 — deep-nav from the Stimmung contributor into the Mood special
    /// Insights page (mood is not a chartable `MetricKind`). `nil` → non-tappable.
    var onSelectMood: (() -> Void)?
    /// v0.14.7 (b156) — when false, the trailing "Signale des Tages" section is
    /// omitted so the host can render it elsewhere (the Insights overview hoists
    /// it BELOW the Einschätzung text via ``InsightsSignalsOfTheDaySection``).
    var showsSignals: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 08-11 — the tile grid is two-up at standard text sizes and ONE column at
    /// an accessibility size, where a half-width tile is narrower than the
    /// number it has to print. Read here (not from a width heuristic) so the
    /// decision follows the setting the user actually changed, and so it agrees
    /// with `HLSettingsRow`/`HLSettingsCard`, which switch on the same predicate.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// v0.14.11 Task B — read the container so the CYCLE ring tile can hard-gate
    /// on `cycleGate.isCycleTrackingAvailable` and read the shared `cycleStore`.
    /// The env is provided by `InsightsScreen` (this block mounts beneath it).
    @Environment(\.appContainer) private var appContainer
    /// v0141 — per-card hide state (local UI-pref). A card the operator hid
    /// (e.g. Recovery / Cardio-fitness with no Apple Watch) is dropped from the
    /// grid; re-enabled from the Insights customisation screen's "Score cards"
    /// toggles. Default empty → every renderable card shows (current behaviour).
    @Environment(WellnessCardVisibilityStore.self) private var cardVisibility
    /// Parity Build 4 · 4.3 — the server-synced ring selection. It drives WHICH
    /// of the three shared ids render here and in what order; see
    /// ``InsightsScoreCardResolution`` for why each card has exactly one owner
    /// and why the web keeps this contract purely to feed iOS.
    ///
    /// OPTIONAL on purpose: the render-verify harnesses + previews mount this
    /// block outside the app's environment, and a non-optional lookup would trap
    /// there. `nil` resolves to "no explicit selection" → the pre-Build-4
    /// behaviour, which is exactly what a fixture render should show.
    @Environment(DashboardLayoutStore.self) private var dashboardLayoutStore: DashboardLayoutStore?
    @State private var detailMetric: DerivedMetricDTO?
    /// Parity Build 4 · 4.3 — the in-place edit affordance. Before this the
    /// selection was only reachable from Settings → Appearance, so the setting
    /// changed a surface the user could not see it change.
    @State private var showRingPicker = false

    /// v0152 T1 — the tile style is now the single shipped P9 `prismUniform`
    /// concept (the dev-switchable picker + its `@AppStorage` override were
    /// removed as an App-Store ship blocker). Every tile renders P9 unconditionally.
    private var tileStyle: InsightsTileStyle {
        .prismUniform
    }

    /// The core 0–100 scores rendered as ring cards (ordered). v0.14.8 Item-2 —
    /// RECOVERY_SCORE (Erholung) + STRESS_SCORE are promoted from the "More from
    /// your data" text lane to the SAME canonical `ScoreRingCard` the operator
    /// loves; both carry a `value.score` so they're tile-able, and the dedup
    /// (`ringPromotedIDs`) auto-drops them from `InsightsDerivedBlock.textMetrics`.
    nonisolated static let ringScoreOrder = ["READINESS", "SLEEP_SCORE", "STRAIN_SCORE", "RECOVERY_SCORE", "STRESS_SCORE"]

    /// The Cardio-Fitness gauge ID — rendered as the open-bottom gauge card.
    nonisolated static let gaugeID = "FITNESS_AGE"
    /// v0.14.9 §2 — the vascular-age years-delta ID, promoted from the "More from
    /// your data" text lane into a years-delta ring tile (the SAME shape as
    /// Cardio-Fitness — a delta, not a 0–100 score).
    nonisolated static let vascularID = "VASCULAR_AGE_DELTA"
    /// v0.14.9 §2 — the HRV-balance band ID, promoted from the text lane into a
    /// band ring tile (no 0–100 score — the server band is positioned on the arc).
    nonisolated static let hrvBalanceID = "HRV_BALANCE"
    /// The "Signale des Tages" deviation-count ID — rendered as the count card.
    nonisolated static let deviationID = "COINCIDENT_DEVIATION"

    /// **The single source of truth** for which derived-metric IDs this block
    /// promotes to a ring / gauge / count card. `InsightsDerivedBlock` filters
    /// THESE out of its text lane so each score renders EXACTLY once — both sides
    /// read the same list, so no ID can appear twice or vanish.
    nonisolated static let ringPromotedIDs: Set<String> =
        Set(ringScoreOrder).union([gaugeID, vascularID, hrvBalanceID, deviationID])

    // v0141 — `hideableCardOrder` + `isCardPresent` (the per-card show/hide
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
    /// `cycleGate.isCycleTrackingAvailable` (women-only + explicit opt-in, behind
    /// `FeatureFlag.cycleTracking`) AND a cycle store exists that isn't disabled.
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
        // v0141 — `tiles` already applies the per-card hide filter AND includes
        // the cycle ring when available, so a non-empty `tiles` covers every
        // rendered ring (incl. the cycle-only user). The signals count is the
        // separate honest "Signals of the day" section, gated on its own value.
        !tiles.isEmpty || byMetric[Self.deviationID]?.value != nil
    }

    /// v0.14.1 §4 — two-per-row grid columns for the half-width score tiles.
    /// FW1-C (M6): card-grid gutter unified onto `HLSpace.md` (12) to match
    /// the Dashboard 2-up tile grid; previously `.sm` (8), which
    /// read as "not the same grid" one tab apart.
    private let columns = [
        GridItem(.flexible(), spacing: HLSpace.md),
        GridItem(.flexible(), spacing: HLSpace.md)
    ]

    /// 08-11 — the grid actually rendered: ``columns`` at standard text sizes,
    /// one column at an accessibility one. The two-up literal above stays the
    /// standard-size statement it has always been, so nothing about the shipped
    /// density is re-decided here.
    private var gridColumns: [GridItem] {
        InsightsTileGrid.columns(standard: columns, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    /// v0.14.11 — one tile in the grid. An enum so the heterogeneous cards share
    /// ONE ordered list: each gets a stable grid index for the phase-offset glow
    /// breath (Task C), and the cycle ring (Task B) slots in last.
    private enum Tile: Identifiable {
        case score(DerivedMetricDTO), fitness(DerivedMetricDTO)
        case vascular(DerivedMetricDTO), hrv(DerivedMetricDTO), cycle

        var id: String {
            switch self {
            case let .score(dto): "score.\(dto.metric)"
            case let .fitness(dto): "fitness.\(dto.metric)"
            case let .vascular(dto): "vascular.\(dto.metric)"
            case let .hrv(dto): "hrv.\(dto.metric)"
            case .cycle: "cycle"
            }
        }
    }

    /// Parity Build 4 · 4.3 — the ordered, visible card ids. Each id has exactly
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
        // The cycle tile has no derived-metric id and is governed by its own
        // hard gate, so it is neither hideable nor selectable — always last.
        if cycleTileAvailable { result.append(.cycle) }
        return result
    }

    /// v0141 — the hideable derived-metric id for a tile, or `nil` for the cycle
    /// tile (governed by its own hard gate, never operator-hideable here). Drives
    /// the per-tile long-press "Hide card" action.
    private func hideableID(for tile: Tile) -> String? {
        let id: String? = switch tile {
        case let .score(dto): dto.metric
        case let .fitness(dto): dto.metric
        case let .vascular(dto): dto.metric
        case let .hrv(dto): dto.metric
        case .cycle: nil
        }
        // Parity Build 4 · 4.3 — a card the SERVER ring selection owns gets no
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
        case let .score(dto):
            ScoreRingCard(
                dto: dto,
                style: tileStyle,
                glowPhaseIndex: index
            ) { detailMetric = dto }
        case let .fitness(dto):
            FitnessDeltaRingCard(
                dto: dto,
                style: tileStyle,
                glowPhaseIndex: index
            ) { detailMetric = dto }
        case let .vascular(dto):
            VascularDeltaRingCard(
                dto: dto,
                style: tileStyle,
                glowPhaseIndex: index
            ) { detailMetric = dto }
        case let .hrv(dto):
            HrvBalanceRingCard(
                dto: dto,
                style: tileStyle,
                glowPhaseIndex: index
            ) { detailMetric = dto }
        case .cycle:
            // Hard-gated upstream (`cycleTileAvailable`); self-suppresses while learning.
            if let store = appContainer?.cycleStore { CycleScoreRingCard(store: store) }
        }
    }

    var body: some View {
        if hasAnyContent {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                // v0.14.3 B7 — right-aligned subtitle removed (declutter).
                // Parity Build 4 · 4.3 — the ring-selection edit affordance sits
                // ON the surface the setting changes, so the choice is visible
                // where it takes effect (it was Settings-only before).
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                    InsightsSectionHeader("Your health scores")
                    Spacer(minLength: HLSpace.sm)
                    Button { showRingPicker = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.hlCaption.weight(.semibold))
                            .foregroundStyle(HLText.secondary)
                            // 08-11 — the interaction region, not the glyph: a
                            // `minWidth`/`minHeight` grows only what was too
                            // small (28×28 before), so the icon keeps its
                            // caption weight and the tap target reaches the
                            // 44pt `HLHitTarget.minimum`. Written as a literal
                            // because `Phase8AccessibilityPolicyTests` reads
                            // the declared frame's digits, not an identifier.
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(String(localized: "Choose which scores to show")))
                    .accessibilityIdentifier("insights.scoreCards.edit")
                }
                // v0.14.1 §4 — half-width tiles, two per row: bigger ring +
                // number + short label below, NO right-hand text block.
                // v0.14.11 — driven off an ORDERED `tiles` list so each tile gets
                // a STABLE grid index for the phase-offset "living light" breath.
                LazyVGrid(columns: gridColumns, spacing: HLSpace.md) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        tileView(tile, index: index)
                            // v0141 — long-press a score card to hide it (the
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
                    // v0.14.6 N1/N2 — "Signale des Tages" is its OWN section now:
                    // the title is a heading ABOVE the card (matching "Deine
                    // Gesundheitswerte" / "Zeitraum im Rückblick"), pulled out of
                    // the card chrome (the in-card icon + the count "0" are gone —
                    // the body sentence already carries the count). A top gap
                    // gives it breathing room from the score-ring grid (N1).
                    // v0.14.7 (b156): `showsSignals` lets the overview hoist this
                    // BELOW the Einschätzung (``InsightsSignalsOfTheDaySection``).
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        InsightsSectionHeader("Signals of the day")
                        SignalsOfTheDayCard(summary: summary)
                    }
                    .padding(.top, HLSpace.md)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(reduceMotion ? .identity : .opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("insights.scoreCards")
            .sheet(item: $detailMetric) { dto in
                WellnessScoreDetailSheet(dto: dto, onSelectMetric: onSelectMetric, onSelectMood: onSelectMood)
                    .hlSheetPresentation(.standard)
                    .presentationBackground(HLColor.surface)
            }
            .sheet(isPresented: $showRingPicker) {
                // Parity Build 4 · 4.3 + 4.8 — the SAME sheet the Appearance
                // settings row opens (one editor, two entry points), now also
                // carrying the hero ring ORDER incl. the health-score anchor.
                ScoreRingSelectionSheet(
                    initialSelection: dashboardLayoutStore?.selectedScoreRings ?? ScoreRingID.defaultSelection,
                    initialOrder: dashboardLayoutStore?.heroRingOrder ?? []
                ) { chosen, order in
                    guard let store = dashboardLayoutStore else { return }
                    Task { await store.setScoreRings(selected: chosen, heroOrder: order) }
                }
                .hlSheetPresentation(.standard)
                .presentationBackground(HLColor.surface)
            }
        }
    }
}

// MARK: - The Insights tile-grid width policy (08-11)

/// **08-11 — how wide an Insights tile grid is, as a pure function.**
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
///   predicate `HLSettingsRow`/`HLSettingsCard` switch on (08-04), so two
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
        // v0.14.6 N2 — the section heading now lives ABOVE this card (call
        // site), so the card carries ONLY the honest sentence + factor list.
        // The in-card icon + title + count "0" were removed.
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                Text(bodyText)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !summary.contributing.isEmpty {
                    Text(factorsText)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
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

// MARK: - Signale des Tages — standalone overview section (b156)

/// v0.14.7 (b156) — "Signale des Tages" as a standalone overview section so it
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
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                InsightsSectionHeader("Signals of the day")
                SignalsOfTheDayCard(summary: summary)
            }
        }
    }
}
